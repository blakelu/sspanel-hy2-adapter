package stats

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"sspanel-uim-hy2-adapter/internal/hy2"
	"sspanel-uim-hy2-adapter/internal/panel"
)

type fakeReader struct {
	traffic map[string]hy2.Counter
	err     error
}

func (f *fakeReader) FetchTraffic(context.Context) (map[string]hy2.Counter, error) {
	return f.traffic, f.err
}

type fakeReporter struct {
	traffic []panel.Traffic
	err     error
}

func (f *fakeReporter) ReportTraffic(_ context.Context, traffic []panel.Traffic) error {
	f.traffic = append([]panel.Traffic(nil), traffic...)
	return f.err
}

func TestCollectorReportsDeltaAndPersistsState(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	state, err := LoadState(path)
	if err != nil {
		t.Fatal(err)
	}
	state.Replace(map[string]hy2.Counter{"7": {Tx: 100, Rx: 200}})
	if err := state.Save(); err != nil {
		t.Fatal(err)
	}
	reader := &fakeReader{traffic: map[string]hy2.Counter{
		"7":   {Tx: 150, Rx: 260},
		"9":   {Tx: 10, Rx: 20},
		"bad": {Tx: 99, Rx: 99},
	}}
	reporter := &fakeReporter{}
	collector := NewCollector(reader, reporter, state, time.Minute, false, discardLogger())
	if err := collector.Collect(context.Background()); err != nil {
		t.Fatal(err)
	}
	want := []panel.Traffic{
		{UserID: 7, Upload: 50, Download: 60},
		{UserID: 9, Upload: 10, Download: 20},
	}
	if !reflect.DeepEqual(reporter.traffic, want) {
		t.Fatalf("traffic = %#v, want %#v", reporter.traffic, want)
	}
	reloaded, err := LoadState(path)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(reloaded.Snapshot(), reader.traffic) {
		t.Fatalf("persisted state = %#v, want %#v", reloaded.Snapshot(), reader.traffic)
	}
}

func TestCollectorHandlesHY2CounterReset(t *testing.T) {
	state, err := LoadState(filepath.Join(t.TempDir(), "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	state.Replace(map[string]hy2.Counter{"7": {Tx: 1000, Rx: 2000}})
	reporter := &fakeReporter{}
	collector := NewCollector(
		&fakeReader{traffic: map[string]hy2.Counter{"7": {Tx: 5, Rx: 8}}},
		reporter, state, time.Minute, false, discardLogger(),
	)
	if err := collector.Collect(context.Background()); err != nil {
		t.Fatal(err)
	}
	want := []panel.Traffic{{UserID: 7, Upload: 5, Download: 8}}
	if !reflect.DeepEqual(reporter.traffic, want) {
		t.Fatalf("reset traffic = %#v, want %#v", reporter.traffic, want)
	}
}

func TestCollectorDoesNotAdvanceStateWhenReportFails(t *testing.T) {
	state, err := LoadState(filepath.Join(t.TempDir(), "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	state.Replace(map[string]hy2.Counter{"7": {Tx: 10, Rx: 20}})
	reporter := &fakeReporter{err: errors.New("panel unavailable")}
	collector := NewCollector(
		&fakeReader{traffic: map[string]hy2.Counter{"7": {Tx: 50, Rx: 80}}},
		reporter, state, time.Minute, false, discardLogger(),
	)
	if err := collector.Collect(context.Background()); err == nil {
		t.Fatal("expected report error")
	}
	want := map[string]hy2.Counter{"7": {Tx: 10, Rx: 20}}
	if !reflect.DeepEqual(state.Snapshot(), want) {
		t.Fatalf("state advanced after failed report: %#v", state.Snapshot())
	}
}

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}
