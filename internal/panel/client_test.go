package panel

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestFetchUsersAndETag(t *testing.T) {
	transport := roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/mod_mu/users" || r.URL.Query().Get("key") != "panel-key" || r.URL.Query().Get("node_id") != "8" {
			t.Fatalf("unexpected request URL: %s", r.URL.String())
		}
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     http.Header{"Etag": []string{`"users-v1"`}},
			Body:       io.NopCloser(strings.NewReader(`{"ret":1,"data":[{"id":3,"uuid":"abc","passwd":"def"}],"msg":"ok"}`)),
		}, nil
	})
	client := New("https://panel.example", "panel-key", 8, time.Second, false)
	client.http.Transport = transport
	users, etag, notModified, err := client.FetchUsers(context.Background(), "")
	if err != nil {
		t.Fatal(err)
	}
	want := []User{{ID: 3, UUID: "abc", Passwd: "def"}}
	if !reflect.DeepEqual(users, want) || etag != `"users-v1"` || notModified {
		t.Fatalf("FetchUsers = %#v, %q, %v", users, etag, notModified)
	}
}

func TestReportTrafficPayload(t *testing.T) {
	var received struct {
		Data []Traffic `json:"data"`
	}
	transport := roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.Method != http.MethodPost || r.URL.Path != "/mod_mu/users/traffic" {
			t.Fatalf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		if err := json.NewDecoder(r.Body).Decode(&received); err != nil {
			t.Fatal(err)
		}
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     make(http.Header),
			Body:       io.NopCloser(strings.NewReader(`{"ret":1,"data":[],"msg":"ok"}`)),
		}, nil
	})
	client := New("https://panel.example", "panel-key", 8, time.Second, false)
	client.http.Transport = transport
	want := []Traffic{{UserID: 7, Upload: 100, Download: 200}}
	if err := client.ReportTraffic(context.Background(), want); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(received.Data, want) {
		t.Fatalf("payload = %#v, want %#v", received.Data, want)
	}
}
