package panel

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const maxResponseSize = 8 << 20

type Client struct {
	baseURL string
	key     string
	nodeID  int64
	http    *http.Client
}

type User struct {
	ID     int64  `json:"id"`
	UUID   string `json:"uuid"`
	Passwd string `json:"passwd"`
}

type Traffic struct {
	UserID   int64  `json:"user_id"`
	Upload   uint64 `json:"u"`
	Download uint64 `json:"d"`
}

type envelope struct {
	Ret  int             `json:"ret"`
	Data json.RawMessage `json:"data"`
	Msg  string          `json:"msg"`
}

func New(baseURL, key string, nodeID int64, timeout time.Duration, insecureSkipVerify bool) *Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12, InsecureSkipVerify: insecureSkipVerify} //nolint:gosec // Explicit operator option.
	return &Client{
		baseURL: strings.TrimRight(baseURL, "/"),
		key:     key,
		nodeID:  nodeID,
		http:    &http.Client{Timeout: timeout, Transport: transport},
	}
}

func (c *Client) FetchUsers(ctx context.Context, etag string) ([]User, string, bool, error) {
	req, err := c.request(ctx, http.MethodGet, "/mod_mu/users", nil)
	if err != nil {
		return nil, "", false, err
	}
	if etag != "" {
		req.Header.Set("If-None-Match", etag)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, "", false, fmt.Errorf("fetch users: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotModified {
		return nil, etag, true, nil
	}
	env, err := decodeEnvelope(resp, "fetch users")
	if err != nil {
		return nil, "", false, err
	}
	var users []User
	if err := json.Unmarshal(env.Data, &users); err != nil {
		return nil, "", false, fmt.Errorf("decode users: %w", err)
	}
	return users, resp.Header.Get("ETag"), false, nil
}

func (c *Client) ReportTraffic(ctx context.Context, traffic []Traffic) error {
	body := struct {
		Data []Traffic `json:"data"`
	}{Data: traffic}
	req, err := c.request(ctx, http.MethodPost, "/mod_mu/users/traffic", body)
	if err != nil {
		return err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("report traffic: %w", err)
	}
	defer resp.Body.Close()
	_, err = decodeEnvelope(resp, "report traffic")
	return err
}

func (c *Client) request(ctx context.Context, method, path string, body any) (*http.Request, error) {
	var reader io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, fmt.Errorf("encode request: %w", err)
		}
		reader = bytes.NewReader(b)
	}
	u, err := url.Parse(c.baseURL + path)
	if err != nil {
		return nil, fmt.Errorf("build panel URL: %w", err)
	}
	q := u.Query()
	q.Set("key", c.key)
	q.Set("muKey", c.key)
	q.Set("node_id", strconv.FormatInt(c.nodeID, 10))
	u.RawQuery = q.Encode()
	req, err := http.NewRequestWithContext(ctx, method, u.String(), reader)
	if err != nil {
		return nil, fmt.Errorf("build panel request: %w", err)
	}
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	return req, nil
}

func decodeEnvelope(resp *http.Response, operation string) (envelope, error) {
	b, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseSize+1))
	if err != nil {
		return envelope{}, fmt.Errorf("%s: read response: %w", operation, err)
	}
	if len(b) > maxResponseSize {
		return envelope{}, fmt.Errorf("%s: response exceeds %d bytes", operation, maxResponseSize)
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return envelope{}, fmt.Errorf("%s: panel returned HTTP %d: %s", operation, resp.StatusCode, truncate(b, 512))
	}
	var env envelope
	if err := json.Unmarshal(b, &env); err != nil {
		return envelope{}, fmt.Errorf("%s: invalid JSON response: %w", operation, err)
	}
	if env.Ret == 0 {
		if env.Msg == "" {
			env.Msg = "unknown panel error"
		}
		return envelope{}, errors.New(operation + ": " + env.Msg)
	}
	return env, nil
}

func truncate(b []byte, max int) string {
	if len(b) <= max {
		return string(b)
	}
	return string(b[:max]) + "..."
}
