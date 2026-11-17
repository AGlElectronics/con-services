package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

var version = "dev"

type config struct {
	HTTPAddr     string
	AuthMode     string
	PollInterval time.Duration
	PullTimeout  time.Duration
	ServiceToken string
	Sources      []source
}

type source struct {
	Name string
	URL  string
}

type metric struct {
	Key   string  `json:"key"`
	Label string  `json:"label"`
	Value float64 `json:"value"`
	Unit  string  `json:"unit"`
}

type pullResponse struct {
	SchemaVersion int       `json:"schema_version"`
	Module        string    `json:"module"`
	GeneratedAt   time.Time `json:"generated_at"`
	Metrics       []metric  `json:"metrics"`
}

type sourceState struct {
	Name        string
	URL         string
	LastAttempt time.Time
	LastSuccess time.Time
	GeneratedAt time.Time
	Metrics     []metric
	Error       string
}

type dashboardSummary struct {
	ConfiguredSources int     `json:"configured_sources"`
	ReportingSources  int     `json:"reporting_sources"`
	StaleSources      int     `json:"stale_sources"`
	Metrics           int     `json:"metrics"`
	CountTotal        float64 `json:"count_total"`
}

type dashboardSource struct {
	Name        string     `json:"name"`
	Status      string     `json:"status"`
	GeneratedAt *time.Time `json:"generated_at,omitempty"`
	LastSuccess *time.Time `json:"last_success,omitempty"`
	Error       string     `json:"error,omitempty"`
	Metrics     []metric   `json:"metrics"`
}

type dashboardResponse struct {
	Version             string            `json:"version"`
	GeneratedAt         time.Time         `json:"generated_at"`
	PollIntervalSeconds int64             `json:"poll_interval_seconds"`
	Summary             dashboardSummary  `json:"summary"`
	Sources             []dashboardSource `json:"sources"`
}

type aggregator struct {
	mu           sync.RWMutex
	states       map[string]sourceState
	sources      []source
	interval     time.Duration
	serviceToken string
	client       *http.Client
	logger       *slog.Logger
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	cfg, err := loadConfig()
	if err != nil {
		logger.Error("invalid configuration", "error", err)
		os.Exit(1)
	}

	agg := newAggregator(cfg, logger)
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go agg.run(ctx)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /livez", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "version": version})
	})
	mux.HandleFunc("GET /api/v1/dashboard", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		writeJSON(w, http.StatusOK, agg.dashboard(time.Now().UTC()))
	})

	server := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           requestLog(logger, mux),
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	errs := make(chan error, 1)
	go func() {
		logger.Info("stats backend listening",
			"address", cfg.HTTPAddr,
			"auth_mode", cfg.AuthMode,
			"poll_interval", cfg.PollInterval,
			"sources", len(cfg.Sources),
			"version", version,
		)
		errs <- server.ListenAndServe()
	}()

	select {
	case <-ctx.Done():
	case err := <-errs:
		if !errors.Is(err, http.ErrServerClosed) {
			logger.Error("server stopped", "error", err)
			os.Exit(1)
		}
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := server.Shutdown(shutdownCtx); err != nil {
		logger.Error("server shutdown failed", "error", err)
	}
}

func loadConfig() (config, error) {
	cfg := config{
		HTTPAddr:     envOr("HTTP_ADDR", ":8080"),
		AuthMode:     envOr("AUTH_MODE", "dev"),
		ServiceToken: os.Getenv("STATS_SERVICE_TOKEN"),
	}
	if cfg.AuthMode != "dev" {
		return config{}, fmt.Errorf("AUTH_MODE=%q is not supported by the 1.1 scaffold; use dev", cfg.AuthMode)
	}

	var err error
	cfg.PollInterval, err = durationEnv("STATS_POLL_INTERVAL", 2*time.Minute)
	if err != nil {
		return config{}, err
	}
	if cfg.PollInterval < time.Minute || cfg.PollInterval > 5*time.Minute {
		return config{}, errors.New("STATS_POLL_INTERVAL must be between 1m and 5m")
	}

	cfg.PullTimeout, err = durationEnv("STATS_PULL_TIMEOUT", 10*time.Second)
	if err != nil {
		return config{}, err
	}
	if cfg.PullTimeout <= 0 || cfg.PullTimeout > 30*time.Second {
		return config{}, errors.New("STATS_PULL_TIMEOUT must be greater than 0 and at most 30s")
	}

	cfg.Sources, err = parseSources(os.Getenv("STATS_SOURCES"))
	if err != nil {
		return config{}, err
	}
	return cfg, nil
}

func envOr(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}

func durationEnv(name string, fallback time.Duration) (time.Duration, error) {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback, nil
	}
	parsed, err := time.ParseDuration(value)
	if err != nil {
		return 0, fmt.Errorf("%s: %w", name, err)
	}
	return parsed, nil
}

func parseSources(raw string) ([]source, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, nil
	}

	seen := make(map[string]bool)
	var sources []source
	for _, entry := range strings.Split(raw, ",") {
		name, address, ok := strings.Cut(strings.TrimSpace(entry), "=")
		name, address = strings.TrimSpace(name), strings.TrimSpace(address)
		if !ok || name == "" || address == "" {
			return nil, fmt.Errorf("invalid STATS_SOURCES entry %q; want module=https://host/api/internal/stats", entry)
		}
		if seen[name] {
			return nil, fmt.Errorf("duplicate STATS_SOURCES module %q", name)
		}
		parsed, err := url.ParseRequestURI(address)
		if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
			return nil, fmt.Errorf("invalid URL for STATS_SOURCES module %q", name)
		}
		seen[name] = true
		sources = append(sources, source{Name: name, URL: address})
	}
	return sources, nil
}

func newAggregator(cfg config, logger *slog.Logger) *aggregator {
	states := make(map[string]sourceState, len(cfg.Sources))
	for _, source := range cfg.Sources {
		states[source.Name] = sourceState{Name: source.Name, URL: source.URL, Metrics: []metric{}}
	}
	return &aggregator{
		states:       states,
		sources:      cfg.Sources,
		interval:     cfg.PollInterval,
		serviceToken: cfg.ServiceToken,
		client:       &http.Client{Timeout: cfg.PullTimeout},
		logger:       logger,
	}
}

func (a *aggregator) run(ctx context.Context) {
	a.collect(ctx)
	ticker := time.NewTicker(a.interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			a.collect(ctx)
		}
	}
}

func (a *aggregator) collect(ctx context.Context) {
	var wg sync.WaitGroup
	for _, configured := range a.sources {
		wg.Add(1)
		go func() {
			defer wg.Done()
			a.pull(ctx, configured)
		}()
	}
	wg.Wait()
}

func (a *aggregator) pull(ctx context.Context, configured source) {
	attemptedAt := time.Now().UTC()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, configured.URL, nil)
	if err == nil && a.serviceToken != "" {
		req.Header.Set("Authorization", "Bearer "+a.serviceToken)
	}
	if err != nil {
		a.recordError(configured.Name, attemptedAt, err)
		return
	}
	req.Header.Set("Accept", "application/json")

	resp, err := a.client.Do(req)
	if err != nil {
		a.recordError(configured.Name, attemptedAt, err)
		return
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<20))
		a.recordError(configured.Name, attemptedAt, fmt.Errorf("source returned HTTP %d", resp.StatusCode))
		return
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, (1<<20)+1))
	if err != nil {
		a.recordError(configured.Name, attemptedAt, fmt.Errorf("read response: %w", err))
		return
	}
	if len(body) > 1<<20 {
		a.recordError(configured.Name, attemptedAt, errors.New("response exceeds 1 MiB"))
		return
	}

	var payload pullResponse
	if err := json.Unmarshal(body, &payload); err != nil {
		a.recordError(configured.Name, attemptedAt, fmt.Errorf("decode response: %w", err))
		return
	}
	if err := validatePull(configured.Name, payload); err != nil {
		a.recordError(configured.Name, attemptedAt, err)
		return
	}

	a.mu.Lock()
	a.states[configured.Name] = sourceState{
		Name:        configured.Name,
		URL:         configured.URL,
		LastAttempt: attemptedAt,
		LastSuccess: time.Now().UTC(),
		GeneratedAt: payload.GeneratedAt,
		Metrics:     payload.Metrics,
	}
	a.mu.Unlock()
	a.logger.Info("stats source collected", "module", configured.Name, "metrics", len(payload.Metrics))
}

func validatePull(expectedModule string, payload pullResponse) error {
	if payload.SchemaVersion != 1 {
		return fmt.Errorf("unsupported schema_version %d", payload.SchemaVersion)
	}
	if payload.Module != expectedModule {
		return fmt.Errorf("source module %q does not match configured name %q", payload.Module, expectedModule)
	}
	if payload.GeneratedAt.IsZero() {
		return errors.New("generated_at is required")
	}
	seen := make(map[string]bool)
	for i, item := range payload.Metrics {
		if strings.TrimSpace(item.Key) == "" || strings.TrimSpace(item.Label) == "" || strings.TrimSpace(item.Unit) == "" {
			return fmt.Errorf("metric %d requires key, label and unit", i)
		}
		if seen[item.Key] {
			return fmt.Errorf("duplicate metric key %q", item.Key)
		}
		if math.IsNaN(item.Value) || math.IsInf(item.Value, 0) {
			return fmt.Errorf("metric %q has a non-finite value", item.Key)
		}
		seen[item.Key] = true
	}
	return nil
}

func (a *aggregator) recordError(name string, attemptedAt time.Time, err error) {
	a.mu.Lock()
	state := a.states[name]
	state.LastAttempt = attemptedAt
	state.Error = err.Error()
	a.states[name] = state
	a.mu.Unlock()
	a.logger.Warn("stats source collection failed", "module", name, "error", err)
}

func (a *aggregator) dashboard(now time.Time) dashboardResponse {
	a.mu.RLock()
	defer a.mu.RUnlock()

	result := dashboardResponse{
		Version:             version,
		GeneratedAt:         now,
		PollIntervalSeconds: int64(a.interval.Seconds()),
		Summary: dashboardSummary{
			ConfiguredSources: len(a.sources),
		},
		Sources: make([]dashboardSource, 0, len(a.sources)),
	}

	for _, configured := range a.sources {
		state := a.states[configured.Name]
		view := dashboardSource{
			Name:    state.Name,
			Status:  "waiting",
			Error:   state.Error,
			Metrics: append([]metric(nil), state.Metrics...),
		}
		if !state.LastSuccess.IsZero() {
			generatedAt, lastSuccess := state.GeneratedAt, state.LastSuccess
			view.GeneratedAt, view.LastSuccess = &generatedAt, &lastSuccess
			view.Status = "ok"
			result.Summary.ReportingSources++
		}
		if state.Error != "" {
			view.Status = "error"
		}
		if state.LastSuccess.IsZero() || now.Sub(state.LastSuccess) > 2*a.interval {
			if !state.LastAttempt.IsZero() {
				view.Status = "stale"
			}
			result.Summary.StaleSources++
		}

		result.Summary.Metrics += len(state.Metrics)
		for _, item := range state.Metrics {
			if item.Unit == "count" {
				result.Summary.CountTotal += item.Value
			}
		}
		result.Sources = append(result.Sources, view)
	}
	return result
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		slog.Error("write JSON response", "error", err)
	}
}

func requestLog(logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		logger.Info("request",
			"method", r.Method,
			"path", r.URL.Path,
			"duration_ms", strconv.FormatInt(time.Since(start).Milliseconds(), 10),
		)
	})
}
