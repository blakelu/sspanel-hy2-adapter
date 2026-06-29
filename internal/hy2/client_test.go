package hy2

import (
	"context"
	"io"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestFetchTraffic(t *testing.T) {
	transport := roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/traffic" || r.URL.RawQuery != "" {
			t.Fatalf("unexpected URL: %s", r.URL.String())
		}
		if r.Header.Get("Authorization") != "stats-secret" {
			t.Fatalf("authorization = %q", r.Header.Get("Authorization"))
		}
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     make(http.Header),
			Body:       io.NopCloser(strings.NewReader(`{"12":{"tx":123,"rx":456}}`)),
		}, nil
	})
	client := New("http://hy2.example:9999", "stats-secret", time.Second, false)
	client.http.Transport = transport
	got, err := client.FetchTraffic(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]Counter{"12": {Tx: 123, Rx: 456}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("traffic = %#v, want %#v", got, want)
	}
}
