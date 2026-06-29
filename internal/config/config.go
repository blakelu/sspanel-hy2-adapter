package config

import (
	"errors"
	"fmt"
	"net/url"
	"os"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

type Duration time.Duration

func (d *Duration) UnmarshalText(text []byte) error {
	v, err := time.ParseDuration(string(text))
	if err != nil {
		return err
	}
	*d = Duration(v)
	return nil
}

func (d Duration) Value() time.Duration { return time.Duration(d) }

type Config struct {
	Server     ServerConfig     `yaml:"server"`
	Panel      PanelConfig      `yaml:"panel"`
	UserSource UserSourceConfig `yaml:"user_source"`
	HY2        HY2Config        `yaml:"hy2"`
	Log        LogConfig        `yaml:"log"`
}

type ServerConfig struct {
	Listen    string   `yaml:"listen"`
	AuthPath  string   `yaml:"auth_path"`
	AuthToken string   `yaml:"auth_token"`
	ReadTime  Duration `yaml:"read_timeout"`
	WriteTime Duration `yaml:"write_timeout"`
}

type PanelConfig struct {
	BaseURL            string   `yaml:"base_url"`
	Key                string   `yaml:"key"`
	NodeID             int64    `yaml:"node_id"`
	Timeout            Duration `yaml:"timeout"`
	HeartbeatInterval  Duration `yaml:"heartbeat_interval"`
	InsecureSkipVerify bool     `yaml:"insecure_skip_verify"`
}

type UserSourceConfig struct {
	Mode             string         `yaml:"mode"`
	CredentialFields []string       `yaml:"credential_fields"`
	API              APIConfig      `yaml:"api"`
	Database         DatabaseConfig `yaml:"database"`
}

type APIConfig struct {
	RefreshInterval Duration `yaml:"refresh_interval"`
	MaxStale        Duration `yaml:"max_stale"`
}

type DatabaseConfig struct {
	DSN             string   `yaml:"dsn"`
	MaxOpenConns    int      `yaml:"max_open_conns"`
	MaxIdleConns    int      `yaml:"max_idle_conns"`
	ConnMaxLifetime Duration `yaml:"conn_max_lifetime"`
}

type HY2Config struct {
	StatsURL     string   `yaml:"stats_url"`
	StatsSecret  string   `yaml:"stats_secret"`
	Timeout      Duration `yaml:"timeout"`
	PollInterval Duration `yaml:"poll_interval"`
	StateFile    string   `yaml:"state_file"`
	RunOnStartup bool     `yaml:"run_on_startup"`
}

type LogConfig struct {
	Level string `yaml:"level"`
}

func Default() Config {
	return Config{
		Server: ServerConfig{
			Listen:    "127.0.0.1:8080",
			AuthPath:  "/auth",
			ReadTime:  Duration(5 * time.Second),
			WriteTime: Duration(5 * time.Second),
		},
		Panel: PanelConfig{
			Timeout:           Duration(5 * time.Second),
			HeartbeatInterval: Duration(60 * time.Second),
		},
		UserSource: UserSourceConfig{
			Mode:             "api",
			CredentialFields: []string{"uuid"},
			API: APIConfig{
				RefreshInterval: Duration(30 * time.Second),
				MaxStale:        Duration(5 * time.Minute),
			},
			Database: DatabaseConfig{
				MaxOpenConns:    10,
				MaxIdleConns:    5,
				ConnMaxLifetime: Duration(5 * time.Minute),
			},
		},
		HY2: HY2Config{
			StatsURL:     "http://127.0.0.1:9999",
			Timeout:      Duration(5 * time.Second),
			PollInterval: Duration(60 * time.Second),
			StateFile:    "./data/traffic-state.json",
			RunOnStartup: true,
		},
		Log: LogConfig{Level: "info"},
	}
}

func Load(path string) (Config, error) {
	cfg := Default()
	b, err := os.ReadFile(path)
	if err != nil {
		return Config{}, fmt.Errorf("read config: %w", err)
	}
	decoder := yaml.NewDecoder(strings.NewReader(os.ExpandEnv(string(b))))
	decoder.KnownFields(true)
	if err := decoder.Decode(&cfg); err != nil {
		return Config{}, fmt.Errorf("parse config: %w", err)
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	cfg.Panel.BaseURL = strings.TrimRight(cfg.Panel.BaseURL, "/")
	cfg.HY2.StatsURL = strings.TrimRight(cfg.HY2.StatsURL, "/")
	return cfg, nil
}

func (c Config) Validate() error {
	var errs []error
	if c.Server.Listen == "" {
		errs = append(errs, errors.New("server.listen is required"))
	}
	if !strings.HasPrefix(c.Server.AuthPath, "/") || strings.Contains(c.Server.AuthPath, "?") {
		errs = append(errs, errors.New("server.auth_path must be an absolute path without a query string"))
	}
	if c.Server.ReadTime.Value() <= 0 || c.Server.WriteTime.Value() <= 0 {
		errs = append(errs, errors.New("server timeouts must be positive"))
	}
	if err := validateHTTPURL("panel.base_url", c.Panel.BaseURL); err != nil {
		errs = append(errs, err)
	}
	if c.Panel.Key == "" {
		errs = append(errs, errors.New("panel.key is required"))
	}
	if c.Panel.NodeID <= 0 {
		errs = append(errs, errors.New("panel.node_id must be positive"))
	}
	if c.Panel.Timeout.Value() <= 0 {
		errs = append(errs, errors.New("panel.timeout must be positive"))
	}
	if c.Panel.HeartbeatInterval.Value() <= 0 {
		errs = append(errs, errors.New("panel.heartbeat_interval must be positive"))
	}
	if len(c.UserSource.CredentialFields) == 0 {
		errs = append(errs, errors.New("user_source.credential_fields must not be empty"))
	}
	allowed := map[string]bool{"uuid": true, "passwd": true}
	if c.UserSource.Mode == "database" {
		allowed["email"] = true
		allowed["user_name"] = true
	}
	for _, field := range c.UserSource.CredentialFields {
		if !allowed[field] {
			errs = append(errs, fmt.Errorf("credential field %q is not supported in %s mode", field, c.UserSource.Mode))
		}
	}
	switch c.UserSource.Mode {
	case "api":
		if c.UserSource.API.RefreshInterval.Value() <= 0 {
			errs = append(errs, errors.New("user_source.api.refresh_interval must be positive"))
		}
		if c.UserSource.API.MaxStale.Value() <= 0 {
			errs = append(errs, errors.New("user_source.api.max_stale must be positive"))
		}
		if c.UserSource.API.MaxStale.Value() < c.UserSource.API.RefreshInterval.Value() {
			errs = append(errs, errors.New("user_source.api.max_stale must not be shorter than refresh_interval"))
		}
	case "database":
		if c.UserSource.Database.DSN == "" {
			errs = append(errs, errors.New("user_source.database.dsn is required in database mode"))
		}
		if c.UserSource.Database.MaxOpenConns <= 0 || c.UserSource.Database.MaxIdleConns < 0 {
			errs = append(errs, errors.New("database connection limits are invalid"))
		}
		if c.UserSource.Database.ConnMaxLifetime.Value() <= 0 {
			errs = append(errs, errors.New("user_source.database.conn_max_lifetime must be positive"))
		}
	default:
		errs = append(errs, fmt.Errorf("user_source.mode must be api or database, got %q", c.UserSource.Mode))
	}
	if err := validateHTTPURL("hy2.stats_url", c.HY2.StatsURL); err != nil {
		errs = append(errs, err)
	}
	if c.HY2.Timeout.Value() <= 0 || c.HY2.PollInterval.Value() <= 0 {
		errs = append(errs, errors.New("hy2 timeout and poll_interval must be positive"))
	}
	if c.HY2.StateFile == "" {
		errs = append(errs, errors.New("hy2.state_file is required"))
	}
	if c.Log.Level != "debug" && c.Log.Level != "info" && c.Log.Level != "warn" && c.Log.Level != "error" {
		errs = append(errs, fmt.Errorf("unsupported log.level %q", c.Log.Level))
	}
	return errors.Join(errs...)
}

func validateHTTPURL(name, raw string) error {
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") {
		return fmt.Errorf("%s must be a valid http(s) URL", name)
	}
	return nil
}
