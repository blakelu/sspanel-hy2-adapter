package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestLoadAppliesDefaultsAndEnvironment(t *testing.T) {
	t.Setenv("TEST_PANEL_KEY", "secret")
	path := writeConfig(t, `
panel:
  base_url: https://panel.example.com/
  key: ${TEST_PANEL_KEY}
  node_id: 9
user_source:
  mode: api
hy2:
  stats_url: http://127.0.0.1:9999/
`)
	cfg, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Panel.Key != "secret" || cfg.Panel.BaseURL != "https://panel.example.com" {
		t.Fatalf("unexpected panel config: %#v", cfg.Panel)
	}
	if cfg.HY2.StatsURL != "http://127.0.0.1:9999" || cfg.HY2.PollInterval.Value() != time.Minute {
		t.Fatalf("unexpected HY2 defaults: %#v", cfg.HY2)
	}
}

func TestLoadRejectsUnknownField(t *testing.T) {
	path := writeConfig(t, `
panel:
  base_url: https://panel.example.com
  key: secret
  node_id: 9
  tiemout: 5s
`)
	_, err := Load(path)
	if err == nil || !strings.Contains(err.Error(), "tiemout") {
		t.Fatalf("expected unknown field error, got %v", err)
	}
}

func TestValidateRejectsUnsafeAPIStaleWindow(t *testing.T) {
	cfg := Default()
	cfg.Panel.BaseURL = "https://panel.example.com"
	cfg.Panel.Key = "secret"
	cfg.Panel.NodeID = 1
	cfg.UserSource.API.RefreshInterval = Duration(time.Minute)
	cfg.UserSource.API.MaxStale = Duration(30 * time.Second)
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "max_stale") {
		t.Fatalf("expected max_stale validation error, got %v", err)
	}
}

func writeConfig(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}
