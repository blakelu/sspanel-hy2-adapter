package xray

import (
	"context"
	"io"
	"log/slog"
	"reflect"
	"testing"
	"time"

	"sspanel-uim-hy2-adapter/internal/panel"
)

type fakeProvider struct{ users []panel.User }

func (f fakeProvider) Users(context.Context) ([]panel.User, error) { return f.users, nil }

type fakeUserClient struct {
	users   map[string]UserSpec
	added   []string
	removed []string
}

func (f *fakeUserClient) ListUsers(context.Context) (map[string]UserSpec, error) {
	result := make(map[string]UserSpec, len(f.users))
	for email, user := range f.users {
		result[email] = user
	}
	return result, nil
}

func (f *fakeUserClient) AddUser(_ context.Context, email, id string) error {
	f.added = append(f.added, email+"="+id)
	f.users[email] = UserSpec{ID: id, Flow: visionFlow}
	return nil
}

func (f *fakeUserClient) RemoveUser(_ context.Context, email string) error {
	f.removed = append(f.removed, email)
	delete(f.users, email)
	return nil
}

type fakeCollector struct{ calls int }

func (f *fakeCollector) Collect(context.Context) error { f.calls++; return nil }

func TestSynchronizerReconcilesUsers(t *testing.T) {
	provider := fakeProvider{users: []panel.User{
		{ID: 7, UUID: "new-id"},
		{ID: 9, UUID: "ninth-id"},
	}}
	client := &fakeUserClient{users: map[string]UserSpec{
		"7": {ID: "old-id", Flow: visionFlow},
		"8": {ID: "revoked-id", Flow: visionFlow},
	}}
	collector := &fakeCollector{}
	syncer := NewSynchronizer(provider, client, collector, time.Minute, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err := syncer.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(client.removed, []string{"7", "8"}) {
		t.Fatalf("removed = %#v", client.removed)
	}
	if !reflect.DeepEqual(client.added, []string{"7=new-id", "9=ninth-id"}) {
		t.Fatalf("added = %#v", client.added)
	}
	if collector.calls != 1 {
		t.Fatalf("collector calls = %d, want 1", collector.calls)
	}
}

func TestDesiredUsersRejectsSharedUUID(t *testing.T) {
	got := desiredUsers([]panel.User{
		{ID: 1, UUID: "shared"},
		{ID: 2, UUID: "unique"},
		{ID: 3, UUID: "shared"},
		{ID: 4, UUID: "shared"},
	})
	want := map[string]string{"2": "unique"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("desired users = %#v, want %#v", got, want)
	}
}
