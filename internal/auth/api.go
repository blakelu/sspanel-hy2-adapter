package auth

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"sspanel-uim-hy2-adapter/internal/panel"
)

type APIUserClient interface {
	FetchUsers(ctx context.Context, etag string) (users []panel.User, newETag string, notModified bool, err error)
}

type API struct {
	client          APIUserClient
	fields          []string
	refreshInterval time.Duration
	maxStale        time.Duration
	logger          *slog.Logger

	mu          sync.RWMutex
	users       map[string]int64
	ambiguous   map[string]struct{}
	etag        string
	lastSuccess time.Time
}

func NewAPI(client APIUserClient, fields []string, refreshInterval, maxStale time.Duration, logger *slog.Logger) *API {
	return &API{
		client: client, fields: fields, refreshInterval: refreshInterval, maxStale: maxStale,
		logger: logger, users: make(map[string]int64), ambiguous: make(map[string]struct{}),
	}
}

func (a *API) InitialRefresh(ctx context.Context) error {
	if err := a.Refresh(ctx); err != nil {
		return fmt.Errorf("initial user refresh: %w", err)
	}
	return nil
}

func (a *API) Run(ctx context.Context) {
	ticker := time.NewTicker(a.refreshInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := a.Refresh(ctx); err != nil && !errors.Is(err, context.Canceled) {
				a.logger.Error("failed to refresh panel users", "error", err)
			}
		}
	}
}

func (a *API) Refresh(ctx context.Context) error {
	a.mu.RLock()
	etag := a.etag
	a.mu.RUnlock()
	users, newETag, notModified, err := a.client.FetchUsers(ctx, etag)
	if err != nil {
		return err
	}
	now := time.Now()
	if notModified {
		a.mu.Lock()
		a.lastSuccess = now
		a.mu.Unlock()
		return nil
	}

	index := make(map[string]int64, len(users))
	ambiguous := make(map[string]struct{})
	for _, user := range users {
		for _, field := range a.fields {
			credential := userCredential(user, field)
			if credential == "" {
				continue
			}
			if existing, found := index[credential]; found && existing != user.ID {
				delete(index, credential)
				ambiguous[credential] = struct{}{}
				continue
			}
			if _, duplicated := ambiguous[credential]; !duplicated {
				index[credential] = user.ID
			}
		}
	}
	a.mu.Lock()
	a.users = index
	a.ambiguous = ambiguous
	a.etag = newETag
	a.lastSuccess = now
	a.mu.Unlock()
	a.logger.Info("panel users refreshed", "users", len(users), "credentials", len(index), "ambiguous", len(ambiguous))
	return nil
}

func (a *API) Authenticate(_ context.Context, credential string) (int64, bool, error) {
	a.mu.RLock()
	defer a.mu.RUnlock()
	if a.lastSuccess.IsZero() || time.Since(a.lastSuccess) > a.maxStale {
		return 0, false, errors.New("panel user cache is stale")
	}
	if _, found := a.ambiguous[credential]; found {
		return 0, false, nil
	}
	id, found := a.users[credential]
	return id, found, nil
}

func (a *API) Healthy() bool {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return !a.lastSuccess.IsZero() && time.Since(a.lastSuccess) <= a.maxStale
}

func (a *API) Close() error { return nil }

func userCredential(user panel.User, field string) string {
	switch field {
	case "uuid":
		return user.UUID
	case "passwd":
		return user.Passwd
	default:
		return ""
	}
}
