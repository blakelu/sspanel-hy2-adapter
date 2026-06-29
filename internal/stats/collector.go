package stats

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"strconv"
	"time"

	"sspanel-uim-hy2-adapter/internal/hy2"
	"sspanel-uim-hy2-adapter/internal/panel"
)

type TrafficReader interface {
	FetchTraffic(ctx context.Context) (map[string]hy2.Counter, error)
}

type TrafficReporter interface {
	ReportTraffic(ctx context.Context, traffic []panel.Traffic) error
}

type Collector struct {
	reader   TrafficReader
	reporter TrafficReporter
	state    *State
	interval time.Duration
	startup  bool
	logger   *slog.Logger
}

func NewCollector(reader TrafficReader, reporter TrafficReporter, state *State, interval time.Duration, runOnStartup bool, logger *slog.Logger) *Collector {
	return &Collector{reader: reader, reporter: reporter, state: state, interval: interval, startup: runOnStartup, logger: logger}
}

func (c *Collector) Run(ctx context.Context) {
	if c.startup {
		if err := c.Collect(ctx); err != nil && !errors.Is(err, context.Canceled) {
			c.logger.Error("initial traffic collection failed", "error", err)
		}
	}
	ticker := time.NewTicker(c.interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := c.Collect(ctx); err != nil && !errors.Is(err, context.Canceled) {
				c.logger.Error("traffic collection failed", "error", err)
			}
		}
	}
}

func (c *Collector) Collect(ctx context.Context) error {
	current, err := c.reader.FetchTraffic(ctx)
	if err != nil {
		return err
	}
	traffic := trafficDelta(c.state.Snapshot(), current, c.logger)
	if len(traffic) > 0 {
		if err := c.reporter.ReportTraffic(ctx, traffic); err != nil {
			return err
		}
	}
	// Advance only after the panel accepts the complete batch. An empty current map
	// is also persisted because it signals that HY2 restarted or was externally cleared.
	c.state.Replace(current)
	if err := c.state.Save(); err != nil {
		return err
	}
	if len(traffic) > 0 {
		var upload, download uint64
		for _, item := range traffic {
			upload += item.Upload
			download += item.Download
		}
		c.logger.Info("traffic reported", "users", len(traffic), "upload", upload, "download", download)
	}
	return nil
}

func trafficDelta(previous, current map[string]hy2.Counter, logger *slog.Logger) []panel.Traffic {
	result := make([]panel.Traffic, 0, len(current))
	for rawID, now := range current {
		id, err := strconv.ParseInt(rawID, 10, 64)
		if err != nil || id <= 0 {
			logger.Warn("ignoring HY2 traffic for non-numeric client ID", "id", rawID)
			continue
		}
		before := previous[rawID]
		upload := counterDelta(before.Tx, now.Tx)
		download := counterDelta(before.Rx, now.Rx)
		if upload == 0 && download == 0 {
			continue
		}
		result = append(result, panel.Traffic{UserID: id, Upload: upload, Download: download})
	}
	sort.Slice(result, func(i, j int) bool { return result[i].UserID < result[j].UserID })
	return result
}

func counterDelta(previous, current uint64) uint64 {
	if current >= previous {
		return current - previous
	}
	// HY2 counters reset when the process restarts (or another caller clears them).
	return current
}

func (c *Collector) String() string {
	return fmt.Sprintf("HY2 traffic collector (interval %s)", c.interval)
}
