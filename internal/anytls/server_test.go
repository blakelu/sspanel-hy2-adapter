package anytls

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"io"
	"log/slog"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	protocol "github.com/sagernet/sing-anytls"
	"github.com/sagernet/sing/common/logger"
	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/sing/common/uot"

	"sspanel-uim-hy2-adapter/internal/config"
	"sspanel-uim-hy2-adapter/internal/panel"
	"sspanel-uim-hy2-adapter/internal/traffic"
)

type fixtureProvider struct {
	mu    sync.Mutex
	users []panel.User
	err   error
}

func (p *fixtureProvider) Users(context.Context) ([]panel.User, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]panel.User(nil), p.users...), p.err
}

func (p *fixtureProvider) replace(users []panel.User, err error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.users, p.err = users, err
}

func certificate(t *testing.T, dir string) (*x509.CertPool, string, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(time.Now().UnixNano()),
		Subject: pkix.Name{CommonName: "anytls.example.test"}, DNSNames: []string{"anytls.example.test"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		KeyUsage:    x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, IsCA: true, BasicConstraintsValid: true}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	certFile, keyFile := filepath.Join(dir, "cert.pem"), filepath.Join(dir, "key.pem")
	if err := os.WriteFile(certFile, certPEM, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(keyFile, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}), 0600); err != nil {
		t.Fatal(err)
	}
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(certPEM)
	return pool, certFile, keyFile
}

func startServer(t *testing.T) (*Server, *fixtureProvider, *x509.CertPool) {
	t.Helper()
	pool, cert, key := certificate(t, t.TempDir())
	cfg := config.Default().AnyTLS
	cfg.Listen, cfg.CertificateFile, cfg.KeyFile = "127.0.0.1:0", cert, key
	p := &fixtureProvider{users: []panel.User{{ID: 7, UUID: "user-one"}, {ID: 8, UUID: "user-two"}}}
	s, err := New(cfg, p, func() bool { return true }, map[string]traffic.Counter{"7": {Tx: 100, Rx: 200}}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	if err = s.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err = s.Listen(); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- s.Serve(ctx) }()
	t.Cleanup(func() {
		cancel()
		s.Close()
		if err := <-done; err != nil {
			t.Error(err)
		}
	})
	return s, p, pool
}

func client(t *testing.T, s *Server, pool *x509.CertPool, password string) *protocol.Client {
	t.Helper()
	c, err := protocol.NewClient(protocol.ClientOptions{
		Password: password, Logger: logger.NOP(), IdleSessionCheckInterval: time.Second, IdleSessionTimeout: time.Minute,
		DialOut: func(ctx context.Context) (net.Conn, error) {
			d := tls.Dialer{NetDialer: &net.Dialer{Timeout: time.Second}, Config: &tls.Config{ServerName: "anytls.example.test", RootCAs: pool, MinVersion: tls.VersionTLS12}}
			return d.DialContext(ctx, "tcp", s.Addr().String())
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return c
}

func echoTCP(t *testing.T) M.Socksaddr {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func() { defer conn.Close(); io.Copy(conn, conn) }()
		}
	}()
	return M.SocksaddrFromNet(ln.Addr())
}

func exchange(t *testing.T, c *protocol.Client, destination M.Socksaddr) net.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	conn, err := c.DialContext(ctx, destination)
	if err != nil {
		t.Fatal(err)
	}
	conn.SetDeadline(time.Now().Add(2 * time.Second))
	if _, err = conn.Write([]byte("hello")); err != nil {
		conn.Close()
		t.Fatal(err)
	}
	buffer := make([]byte, 5)
	if _, err = io.ReadFull(conn, buffer); err != nil {
		conn.Close()
		t.Fatal(err)
	}
	if string(buffer) != "hello" {
		t.Fatalf("unexpected echo %q", buffer)
	}
	return conn
}

func awaitCounter(t *testing.T, s *Server, id string, tx, rx uint64) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		got, _ := s.FetchTraffic(context.Background())
		if got[id].Tx == tx && got[id].Rx == rx {
			return
		}
		time.Sleep(time.Millisecond)
	}
	got, _ := s.FetchTraffic(context.Background())
	t.Fatalf("counter %s: got %+v, want tx=%d rx=%d", id, got[id], tx, rx)
}

func TestTLSMultiUserTrafficAndRevocation(t *testing.T) {
	s, p, pool := startServer(t)
	destination := echoTCP(t)
	one := client(t, s, pool, "user-one")
	conn := exchange(t, one, destination)
	defer conn.Close()
	two := client(t, s, pool, "user-two")
	exchange(t, two, destination).Close()
	awaitCounter(t, s, "7", 105, 205)
	awaitCounter(t, s, "8", 5, 5)
	// User 7's active session must stop, while user 8 stays usable.
	p.replace([]panel.User{{ID: 8, UUID: "user-two"}}, nil)
	if err := s.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	conn.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := conn.Read(make([]byte, 1)); err == nil {
		t.Fatal("revoked session still readable")
	}
	exchange(t, two, destination).Close()
	awaitCounter(t, s, "8", 10, 10)
}

func TestInvalidAndDuplicatePasswordsCannotProxy(t *testing.T) {
	s, p, pool := startServer(t)
	destination := echoTCP(t)
	p.replace([]panel.User{{ID: 7, UUID: "shared"}, {ID: 8, UUID: "shared"}}, nil)
	if err := s.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	for _, password := range []string{"wrong", "shared", "user-one"} {
		c := client(t, s, pool, password)
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		conn, err := c.DialContext(ctx, destination)
		cancel()
		if err == nil {
			conn.SetDeadline(time.Now().Add(time.Second))
			conn.Write([]byte("hello"))
			if _, err := conn.Read(make([]byte, 5)); err == nil {
				t.Fatal("unauthorized password forwarded traffic")
			}
			conn.Close()
		}
	}
	awaitCounter(t, s, "7", 100, 200)
}

func TestExpiredUserSourceFailsClosed(t *testing.T) {
	s, p, pool := startServer(t)
	conn := exchange(t, client(t, s, pool, "user-one"), echoTCP(t))
	defer conn.Close()
	p.replace(nil, errors.New("cache expired"))
	if err := s.Sync(context.Background()); err == nil {
		t.Fatal("stale cache accepted")
	}
	conn.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := conn.Read(make([]byte, 1)); err == nil {
		t.Fatal("expired user session still open")
	}
}

func TestUDPOverTCPBothVersions(t *testing.T) {
	s, _, pool := startServer(t)
	packet, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer packet.Close()
	go func() {
		buffer := make([]byte, 65535)
		for {
			n, addr, err := packet.ReadFrom(buffer)
			if err != nil {
				return
			}
			packet.WriteTo(buffer[:n], addr)
		}
	}()
	c := client(t, s, pool, "user-two")
	for _, version := range []uint8{uot.LegacyVersion, uot.Version} {
		stream, err := c.DialContext(context.Background(), uot.RequestDestination(version))
		if err != nil {
			t.Fatal(err)
		}
		stream.SetDeadline(time.Now().Add(2 * time.Second))
		u := uot.Client{Version: version}
		udp, err := u.DialConn(stream, false, M.SocksaddrFromNet(packet.LocalAddr()))
		if err != nil {
			t.Fatal(err)
		}
		if _, err = udp.WriteTo([]byte("packet"), packet.LocalAddr()); err != nil {
			t.Fatal(err)
		}
		buffer := make([]byte, 64)
		n, _, err := udp.ReadFrom(buffer)
		if err != nil {
			t.Fatal(err)
		}
		if string(buffer[:n]) != "packet" {
			t.Fatalf("bad UDP echo %q", buffer[:n])
		}
		udp.Close()
	}
	awaitCounter(t, s, "8", 12, 12)
}

func TestCertificateReloadAndConcurrentSync(t *testing.T) {
	s, p, pool := startServer(t)
	destination := echoTCP(t)
	c := client(t, s, pool, "user-one")
	exchange(t, c, destination).Close()
	for i := 0; i < 10; i++ {
		go func() {
			p.replace([]panel.User{{ID: 7, UUID: "user-one"}, {ID: 8, UUID: "user-two"}}, nil)
			s.Sync(context.Background())
		}()
		exchange(t, c, destination).Close()
	}
	// Overwrite the configured PEM files; no listener restart is needed.
	if err := os.WriteFile(s.cfg.KeyFile, []byte("incomplete renewal write"), 0600); err != nil {
		t.Fatal(err)
	}
	// Handshakes continue using the previous valid pair during installation.
	exchange(t, client(t, s, pool, "user-two"), destination).Close()
	newPool, _, _ := certificate(t, filepath.Dir(s.cfg.CertificateFile))
	exchange(t, client(t, s, newPool, "user-two"), destination).Close()
}
