package auth

import (
	"context"

	"sspanel-uim-hy2-adapter/internal/panel"
)

type Source interface {
	Authenticate(ctx context.Context, credential string) (userID int64, ok bool, err error)
	Healthy() bool
	Close() error
}

// UserProvider lists all users currently authorized for protocols, such as
// VLESS, that require their users to be installed in the server ahead of time.
type UserProvider interface {
	Users(ctx context.Context) ([]panel.User, error)
}
