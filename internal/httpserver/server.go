package httpserver

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"strings"

	"sspanel-uim-hy2-adapter/internal/auth"
)

const maxAuthBody = 64 << 10

type Server struct {
	authPath  string
	token     string
	source    auth.Source
	collector TrafficCollector
	logger    *slog.Logger
}

type TrafficCollector interface {
	Collect(ctx context.Context) error
}

type authRequest struct {
	Addr string `json:"addr"`
	Auth string `json:"auth"`
	Tx   uint64 `json:"tx"`
}

type authResponse struct {
	OK bool   `json:"ok"`
	ID string `json:"id,omitempty"`
}

func New(authPath, token string, source auth.Source, collector TrafficCollector, logger *slog.Logger) http.Handler {
	s := &Server{authPath: authPath, token: token, source: source, collector: collector, logger: logger}
	mux := http.NewServeMux()
	mux.HandleFunc(authPath, s.authenticate)
	mux.HandleFunc("/admin/collect", s.collectTraffic)
	mux.HandleFunc("/healthz", s.health)
	return mux
}

func (s *Server) collectTraffic(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if s.token == "" || !tokenMatches(s.token, requestToken(r)) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if s.collector == nil {
		http.Error(w, "traffic collector unavailable", http.StatusServiceUnavailable)
		return
	}
	if err := s.collector.Collect(r.Context()); err != nil {
		s.logger.Error("manual traffic collection failed", "error", err)
		writeJSON(w, http.StatusBadGateway, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	s.logger.Info("manual traffic collection completed")
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) authenticate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if s.token != "" && !tokenMatches(s.token, requestToken(r)) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxAuthBody)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	var input authRequest
	if err := decoder.Decode(&input); err != nil {
		http.Error(w, "invalid JSON request", http.StatusBadRequest)
		return
	}
	if err := ensureJSONEnd(decoder); err != nil {
		http.Error(w, "invalid JSON request", http.StatusBadRequest)
		return
	}
	if input.Auth == "" {
		writeJSON(w, http.StatusOK, authResponse{OK: false})
		return
	}
	id, ok, err := s.source.Authenticate(r.Context(), input.Auth)
	if err != nil {
		s.logger.Error("authentication backend failed", "error", err)
		writeJSON(w, http.StatusOK, authResponse{OK: false})
		return
	}
	if !ok {
		s.logger.Debug("HY2 authentication rejected", "addr", input.Addr)
		writeJSON(w, http.StatusOK, authResponse{OK: false})
		return
	}
	writeJSON(w, http.StatusOK, authResponse{OK: true, ID: strconv.FormatInt(id, 10)})
}

func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	healthy := s.source.Healthy()
	status := http.StatusOK
	if !healthy {
		status = http.StatusServiceUnavailable
	}
	writeJSON(w, status, map[string]bool{"ok": healthy})
}

func requestToken(r *http.Request) string {
	if token := r.Header.Get("X-Adapter-Token"); token != "" {
		return token
	}
	if authorization := r.Header.Get("Authorization"); strings.HasPrefix(authorization, "Bearer ") {
		return strings.TrimPrefix(authorization, "Bearer ")
	}
	return r.URL.Query().Get("token")
}

func tokenMatches(expected, actual string) bool {
	return subtle.ConstantTimeCompare([]byte(expected), []byte(actual)) == 1
}

func ensureJSONEnd(decoder *json.Decoder) error {
	var extra any
	err := decoder.Decode(&extra)
	if errors.Is(err, io.EOF) {
		return nil
	}
	if err == nil {
		return errors.New("multiple JSON values")
	}
	return err
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
