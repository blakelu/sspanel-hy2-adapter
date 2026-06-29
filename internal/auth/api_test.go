package auth

import (
	"context"
	"io"
	"log/slog"
	"testing"
	"time"

	"sspanel-uim-hy2-adapter/internal/panel"
)

type fakeAPIClient struct {
	users       []panel.User
	etag        string
	notModified bool
	err         error
}

func (f *fakeAPIClient) FetchUsers(context.Context, string) ([]panel.User, string, bool, error) {
	return f.users, f.etag, f.notModified, f.err
}

func TestAPIRefreshAndAuthenticate(t *testing.T) {
	client := &fakeAPIClient{users: []panel.User{
		{ID: 12, UUID: "first", Passwd: "shared"},
		{ID: 34, UUID: "second", Passwd: "shared"},
	}}
	source := NewAPI(client, []string{"uuid", "passwd"}, time.Minute, time.Minute, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err := source.InitialRefresh(context.Background()); err != nil {
		t.Fatal(err)
	}

	id, ok, err := source.Authenticate(context.Background(), "first")
	if err != nil || !ok || id != 12 {
		t.Fatalf("Authenticate(first) = %d, %v, %v", id, ok, err)
	}
	if _, ok, err := source.Authenticate(context.Background(), "shared"); err != nil || ok {
		t.Fatalf("ambiguous credential should be rejected, ok=%v err=%v", ok, err)
	}
	if _, ok, err := source.Authenticate(context.Background(), "missing"); err != nil || ok {
		t.Fatalf("missing credential should be rejected, ok=%v err=%v", ok, err)
	}
}

func TestAPIStaleCacheFailsClosed(t *testing.T) {
	client := &fakeAPIClient{users: []panel.User{{ID: 12, UUID: "first"}}}
	source := NewAPI(client, []string{"uuid"}, time.Minute, time.Nanosecond, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err := source.InitialRefresh(context.Background()); err != nil {
		t.Fatal(err)
	}
	time.Sleep(time.Millisecond)
	if _, ok, err := source.Authenticate(context.Background(), "first"); err == nil || ok {
		t.Fatalf("stale cache should fail closed, ok=%v err=%v", ok, err)
	}
}

func TestAPINotModifiedExtendsFreshness(t *testing.T) {
	client := &fakeAPIClient{users: []panel.User{{ID: 12, UUID: "first"}}, etag: "v1"}
	source := NewAPI(client, []string{"uuid"}, time.Minute, time.Minute, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err := source.InitialRefresh(context.Background()); err != nil {
		t.Fatal(err)
	}
	before := source.lastSuccess
	client.notModified = true
	time.Sleep(time.Millisecond)
	if err := source.Refresh(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !source.lastSuccess.After(before) {
		t.Fatal("304 response did not refresh cache freshness")
	}
}
