package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
	"time"

	protocol "github.com/sagernet/sing-anytls"
	"github.com/sagernet/sing/common/logger"
	M "github.com/sagernet/sing/common/metadata"

	"sspanel-uim-hy2-adapter/internal/config"
	"sspanel-uim-hy2-adapter/internal/panel"
)

// Run the real main entry point in a child process, including panel refresh,
// authentication, listener setup, admin collection and graceful shutdown.
func TestAnyTLSProcess(t *testing.T) {
	if path := os.Getenv("SSPANEL_ANYTLS_TEST_CONFIG"); path != "" {
		flag.CommandLine = flag.NewFlagSet("adapter", flag.ExitOnError)
		os.Args = []string{"adapter", "-config", path}
		if err := run(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		os.Exit(0)
	}
	dir := t.TempDir()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	leaf := &x509.Certificate{SerialNumber: big.NewInt(1), DNSNames: []string{"anytls.test"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true,
		KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, leaf, leaf, &key.PublicKey, key)
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
	var mu sync.Mutex
	users := []panel.User{{ID: 7, UUID: "test-user-uuid"}}
	var reported []panel.Traffic
	panelServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("key") != "test-mukey" || r.URL.Query().Get("node_id") != "16" {
			http.Error(w, "bad panel credentials", 403)
			return
		}
		mu.Lock()
		defer mu.Unlock()
		switch r.URL.Path {
		case "/mod_mu/users":
			json.NewEncoder(w).Encode(map[string]any{"ret": 1, "data": users})
		case "/mod_mu/users/traffic":
			var batch struct {
				Data []panel.Traffic `json:"data"`
			}
			if err := json.NewDecoder(r.Body).Decode(&batch); err != nil {
				http.Error(w, "bad traffic", 400)
				return
			}
			reported = append(reported, batch.Data...)
			io.WriteString(w, `{"ret":1}`)
		default:
			http.NotFound(w, r)
		}
	}))
	defer panelServer.Close()
	freeAddress := func() string {
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		addr := ln.Addr().String()
		ln.Close()
		return addr
	}
	cfg := config.Default()
	cfg.Panel.BaseURL, cfg.Panel.Key, cfg.Panel.NodeID = panelServer.URL, "test-mukey", 16
	cfg.Server.Listen, cfg.Server.AuthToken = freeAddress(), "test-admin-token"
	cfg.HY2.Enabled = false
	cfg.AnyTLS.Enabled = true
	cfg.AnyTLS.Listen = freeAddress()
	cfg.AnyTLS.ServerName = "anytls.test"
	cfg.AnyTLS.CertificateFile, cfg.AnyTLS.KeyFile, cfg.AnyTLS.StateFile = certFile, keyFile, filepath.Join(dir, "traffic.json")
	cfg.UserSource.API.RefreshInterval = config.Duration(30 * time.Millisecond)
	cfg.AnyTLS.SyncInterval = config.Duration(30 * time.Millisecond)
	cfg.AnyTLS.PollInterval = config.Duration(time.Hour)
	cfg.Log.Level = "warn"
	data := []byte(fmt.Sprintf(`server:
  listen: %q
  auth_token: test-admin-token
panel:
  base_url: %q
  key: test-mukey
  node_id: 16
user_source:
  mode: api
  credential_fields: [uuid]
  api:
    refresh_interval: 30ms
    max_stale: 5m
hy2:
  enabled: false
xray:
  enabled: false
anytls:
  enabled: true
  listen: %q
  server_name: anytls.test
  certificate_file: %q
  key_file: %q
  state_file: %q
  sync_interval: 30ms
  poll_interval: 1h
log:
  level: warn
`, cfg.Server.Listen, cfg.Panel.BaseURL, cfg.AnyTLS.Listen, certFile, keyFile, cfg.AnyTLS.StateFile))
	configFile := filepath.Join(dir, "adapter.yaml")
	if err := os.WriteFile(configFile, data, 0600); err != nil {
		t.Fatal(err)
	}
	logFile, err := os.Create(filepath.Join(dir, "process.log"))
	if err != nil {
		t.Fatal(err)
	}
	defer logFile.Close()
	cmd := exec.Command(os.Args[0], "-test.run=^TestAnyTLSProcess$")
	cmd.Env = append(os.Environ(), "SSPANEL_ANYTLS_TEST_CONFIG="+configFile)
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	t.Cleanup(func() {
		cmd.Process.Signal(os.Interrupt)
		select {
		case err := <-done:
			if err != nil {
				b, _ := os.ReadFile(logFile.Name())
				t.Errorf("adapter stopped: %v\n%s", err, b)
			}
		case <-time.After(5 * time.Second):
			cmd.Process.Kill()
			<-done
			t.Error("adapter shutdown timed out")
		}
	})
	httpClient := &http.Client{Timeout: time.Second}
	ready := false
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); {
		resp, err := httpClient.Get("http://" + cfg.Server.Listen + "/healthz")
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == 200 {
				ready = true
				break
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !ready {
		b, _ := os.ReadFile(logFile.Name())
		t.Fatalf("adapter not healthy: %s", b)
	}
	echo, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	go func() {
		conn, err := echo.Accept()
		if err == nil {
			defer conn.Close()
			io.Copy(conn, conn)
		}
	}()
	c, err := protocol.NewClient(protocol.ClientOptions{Password: "test-user-uuid", Logger: logger.NOP(),
		IdleSessionCheckInterval: time.Second, IdleSessionTimeout: time.Minute,
		DialOut: func(ctx context.Context) (net.Conn, error) {
			d := tls.Dialer{Config: &tls.Config{RootCAs: pool, ServerName: "anytls.test", MinVersion: tls.VersionTLS12}}
			return d.DialContext(ctx, "tcp", cfg.AnyTLS.Listen)
		}})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	conn, err := c.DialContext(context.Background(), M.SocksaddrFromNet(echo.Addr()))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(3 * time.Second))
	payload := []byte("panel-to-proxy")
	if _, err := conn.Write(payload); err != nil {
		t.Fatal(err)
	}
	buffer := make([]byte, len(payload))
	if _, err := io.ReadFull(conn, buffer); err != nil {
		t.Fatal(err)
	}
	if string(buffer) != string(payload) {
		t.Fatal("proxy payload changed")
	}
	// Allow the download write's accounting callback to finish before collecting.
	time.Sleep(20 * time.Millisecond)
	req, _ := http.NewRequest(http.MethodPost, "http://"+cfg.Server.Listen+"/admin/collect", nil)
	req.Header.Set("X-Adapter-Token", cfg.Server.AuthToken)
	resp, err := httpClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("collection status %d", resp.StatusCode)
	}
	mu.Lock()
	if len(reported) != 1 || reported[0].UserID != 7 || reported[0].Upload != uint64(len(payload)) || reported[0].Download != uint64(len(payload)) {
		t.Errorf("incorrect per-user traffic: %+v", reported)
	}
	users = nil
	mu.Unlock()
	conn.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := conn.Read(make([]byte, 1)); err == nil {
		t.Fatal("revoked user still connected")
	} else if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
		t.Fatal("user revocation was not applied")
	}
}
