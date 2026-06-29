package httpserver

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type fakeSource struct {
	id      int64
	ok      bool
	err     error
	healthy bool
}

func (f *fakeSource) Authenticate(context.Context, string) (int64, bool, error) {
	return f.id, f.ok, f.err
}
func (f *fakeSource) Healthy() bool { return f.healthy }
func (f *fakeSource) Close() error  { return nil }

func TestAuthenticateSuccess(t *testing.T) {
	handler := New("/auth", "secret", &fakeSource{id: 42, ok: true, healthy: true}, testLogger())
	req := httptest.NewRequest(http.MethodPost, "/auth?token=secret", strings.NewReader(`{"addr":"127.0.0.1:1","auth":"uuid","tx":100}`))
	resp := httptest.NewRecorder()
	handler.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK || strings.TrimSpace(resp.Body.String()) != `{"ok":true,"id":"42"}` {
		t.Fatalf("unexpected response: %d %s", resp.Code, resp.Body.String())
	}
}

func TestAuthenticateDenialAndBackendFailureUseProtocolResponse(t *testing.T) {
	tests := []struct {
		name   string
		source *fakeSource
	}{
		{name: "denied", source: &fakeSource{}},
		{name: "backend error", source: &fakeSource{err: errors.New("offline")}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			handler := New("/auth", "", tt.source, testLogger())
			req := httptest.NewRequest(http.MethodPost, "/auth", bytes.NewBufferString(`{"auth":"bad","addr":"x","tx":0}`))
			resp := httptest.NewRecorder()
			handler.ServeHTTP(resp, req)
			if resp.Code != http.StatusOK || strings.TrimSpace(resp.Body.String()) != `{"ok":false}` {
				t.Fatalf("unexpected response: %d %s", resp.Code, resp.Body.String())
			}
		})
	}
}

func TestAuthenticateRejectsInvalidTokenAndJSON(t *testing.T) {
	handler := New("/auth", "secret", &fakeSource{}, testLogger())

	req := httptest.NewRequest(http.MethodPost, "/auth?token=wrong", strings.NewReader(`{"auth":"x"}`))
	resp := httptest.NewRecorder()
	handler.ServeHTTP(resp, req)
	if resp.Code != http.StatusUnauthorized {
		t.Fatalf("wrong token status = %d", resp.Code)
	}

	req = httptest.NewRequest(http.MethodPost, "/auth?token=secret", strings.NewReader(`{"auth":"x","unexpected":true}`))
	resp = httptest.NewRecorder()
	handler.ServeHTTP(resp, req)
	if resp.Code != http.StatusBadRequest {
		t.Fatalf("invalid JSON status = %d", resp.Code)
	}
}

func TestHealth(t *testing.T) {
	handler := New("/auth", "", &fakeSource{healthy: false}, testLogger())
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	resp := httptest.NewRecorder()
	handler.ServeHTTP(resp, req)
	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("unhealthy status = %d", resp.Code)
	}
}

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}
