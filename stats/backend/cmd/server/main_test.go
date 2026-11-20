package main

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestParseSources(t *testing.T) {
	sources, err := parseSources("desk=http://desk-backend:8080/api/internal/stats, learn=https://learn.example.test/api/internal/stats")
	if err != nil {
		t.Fatal(err)
	}
	if len(sources) != 2 || sources[0].Name != "desk" || sources[1].Name != "learn" {
		t.Fatalf("unexpected sources: %#v", sources)
	}

	if _, err := parseSources("desk=ftp://example.test/stats"); err == nil {
		t.Fatal("expected unsupported source URL to fail")
	}
	if _, err := parseSources("desk=http://one,desk=http://two"); err == nil {
		t.Fatal("expected duplicate source to fail")
	}
}

func TestAggregatorPullAndDashboard(t *testing.T) {
	generatedAt := time.Date(2026, 11, 17, 12, 0, 0, 0, time.UTC)
	sourceServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "Bearer test-token" {
			t.Fatalf("unexpected Authorization header: %q", got)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{
			"schema_version": 1,
			"module": "desk",
			"generated_at": "2026-11-17T12:00:00Z",
			"metrics": [
				{"key":"open_conversations","label":"Open conversations","value":12,"unit":"count"},
				{"key":"response_hours","label":"Response time","value":1.5,"unit":"hours"}
			]
		}`)
	}))
	defer sourceServer.Close()

	cfg := config{
		PollInterval: time.Minute,
		PullTimeout:  time.Second,
		ServiceToken: "test-token",
		Sources:      []source{{Name: "desk", URL: sourceServer.URL}},
	}
	agg := newAggregator(cfg, slog.New(slog.NewTextHandler(io.Discard, nil)))
	agg.collect(t.Context())

	got := agg.dashboard(generatedAt.Add(time.Minute))
	if got.Summary.ReportingSources != 1 || got.Summary.Metrics != 2 || got.Summary.CountTotal != 12 {
		t.Fatalf("unexpected summary: %#v", got.Summary)
	}
	if len(got.Sources) != 1 || got.Sources[0].Status != "ok" {
		t.Fatalf("unexpected sources: %#v", got.Sources)
	}
}

func TestValidatePullRejectsWrongModuleAndDuplicateKeys(t *testing.T) {
	payload := pullResponse{
		SchemaVersion: 1,
		Module:        "learn",
		GeneratedAt:   time.Now(),
		Metrics:       []metric{{Key: "courses", Label: "Courses", Value: 2, Unit: "count"}},
	}
	if err := validatePull("desk", payload); err == nil {
		t.Fatal("expected module mismatch to fail")
	}

	payload.Module = "desk"
	payload.Metrics = append(payload.Metrics, payload.Metrics[0])
	if err := validatePull("desk", payload); err == nil {
		t.Fatal("expected duplicate metric key to fail")
	}
}
