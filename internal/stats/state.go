package stats

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"sspanel-uim-hy2-adapter/internal/hy2"
)

const stateVersion = 1

type diskState struct {
	Version  int                    `json:"version"`
	Counters map[string]hy2.Counter `json:"counters"`
}

type State struct {
	path     string
	counters map[string]hy2.Counter
}

func LoadState(path string) (*State, error) {
	s := &State{path: path, counters: make(map[string]hy2.Counter)}
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read traffic state: %w", err)
	}
	var persisted diskState
	if err := json.Unmarshal(b, &persisted); err != nil {
		return nil, fmt.Errorf("decode traffic state: %w", err)
	}
	if persisted.Version != stateVersion {
		return nil, fmt.Errorf("unsupported traffic state version %d", persisted.Version)
	}
	if persisted.Counters != nil {
		s.counters = persisted.Counters
	}
	return s, nil
}

func (s *State) Snapshot() map[string]hy2.Counter {
	return cloneCounters(s.counters)
}

func (s *State) Replace(counters map[string]hy2.Counter) {
	s.counters = cloneCounters(counters)
}

func (s *State) Save() error {
	dir := filepath.Dir(s.path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create traffic state directory: %w", err)
	}
	f, err := os.CreateTemp(dir, ".traffic-state-*")
	if err != nil {
		return fmt.Errorf("create traffic state temp file: %w", err)
	}
	tempName := f.Name()
	defer os.Remove(tempName)
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		return fmt.Errorf("set traffic state permissions: %w", err)
	}
	encoder := json.NewEncoder(f)
	if err := encoder.Encode(diskState{Version: stateVersion, Counters: s.counters}); err != nil {
		f.Close()
		return fmt.Errorf("encode traffic state: %w", err)
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return fmt.Errorf("sync traffic state: %w", err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("close traffic state: %w", err)
	}
	if err := os.Rename(tempName, s.path); err != nil {
		return fmt.Errorf("replace traffic state: %w", err)
	}
	return nil
}

func cloneCounters(in map[string]hy2.Counter) map[string]hy2.Counter {
	out := make(map[string]hy2.Counter, len(in))
	for id, counter := range in {
		out[id] = counter
	}
	return out
}
