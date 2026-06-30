package main

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"testing"
	"time"
)

func TestJSONLoggerUsesChinaStandardTime(t *testing.T) {
	var output bytes.Buffer
	handler := newJSONHandler(&output, "info")
	record := slog.NewRecord(
		time.Date(2026, time.June, 30, 12, 34, 56, 0, time.UTC),
		slog.LevelInfo,
		"test message",
		0,
	)

	if err := handler.Handle(context.Background(), record); err != nil {
		t.Fatalf("write log: %v", err)
	}

	if got := output.String(); !strings.Contains(got, `"time":"2026-06-30T20:34:56+08:00"`) {
		t.Fatalf("log time is not UTC+8: %s", got)
	}
}
