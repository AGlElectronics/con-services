package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/AGlElectronics/feedback/backend/internal/probe"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/AGlElectronics/feedback/backend/internal/flow"
	"github.com/AGlElectronics/feedback/backend/internal/store"
	"github.com/AGlElectronics/feedback/backend/internal/telegram"
)

var version = "dev"

type config struct {
	HTTPAddr      string
	DatabaseURL   string
	BotToken      string
	BoardChatID   int64
	BoardThreadID *int64
	Departments   []string
	ServiceToken  string
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
	eng := flow.New(st, tg, flow.Config{
		Departments:   cfg.Departments,
		BoardChatID:   cfg.BoardChatID,
		BoardThreadID: cfg.BoardThreadID,
	}, logger)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /livez", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{
			"status":        "ok",
			"version":       version,
			"telegram":      tg.Configured(),
			"board_chat_id": cfg.BoardChatID,
			"departments":   cfg.Departments,
		})
	})
	mux.HandleFunc("GET /api/v1/status", func(w http.ResponseWriter, r *http.Request) {
		total, pos, neg, err := st.Counts(r.Context())
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "counts failed"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"version":     version,
			"module":      "feedback",
			"telegram":    tg.Configured(),
			"departments": cfg.Departments,
			"counts": map[string]int{
				"total":    total,
				"positive": pos,
				"negative": neg,
			},
		})
	})
	mux.HandleFunc("GET /api/v1/submissions", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		list, err := st.ListSubmissions(r.Context(), q.Get("polarity"), q.Get("department"), 50)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "list failed"})
			return
		}
		if list == nil {
			list = []store.Submission{}
		}
		writeJSON(w, http.StatusOK, map[string]any{"submissions": list})
	})
	mux.HandleFunc("GET /api/v1/departments", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"departments": cfg.Departments})
	})
	mux.HandleFunc("POST /api/v1/telegram/message", func(w http.ResponseWriter, r *http.Request) {
		if !authorize(r, cfg.ServiceToken) {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
			return
		}
		var msg flow.Message
		if err := json.NewDecoder(r.Body).Decode(&msg); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid json"})
			return
		}
		res, err := eng.Handle(r.Context(), msg)
		if err != nil {
			logger.Warn("feedback handle failed", "error", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "handle failed"})
			return
		}
		if res.Handled && res.Reply != "" && tg.Configured() {
			replyTo := msg.MessageID
			opts := telegram.SendOpts{
				ReplyToMessage: &replyTo,
				Keyboard:       res.Keyboard,
				RemoveKeyboard: res.RemoveKeyboard,
			}
			if _, err := tg.SendMessage(r.Context(), msg.ChatID, res.Reply, opts); err != nil {
				logger.Warn("feedback reply failed", "error", err)
			}
		}
		writeJSON(w, http.StatusOK, res)
	})

	server := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           requestLog(logger, mux),
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	errs := make(chan error, 1)
	go func() {
		logger.Info("feedback backend listening",
			"address", cfg.HTTPAddr,
			"telegram", tg.Configured(),
			"departments", len(cfg.Departments),
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
	_ = server.Shutdown(shutdownCtx)
}

func loadConfig() (config, error) {
	cfg := config{
		HTTPAddr:     envOr("HTTP_ADDR", ":8080"),
		DatabaseURL:  os.Getenv("DATABASE_URL"),
		BotToken:     firstNonEmpty(os.Getenv("FEEDBACK_TELEGRAM_BOT_TOKEN"), os.Getenv("TELEGRAM_BOT_TOKEN")),
		ServiceToken: firstNonEmpty(os.Getenv("FEEDBACK_SERVICE_TOKEN"), "feedback-dev-token"),
		Departments:  parseDepartments(os.Getenv("FEEDBACK_DEPARTMENTS")),
	}
	if cfg.DatabaseURL == "" {
		return config{}, errors.New("DATABASE_URL is required")
	}
	board := firstNonEmpty(os.Getenv("FEEDBACK_BOARD_CHAT_ID"), os.Getenv("INTERCOM_BOARD_CHAT_ID"), os.Getenv("TELEGRAM_DEV_CATCHALL_CHAT_ID"))
	if board != "" {
		id, err := strconv.ParseInt(board, 10, 64)
		if err != nil {
			return config{}, fmt.Errorf("board chat id: %w", err)
		}
		cfg.BoardChatID = id
	}
	thread := firstNonEmpty(os.Getenv("FEEDBACK_BOARD_THREAD_ID"), os.Getenv("INTERCOM_BOARD_THREAD_ID"), os.Getenv("TELEGRAM_DEV_CATCHALL_THREAD_ID"))
	if thread != "" {
		id, err := strconv.ParseInt(thread, 10, 64)
		if err != nil {
			return config{}, fmt.Errorf("board thread id: %w", err)
		}
		if id > 0 {
			cfg.BoardThreadID = &id
		}
	}
	return cfg, nil
}

func parseDepartments(raw string) []string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return []string{"Board", "Ops", "HR", "Tech", "Front of House"}
	}
	parts := strings.Split(raw, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

func authorize(r *http.Request, token string) bool {
	if token == "" {
		return true
	}
	got, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	return ok && strings.TrimSpace(got) == token
}

func envOr(k, d string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	return d
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
