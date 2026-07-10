package xray

import (
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestClientAgainstXray(t *testing.T) {
	bin := os.Getenv("XRAY_BIN")
	if bin == "" {
		t.Skip("XRAY_BIN is not set")
	}
	apiPort := freeTCPPort(t)
	inboundPort := freeTCPPort(t)
	config := fmt.Sprintf(`{
  "log":{"loglevel":"error"},
  "api":{"tag":"api","listen":"127.0.0.1:%d","services":["HandlerService","StatsService"]},
  "stats":{},
  "policy":{"levels":{"0":{"statsUserUplink":true,"statsUserDownlink":true}}},
  "inbounds":[{
    "tag":"vless-reality","listen":"127.0.0.1","port":%d,"protocol":"vless",
    "settings":{"clients":[],"decryption":"none"},
    "streamSettings":{"network":"raw","security":"reality","realitySettings":{
      "target":"www.microsoft.com:443","serverNames":["www.microsoft.com"],
      "privateKey":"4KUgMex3lQ3FllmJJA3RI5c7nOnJucAqlPmLFTNjwk0","shortIds":["0123456789abcdef"]
    }}
  }],
  "outbounds":[{"protocol":"freedom"}]
}`, apiPort, inboundPort)
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, []byte(config), 0o600); err != nil {
		t.Fatal(err)
	}
	command := exec.Command(bin, "run", "-config", path)
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = command.Process.Kill()
		_ = command.Wait()
	})

	client, err := New(fmt.Sprintf("127.0.0.1:%d", apiPort), "vless-reality", time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = client.Close() })

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
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

	const uuid = "5783a3e7-e373-51cd-8642-c83782b807c5"
	if err := client.AddUser(ctx, "12", uuid); err != nil {
		t.Fatal(err)
	}
	users, err := client.ListUsers(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if users["12"] != (UserSpec{ID: uuid, Flow: visionFlow}) {
		t.Fatalf("users = %#v", users)
	}
	if _, err := client.FetchTraffic(ctx); err != nil {
		t.Fatal(err)
	}
	if err := client.RemoveUser(ctx, "12"); err != nil {
		t.Fatal(err)
	}
	users, err = client.ListUsers(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, exists := users["12"]; exists {
		t.Fatalf("removed user still exists: %#v", users)
	}
}

func freeTCPPort(t *testing.T) int {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	return listener.Addr().(*net.TCPAddr).Port
}
