package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"sspanel-uim-hy2-adapter/internal/auth"
	"sspanel-uim-hy2-adapter/internal/config"
	"sspanel-uim-hy2-adapter/internal/httpserver"
	"sspanel-uim-hy2-adapter/internal/hy2"
	"sspanel-uim-hy2-adapter/internal/panel"
	"sspanel-uim-hy2-adapter/internal/stats"
)

var version = "dev"

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run() error {
	configPath := flag.String("config", "config.yaml", "path to the YAML configuration file")
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return nil
	}

	cfg, err := config.Load(*configPath)
	if err != nil {
		return err
	}
	logger := newLogger(cfg.Log.Level)
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	panelClient := panel.New(cfg.Panel.BaseURL, cfg.Panel.Key, cfg.Panel.NodeID, cfg.Panel.Timeout.Value(), cfg.Panel.InsecureSkipVerify)
	userSource, apiSource, err := buildUserSource(ctx, cfg, panelClient, logger)
	if err != nil {
		return err
	}
	defer userSource.Close()
	if apiSource != nil {
		go apiSource.Run(ctx)
	} else {
		// SSPanel-UIM updates node_heartbeat in GET /mod_mu/users. Database auth
		// bypasses that endpoint, so keep a lightweight ETag-backed heartbeat.
		go runPanelHeartbeat(ctx, panelClient, cfg.Panel.HeartbeatInterval.Value(), logger)
	}

	state, err := stats.LoadState(cfg.HY2.StateFile)
	if err != nil {
		return err
	}
	hy2Client := hy2.New(cfg.HY2.StatsURL, cfg.HY2.StatsSecret, cfg.HY2.Timeout.Value(), false)
	collector := stats.NewCollector(hy2Client, panelClient, state, cfg.HY2.PollInterval.Value(), cfg.HY2.RunOnStartup, logger)
	go collector.Run(ctx)

	httpServer := &http.Server{
		Addr:         cfg.Server.Listen,
		Handler:      httpserver.New(cfg.Server.AuthPath, cfg.Server.AuthToken, userSource, logger),
		ReadTimeout:  cfg.Server.ReadTime.Value(),
		WriteTimeout: cfg.Server.WriteTime.Value(),
		IdleTimeout:  60 * time.Second,
	}
	serverErrors := make(chan error, 1)
	go func() {
		logger.Info("adapter listening", "address", cfg.Server.Listen, "auth_path", cfg.Server.AuthPath, "source", cfg.UserSource.Mode, "version", version)
		serverErrors <- httpServer.ListenAndServe()
	}()

	select {
	case <-ctx.Done():
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer shutdownCancel()
		if err := httpServer.Shutdown(shutdownCtx); err != nil {
			return fmt.Errorf("shutdown HTTP server: %w", err)
		}
		logger.Info("adapter stopped")
		return nil
	case err := <-serverErrors:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return fmt.Errorf("serve HTTP: %w", err)
	}
}

func buildUserSource(ctx context.Context, cfg config.Config, panelClient *panel.Client, logger *slog.Logger) (auth.Source, *auth.API, error) {
	if cfg.UserSource.Mode == "api" {
		source := auth.NewAPI(
			panelClient,
			cfg.UserSource.CredentialFields,
			cfg.UserSource.API.RefreshInterval.Value(),
			cfg.UserSource.API.MaxStale.Value(),
			logger,
		)
		if err := source.InitialRefresh(ctx); err != nil {
			return nil, nil, err
		}
		return source, source, nil
	}
	source, err := auth.NewDatabase(
		ctx,
		cfg.UserSource.Database.DSN,
		cfg.Panel.NodeID,
		cfg.UserSource.CredentialFields,
		cfg.UserSource.Database.MaxOpenConns,
		cfg.UserSource.Database.MaxIdleConns,
		cfg.UserSource.Database.ConnMaxLifetime.Value(),
	)
	if err != nil {
		return nil, nil, err
	}
	return source, nil, nil
}

func newLogger(level string) *slog.Logger {
	levels := map[string]slog.Level{
		"debug": slog.LevelDebug,
		"info":  slog.LevelInfo,
		"warn":  slog.LevelWarn,
		"error": slog.LevelError,
	}
	return slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: levels[level]}))
}

func runPanelHeartbeat(ctx context.Context, client *panel.Client, interval time.Duration, logger *slog.Logger) {
	etag := ""
	heartbeat := func() {
		_, newETag, _, err := client.FetchUsers(ctx, etag)
		if err != nil {
			if !errors.Is(err, context.Canceled) {
				logger.Error("panel heartbeat failed", "error", err)
			}
			return
		}
		if newETag != "" {
			etag = newETag
		}
		logger.Debug("panel heartbeat succeeded")
	}
	heartbeat()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			heartbeat()
		}
	}
}
