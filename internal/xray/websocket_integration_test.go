package xray

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"golang.org/x/net/proxy"
	"sspanel-uim-hy2-adapter/internal/panel"
)

// Exercise TLS, WebSocket, API user synchronization and traffic accounting with
// the same Xray release shipped by the native manager. No external server needed.
func TestWebSocketTLSAgainstXray(t *testing.T) {
	bin := os.Getenv("XRAY_BIN")
	if bin == "" {
		t.Skip("XRAY_BIN is not set")
	}
	dir := t.TempDir()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	cert := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "ws.test"},
		DNSNames: []string{"ws.test"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, cert, cert, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	certPath, keyPath := filepath.Join(dir, "cert.pem"), filepath.Join(dir, "key.pem")
	for path, data := range map[string][]byte{
		certPath: pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
		keyPath:  pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)}),
	} {
		if err := os.WriteFile(path, data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	apiPort, wsPort, socksPort := freeTCPPort(t), freeTCPPort(t), freeTCPPort(t)
	const uuid = "5783a3e7-e373-51cd-8642-c83782b807c5"
	certJSON, _ := json.Marshal(certPath)
	keyJSON, _ := json.Marshal(keyPath)
	start := func(name, config string) {
		t.Helper()
		path := filepath.Join(dir, name+".json")
		if err := os.WriteFile(path, []byte(config), 0o600); err != nil {
			t.Fatal(err)
		}
		if output, err := exec.Command(bin, "run", "-test", "-config", path).CombinedOutput(); err != nil {
			t.Fatalf("invalid %s config: %v\n%s", name, err, output)
		}
		command := exec.Command(bin, "run", "-config", path)
		command.Stdout, command.Stderr = os.Stderr, os.Stderr
		if err := command.Start(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = command.Process.Kill(); _ = command.Wait() })
	}
	start("server", fmt.Sprintf(`{
  "log":{"loglevel":"error"},
  "api":{"tag":"api","listen":"127.0.0.1:%d","services":["HandlerService","StatsService"]},
  "stats":{},"policy":{"levels":{"0":{"statsUserUplink":true,"statsUserDownlink":true}}},
  "inbounds":[{"tag":"vless-ws","listen":"127.0.0.1","port":%d,"protocol":"vless",
    "settings":{"clients":[],"decryption":"none"},
    "streamSettings":{"network":"ws","security":"tls",
      "tlsSettings":{"serverName":"ws.test","alpn":["http/1.1"],"certificates":[{"certificateFile":%s,"keyFile":%s}]},
      "wsSettings":{"path":"/vless","host":"ws.test"}}}],
  "outbounds":[{"protocol":"freedom"}]
}`, apiPort, wsPort, certJSON, keyJSON))
	client, err := New(fmt.Sprintf("127.0.0.1:%d", apiPort), "vless-ws", "", time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = client.Close() })
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	for {
		if _, err := client.ListUsers(ctx); err == nil {
			break
		}
		select {
		case <-ctx.Done():
			t.Fatal("Xray API did not become ready")
		case <-time.After(50 * time.Millisecond):
		}
	}
	syncer := NewSynchronizer(fakeProvider{users: []panel.User{{ID: 12, UUID: uuid}}}, client, nil,
		time.Minute, slog.New(slog.NewTextHandler(io.Discard, nil)), "")
	if err := syncer.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	users, err := client.ListUsers(ctx)
	if err != nil || users["12"] != (UserSpec{ID: uuid, Flow: ""}) {
		t.Fatalf("WebSocket users = %#v, error = %v", users, err)
	}
	start("client", fmt.Sprintf(`{
  "log":{"loglevel":"error"},
  "inbounds":[{"listen":"127.0.0.1","port":%d,"protocol":"socks","settings":{"auth":"noauth"}}],
  "outbounds":[{"protocol":"vless","settings":{"vnext":[{"address":"127.0.0.1","port":%d,
    "users":[{"id":"%s","encryption":"none"}]}]},
    "streamSettings":{"network":"ws","security":"tls",
	      "tlsSettings":{"serverName":"ws.test","alpn":["http/1.1"],"certificates":[{"certificateFile":%s,"usage":"verify"}]},
      "wsSettings":{"path":"/vless","host":"ws.test"}}}]
}`, socksPort, wsPort, uuid, certJSON))
	const payload = "WebSocket TLS traffic passed through Xray"
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = io.WriteString(w, payload) }))
	defer origin.Close()
	dialer, err := proxy.SOCKS5("tcp", fmt.Sprintf("127.0.0.1:%d", socksPort), nil, proxy.Direct)
	if err != nil {
		t.Fatal(err)
	}
	transport := &http.Transport{DialContext: dialer.(proxy.ContextDialer).DialContext, DisableKeepAlives: true}
	defer transport.CloseIdleConnections()
	httpClient := &http.Client{Transport: transport, Timeout: 2 * time.Second}
	for {
		response, err := httpClient.Get(origin.URL)
		if err == nil {
			body, readErr := io.ReadAll(response.Body)
			_ = response.Body.Close()
			if readErr != nil || string(body) != payload {
				t.Fatalf("response = %q, error = %v", body, readErr)
			}
			break
		}
		select {
		case <-ctx.Done():
			t.Fatalf("WebSocket TLS request failed: %v", err)
		case <-time.After(50 * time.Millisecond):
		}
	}
	counters, err := client.FetchTraffic(ctx)
	if err != nil || counters["12"].Tx == 0 || counters["12"].Rx == 0 {
		t.Fatalf("traffic = %#v, error = %v", counters, err)
	}
}
