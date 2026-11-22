package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/AGlElectronics/intercom/backend/internal/probe"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/AGlElectronics/intercom/backend/internal/bot"
	"github.com/AGlElectronics/intercom/backend/internal/feedbackclient"
	"github.com/AGlElectronics/intercom/backend/internal/store"
	"github.com/AGlElectronics/intercom/backend/internal/tasksclient"
	"github.com/AGlElectronics/intercom/backend/internal/telegram"
)

var version = "dev"

type config struct {
	HTTPAddr      string
	DatabaseURL   string
	BotToken      string
	BoardChatID   int64
	BoardThreadID *int64
	IdeasThreadID *int64
	TasksURL      string
	TasksToken    string
	FeedbackURL   string
	FeedbackToken string
}

func main() {
	// `server healthcheck` probes the running server's /livez
	// (Docker HEALTHCHECK / Compose; the image has no curl).
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		addr := os.Getenv("HTTP_ADDR")
		if addr == "" {
			addr = ":8080"
		}
		probe.Run(addr)
	}
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	cfg, err := loadConfig()
	if err != nil {
		logger.Error("invalid configuration", "error", err)
		os.Exit(1)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	st, err := store.Connect(ctx, cfg.DatabaseURL)
	if err != nil {
		logger.Error("database", "error", err)
		os.Exit(1)
	}
	defer st.Close()

	tg := telegram.New(cfg.BotToken, "")
	tasks := tasksclient.New(cfg.TasksURL, cfg.TasksToken)
	if tasks.Enabled() {
		logger.Info("intercom tasks bridge on", "url", cfg.TasksURL)
	} else {
		logger.Warn("intercom tasks bridge off: set TASKS_INTERNAL_URL and TASKS_SERVICE_TOKEN")
	}
	feedback := feedbackclient.New(cfg.FeedbackURL, cfg.FeedbackToken)
	if feedback.Enabled() {
		logger.Info("intercom feedback bridge on", "url", cfg.FeedbackURL)
	}
	b := bot.New(tg, st, tasks, feedback, bot.Config{
		BoardChatID:   cfg.BoardChatID,
		BoardThreadID: cfg.BoardThreadID,
		IdeasThreadID: cfg.IdeasThreadID,
	}, logger)
	go b.Run(ctx)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /livez", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{
			"status":           "ok",
			"version":          version,
			"telegram":         tg.Configured(),
			"board_chat_id":    cfg.BoardChatID,
			"board_thread_set": cfg.BoardThreadID != nil,
		})
	})
	mux.HandleFunc("GET /api/v1/board-relays", func(w http.ResponseWriter, r *http.Request) {
		list, err := st.ListBoardRelays(r.Context(), 50)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "list failed"})
			return
		}
		if list == nil {
			list = []store.BoardRelay{}
		}
		writeJSON(w, http.StatusOK, map[string]any{"relays": list})
	})
	mux.HandleFunc("GET /api/v1/ideas", func(w http.ResponseWriter, r *http.Request) {
		list, err := st.ListIdeas(r.Context(), 50)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "list failed"})
			return
		}
		if list == nil {
			list = []store.Idea{}
		}
		writeJSON(w, http.StatusOK, map[string]any{"ideas": list})
	})
	mux.HandleFunc("GET /api/v1/status", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{
			"version":          version,
			"module":           "intercom",
			"telegram":         tg.Configured(),
			"board_chat_id":    cfg.BoardChatID,
			"board_thread_set": cfg.BoardThreadID != nil,
			"ideas_thread_set": cfg.IdeasThreadID != nil,
		})
	})

	server := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           requestLog(logger, mux),
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	errs := make(chan error, 1)
	go func() {
		logger.Info("intercom backend listening",
			"address", cfg.HTTPAddr,
			"telegram", tg.Configured(),
			"board_chat", cfg.BoardChatID,
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
		HTTPAddr:    envOr("HTTP_ADDR", ":8080"),
		DatabaseURL: os.Getenv("DATABASE_URL"),
		BotToken:    firstNonEmpty(os.Getenv("INTERCOM_TELEGRAM_BOT_TOKEN"), os.Getenv("TELEGRAM_BOT_TOKEN")),
	}
	if cfg.DatabaseURL == "" {
		return config{}, errors.New("DATABASE_URL is required")
	}

	board := firstNonEmpty(os.Getenv("INTERCOM_BOARD_CHAT_ID"), os.Getenv("TELEGRAM_DEV_CATCHALL_CHAT_ID"))
	if board != "" {
		id, err := strconv.ParseInt(board, 10, 64)
		if err != nil {
			return config{}, fmt.Errorf("INTERCOM_BOARD_CHAT_ID: %w", err)
		}
		cfg.BoardChatID = id
	}

	thread := firstNonEmpty(os.Getenv("INTERCOM_BOARD_THREAD_ID"), os.Getenv("TELEGRAM_DEV_CATCHALL_THREAD_ID"))
	if thread != "" {
		id, err := strconv.ParseInt(thread, 10, 64)
		if err != nil {
			return config{}, fmt.Errorf("INTERCOM_BOARD_THREAD_ID: %w", err)
		}
		if id > 0 {
			cfg.BoardThreadID = &id
		}
	}

	if ideas := strings.TrimSpace(os.Getenv("INTERCOM_IDEAS_THREAD_ID")); ideas != "" {
		id, err := strconv.ParseInt(ideas, 10, 64)
		if err != nil {
			return config{}, fmt.Errorf("INTERCOM_IDEAS_THREAD_ID: %w", err)
		}
		if id > 0 {
			cfg.IdeasThreadID = &id
		}
	}
	cfg.TasksURL = firstNonEmpty(os.Getenv("TASKS_INTERNAL_URL"), "http://tasks-backend:8080")
	cfg.TasksToken = strings.TrimSpace(os.Getenv("TASKS_SERVICE_TOKEN"))
	cfg.FeedbackURL = firstNonEmpty(os.Getenv("FEEDBACK_INTERNAL_URL"), "http://feedback-backend:8080")
	cfg.FeedbackToken = firstNonEmpty(os.Getenv("FEEDBACK_SERVICE_TOKEN"), "feedback-dev-token")
	return cfg, nil
}

func envOr(key, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return fallback
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func requestLog(logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		logger.Info("http", "method", r.Method, "path", r.URL.Path, "duration_ms", time.Since(start).Milliseconds())
	})
}
