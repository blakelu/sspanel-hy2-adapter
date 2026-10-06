// Package anytls connects the upstream AnyTLS implementation to SSPanel users
// and traffic accounting. Authentication snapshots keep credentials and
// authorization identities consistent during refresh and revocation.
package anytls

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	protocol "github.com/sagernet/sing-anytls"
	singauth "github.com/sagernet/sing/common/auth"
	"github.com/sagernet/sing/common/logger"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/common/uot"

	"sspanel-uim-hy2-adapter/internal/auth"
	"sspanel-uim-hy2-adapter/internal/config"
	"sspanel-uim-hy2-adapter/internal/panel"
	"sspanel-uim-hy2-adapter/internal/traffic"
)

type snapshot struct {
	service *protocol.MultiService[string]
	users   map[string]string // protocol identity -> numeric SSPanel ID
}

type connection struct {
	conn net.Conn
	user string
}

type connectionKey struct{}

type Server struct {
	cfg      config.AnyTLSConfig
	provider auth.UserProvider
	healthy  func() bool
	logger   *slog.Logger
	current  atomic.Pointer[snapshot]
	cert     atomic.Pointer[tls.Certificate]
	syncMu   sync.Mutex
	mu       sync.Mutex
	listener net.Listener
	closing  bool
	conns    map[*connection]struct{}
	counters map[string]traffic.Counter
	wg       sync.WaitGroup
}

func New(cfg config.AnyTLSConfig, provider auth.UserProvider, healthy func() bool, initial map[string]traffic.Counter, log *slog.Logger) (*Server, error) {
	cert, err := LoadCertificate(cfg)
	if err != nil {
		return nil, fmt.Errorf("load AnyTLS certificate: %w", err)
	}
	s := &Server{cfg: cfg, provider: provider, healthy: healthy, logger: log,
		conns: make(map[*connection]struct{}), counters: make(map[string]traffic.Counter)}
	s.cert.Store(&cert)
	// Continue from the last accepted checkpoint, so a process restart cannot
	// subtract the old process's counters from this process's first traffic.
	for id, counter := range initial {
		s.counters[id] = counter
	}
	return s, nil
}

func LoadCertificate(cfg config.AnyTLSConfig) (tls.Certificate, error) {
	cert, err := tls.LoadX509KeyPair(cfg.CertificateFile, cfg.KeyFile)
	if err != nil {
		return cert, err
	}
	leaf, err := x509.ParseCertificate(cert.Certificate[0])
	if err != nil {
		return cert, err
	}
	if now := time.Now(); now.Before(leaf.NotBefore) || now.After(leaf.NotAfter) {
		return cert, errors.New("AnyTLS certificate is not currently valid")
	}
	if cfg.ServerName != "" {
		if err := leaf.VerifyHostname(cfg.ServerName); err != nil {
			return cert, err
		}
	}
	cert.Leaf = leaf
	return cert, nil
}

func (s *Server) Sync(ctx context.Context) error {
	s.syncMu.Lock()
	defer s.syncMu.Unlock()
	users, fetchErr := s.provider.Users(ctx)
	if fetchErr != nil {
		// API providers retain their bounded stale cache themselves. Once that
		// cache expires, fail closed and revoke existing sessions as well.
		users = nil
	}
	accounts, identities := desiredUsers(users)
	service, err := protocol.NewMultiService[string](protocol.ServiceOptions{
		PaddingScheme: protocol.DefaultPaddingScheme,
		Handler:       s, Logger: logger.NOP(),
	})
	if err != nil {
		return err
	}
	names, passwords := make([]string, len(accounts)), make([]string, len(accounts))
	for i, account := range accounts {
		names[i], passwords[i] = account.Name, account.Password
	}
	if err := service.UpdateUsers(names, passwords); err != nil {
		return err
	}
	next := &snapshot{service: service, users: identities}
	s.mu.Lock()
	s.current.Store(next)
	var revoked []net.Conn
	for conn := range s.conns {
		if conn.user != "" {
			if _, allowed := identities[conn.user]; !allowed {
				revoked = append(revoked, conn.conn)
			}
		}
	}
	s.mu.Unlock()
	for _, conn := range revoked {
		conn.Close()
	}
	if fetchErr != nil {
		return fmt.Errorf("list AnyTLS users: %w", fetchErr)
	}
	s.logger.Debug("AnyTLS users synchronized", "users", len(accounts))
	return nil
}

type account struct{ Name, Password string }

func desiredUsers(users []panel.User) ([]account, map[string]string) {
	owners := make(map[string]int64)
	ambiguous := make(map[string]bool)
	for _, user := range users {
		if user.ID <= 0 || user.UUID == "" {
			continue
		}
		if owner, exists := owners[user.UUID]; exists && owner != user.ID {
			ambiguous[user.UUID] = true
		}
		owners[user.UUID] = user.ID
	}
	accounts := make([]account, 0, len(owners))
	identities := make(map[string]string, len(owners))
	for password, id := range owners {
		if ambiguous[password] {
			continue
		}
		numeric := strconv.FormatInt(id, 10)
		identity := fmt.Sprintf("%s:%x", numeric, sha256.Sum256([]byte(password)))
		accounts = append(accounts, account{Name: identity, Password: password})
		identities[identity] = numeric
	}
	return accounts, identities
}

func (s *Server) RunSync(ctx context.Context) {
	ticker := time.NewTicker(s.cfg.SyncInterval.Value())
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := s.Sync(ctx); err != nil && !errors.Is(err, context.Canceled) {
				s.logger.Error("AnyTLS user synchronization failed", "error", err)
			}
		}
	}
}

func (s *Server) Listen() error {
	ln, err := net.Listen("tcp", s.cfg.Listen)
	if err != nil {
		return fmt.Errorf("listen AnyTLS: %w", err)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closing {
		ln.Close()
		return net.ErrClosed
	}
	s.listener = ln
	return nil
}

func (s *Server) Addr() net.Addr {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.listener.Addr()
}

func (s *Server) Serve(ctx context.Context) error {
	for {
		raw, err := s.listener.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}
		record := &connection{conn: raw}
		s.mu.Lock()
		if s.closing {
			s.mu.Unlock()
			raw.Close()
			return nil
		}
		s.conns[record] = struct{}{}
		s.wg.Add(1)
		s.mu.Unlock()
		go s.serveConnection(ctx, record)
	}
}

func (s *Server) serveConnection(ctx context.Context, record *connection) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	defer s.wg.Done()
	defer func() {
		record.conn.Close()
		s.mu.Lock()
		delete(s.conns, record)
		s.mu.Unlock()
	}()
	conn := tls.Server(record.conn, &tls.Config{
		MinVersion: tls.VersionTLS12,
		// Reload on new TLS handshakes; ACME renewal does not restart sessions.
		GetCertificate: func(*tls.ClientHelloInfo) (*tls.Certificate, error) {
			cert, err := LoadCertificate(s.cfg)
			if err != nil {
				// ACME installs the two PEM files sequentially. Keep using the
				// previous valid pair while the new pair is being written.
				old := s.cert.Load()
				if old != nil && time.Now().Before(old.Leaf.NotAfter) {
					return old, nil
				}
				return nil, err
			}
			s.cert.Store(&cert)
			return &cert, err
		},
	})
	conn.SetDeadline(time.Now().Add(s.cfg.HandshakeTimeout.Value()))
	if err := conn.HandshakeContext(ctx); err != nil {
		return
	}
	now := s.current.Load()
	if now == nil || !s.healthy() {
		return
	}
	ctx = context.WithValue(ctx, connectionKey{}, record)
	// Leave the deadline in place until the first authenticated stream. This
	// also bounds clients which finish TLS but never send AnyTLS credentials.
	if err := now.service.NewConnection(ctx, conn, M.SocksaddrFromNet(conn.RemoteAddr()), nil); err != nil {
		s.logger.Debug("AnyTLS connection rejected")
	}
}

func (s *Server) NewConnectionEx(ctx context.Context, conn net.Conn, _ M.Socksaddr, destination M.Socksaddr, _ N.CloseHandlerFunc) {
	defer conn.Close()
	identity, ok := singauth.UserFromContext[string](ctx)
	record, hasRecord := ctx.Value(connectionKey{}).(*connection)
	if !ok || !hasRecord || !s.healthy() {
		return
	}
	s.mu.Lock()
	now := s.current.Load()
	id, allowed := now.users[identity]
	if !allowed || s.closing {
		s.mu.Unlock()
		return
	}
	record.user = identity
	// Count active stream handlers as well as the outer multiplexed sessions.
	s.wg.Add(1)
	s.mu.Unlock()
	defer s.wg.Done()
	record.conn.SetDeadline(time.Time{})
	if destination.Fqdn == uot.MagicAddress || destination.Fqdn == uot.LegacyMagicAddress {
		if err := N.ReportHandshakeSuccess(conn); err != nil {
			return
		}
		s.relayUDP(ctx, id, conn, destination.Fqdn == uot.MagicAddress)
		return
	}
	dialer := net.Dialer{Timeout: s.cfg.DialTimeout.Value()}
	out, err := dialer.DialContext(ctx, "tcp", destination.String())
	if err != nil {
		N.ReportHandshakeFailure(conn, err)
		return
	}
	defer out.Close()
	if err := N.ReportConnHandshakeSuccess(conn, out); err != nil {
		return
	}
	stop := context.AfterFunc(ctx, func() { out.Close(); conn.Close() })
	defer stop()
	s.relayTCP(id, conn, out)
}

func (s *Server) relayTCP(id string, client, remote net.Conn) {
	uploadDone := make(chan struct{})
	go func() {
		io.Copy(&countWriter{writer: remote, add: func(n int) { s.add(id, uint64(n), 0) }}, client)
		// AnyTLS FIN closes a stream in both directions (no TCP half-close).
		remote.Close()
		close(uploadDone)
	}()
	io.Copy(&countWriter{writer: client, add: func(n int) { s.add(id, 0, uint64(n)) }}, remote)
	client.Close()
	remote.Close()
	<-uploadDone
}

func (s *Server) relayUDP(ctx context.Context, id string, stream net.Conn, v2 bool) {
	request := uot.Request{}
	if v2 {
		r, err := uot.ReadRequest(stream)
		if err != nil {
			return
		}
		request = *r
	}
	client := uot.NewConn(stream, request)
	packet, err := net.ListenPacket("udp", "")
	if err != nil {
		return
	}
	defer packet.Close()
	stop := context.AfterFunc(ctx, func() { packet.Close(); client.Close() })
	defer stop()
	replyDone := make(chan struct{})
	go func() {
		defer close(replyDone)
		defer client.Close()
		buffer := make([]byte, 65535)
		for {
			packet.SetReadDeadline(time.Now().Add(s.cfg.UDPTimeout.Value()))
			n, addr, err := packet.ReadFrom(buffer)
			if err != nil {
				return
			}
			_, err = client.WriteTo(buffer[:n], addr)
			if err != nil {
				return
			}
			// UOT WriteTo returns the framed length, including address/length
			// fields. Bill the UDP payload only, matching the upload direction.
			s.add(id, 0, uint64(n))
		}
	}()
	buffer := make([]byte, 65535)
	for {
		n, addr, err := client.ReadFrom(buffer)
		if err != nil {
			break
		}
		dest := M.SocksaddrFromNet(addr)
		if dest.IsFqdn() {
			lookupCtx, cancel := context.WithTimeout(ctx, s.cfg.DialTimeout.Value())
			ips, err := net.DefaultResolver.LookupNetIP(lookupCtx, "ip", dest.Fqdn)
			cancel()
			if err != nil || len(ips) == 0 {
				continue
			}
			dest = M.Socksaddr{Addr: ips[0], Port: dest.Port}
		}
		written, err := packet.WriteTo(buffer[:n], dest.UDPAddr())
		s.add(id, uint64(written), 0)
		if err != nil {
			break
		}
	}
	packet.Close()
	client.Close()
	<-replyDone
}

func (s *Server) add(id string, tx, rx uint64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	counter := s.counters[id]
	counter.Tx += tx
	counter.Rx += rx
	s.counters[id] = counter
}

func (s *Server) FetchTraffic(context.Context) (map[string]traffic.Counter, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	result := make(map[string]traffic.Counter, len(s.counters))
	for id, counter := range s.counters {
		result[id] = counter
	}
	return result, nil
}

func (s *Server) Close() error {
	s.mu.Lock()
	s.closing = true
	if s.listener != nil {
		s.listener.Close()
	}
	for conn := range s.conns {
		conn.conn.Close()
	}
	s.mu.Unlock()
	s.wg.Wait()
	return nil
}

type countWriter struct {
	writer io.Writer
	add    func(int)
}

func (w *countWriter) Write(data []byte) (int, error) {
	n, err := w.writer.Write(data)
	w.add(n)
	return n, err
}
