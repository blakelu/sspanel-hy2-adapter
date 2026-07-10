package xray

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"strconv"
	"sync"
	"time"

	"sspanel-uim-hy2-adapter/internal/auth"
	"sspanel-uim-hy2-adapter/internal/panel"
)

type UserClient interface {
	ListUsers(ctx context.Context) (map[string]UserSpec, error)
	AddUser(ctx context.Context, email, id string) error
	RemoveUser(ctx context.Context, email string) error
}

type TrafficCollector interface {
	Collect(ctx context.Context) error
}

type Synchronizer struct {
	provider  auth.UserProvider
	client    UserClient
	collector TrafficCollector
	interval  time.Duration
	logger    *slog.Logger
	mu        sync.Mutex
}

func NewSynchronizer(provider auth.UserProvider, client UserClient, collector TrafficCollector, interval time.Duration, logger *slog.Logger) *Synchronizer {
	return &Synchronizer{provider: provider, client: client, collector: collector, interval: interval, logger: logger}
}

func (s *Synchronizer) Run(ctx context.Context) {
	ticker := time.NewTicker(s.interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := s.Sync(ctx); err != nil && !errors.Is(err, context.Canceled) {
				s.logger.Error("failed to synchronize Xray users", "error", err)
			}
		}
	}
}

func (s *Synchronizer) Sync(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	users, err := s.provider.Users(ctx)
	if err != nil {
		return fmt.Errorf("list authorized users: %w", err)
	}
	desired := desiredUsers(users)
	current, listErr := s.client.ListUsers(ctx)
	// ListUsers returns the decodable users even if one foreign account could not
	// be decoded. Reconciliation can still remove that account safely.
	if current == nil {
		return listErr
	}

	remove := make([]string, 0)
	for email, user := range current {
		if desiredID, ok := desired[email]; !ok || desiredID != user.ID || user.Flow != visionFlow {
			remove = append(remove, email)
		}
	}
	sort.Strings(remove)
	var syncErrors []error
	if len(remove) > 0 && s.collector != nil {
		if err := s.collector.Collect(ctx); err != nil {
			// Authorization changes take precedence over accounting continuity.
			// Continue removing revoked users even if the final collection fails.
			syncErrors = append(syncErrors, fmt.Errorf("collect Xray traffic before removing users: %w", err))
		}
	}

	if listErr != nil {
		syncErrors = append(syncErrors, listErr)
	}
	for _, email := range remove {
		if err := s.client.RemoveUser(ctx, email); err != nil {
			syncErrors = append(syncErrors, err)
			continue
		}
		delete(current, email)
	}

	add := make([]string, 0)
	for email := range desired {
		if _, ok := current[email]; !ok {
			add = append(add, email)
		}
	}
	sort.Strings(add)
	for _, email := range add {
		if err := s.client.AddUser(ctx, email, desired[email]); err != nil {
			syncErrors = append(syncErrors, err)
		}
	}
	if err := errors.Join(syncErrors...); err != nil {
		return err
	}
	s.logger.Info("Xray users synchronized", "users", len(desired), "added", len(add), "removed", len(remove))
	return nil
}

func desiredUsers(users []panel.User) map[string]string {
	desired := make(map[string]string, len(users))
	owners := make(map[string]string, len(users))
	ambiguous := make(map[string]struct{})
	for _, user := range users {
		if user.ID <= 0 || user.UUID == "" {
			continue
		}
		email := strconv.FormatInt(user.ID, 10)
		if owner, exists := owners[user.UUID]; exists && owner != email {
			delete(desired, owner)
			ambiguous[user.UUID] = struct{}{}
			continue
		}
		if _, exists := ambiguous[user.UUID]; exists {
			continue
		}
		owners[user.UUID] = email
		desired[email] = user.UUID
	}
	return desired
}
