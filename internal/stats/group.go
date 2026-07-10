package stats

import (
	"context"
	"errors"
)

type CollectFunc func(context.Context) error

type Group []CollectFunc

func (g Group) Collect(ctx context.Context) error {
	var errs []error
	for _, collect := range g {
		if err := collect(ctx); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}
