package hy2

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

const maxStatsResponseSize = 16 << 20

type Counter struct {
	Tx uint64 `json:"tx"`
	Rx uint64 `json:"rx"`
}

type Client struct {
	baseURL string
	secret  string
	http    *http.Client
}

func New(baseURL, secret string, timeout time.Duration, insecureSkipVerify bool) *Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12, InsecureSkipVerify: insecureSkipVerify} //nolint:gosec // Explicit operator option.
	return &Client{
		baseURL: strings.TrimRight(baseURL, "/"),
		secret:  secret,
		http:    &http.Client{Timeout: timeout, Transport: transport},
	}
}

func (c *Client) FetchTraffic(ctx context.Context) (map[string]Counter, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.baseURL+"/traffic", nil)
	if err != nil {
		return nil, fmt.Errorf("build HY2 stats request: %w", err)
	}
	if c.secret != "" {
		req.Header.Set("Authorization", c.secret)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("fetch HY2 traffic: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return nil, fmt.Errorf("fetch HY2 traffic: HTTP %d: %s", resp.StatusCode, b)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, maxStatsResponseSize+1))
	if err != nil {
		return nil, fmt.Errorf("read HY2 traffic: %w", err)
	}
	if len(b) > maxStatsResponseSize {
		return nil, fmt.Errorf("decode HY2 traffic: response exceeds %d bytes", maxStatsResponseSize)
	}
	stats := make(map[string]Counter)
	if err := json.Unmarshal(b, &stats); err != nil {
		return nil, fmt.Errorf("decode HY2 traffic: %w", err)
	}
	return stats, nil
}
