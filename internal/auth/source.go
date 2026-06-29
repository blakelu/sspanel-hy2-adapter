package auth

import "context"

type Source interface {
	Authenticate(ctx context.Context, credential string) (userID int64, ok bool, err error)
	Healthy() bool
	Close() error
}
