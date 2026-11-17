// Package tasksclient posts Telegram /idea captures into Tasks.
package tasksclient

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

type Client struct {
	baseURL string
	token   string
	http    *http.Client
}

func New(baseURL, token string) *Client {
	baseURL = strings.TrimRight(strings.TrimSpace(baseURL), "/")
	token = strings.TrimSpace(token)
	if baseURL == "" || token == "" {
		return nil
	}
	return &Client{
		baseURL: baseURL,
		token:   token,
		http:    &http.Client{Timeout: 15 * time.Second},
	}
}

func (c *Client) Enabled() bool { return c != nil }

type IdeaInput struct {
	Title           string `json:"title"`
	Body            string `json:"body"`
	SourceUserName  string `json:"source_user_name"`
	SourceChatTitle string `json:"source_chat_title"`
}

type IdeaResult struct {
	TaskKey   string `json:"task_key"`
	SpaceName string `json:"space_name"`
	ListName  string `json:"list_name"`
	Task      struct {
		ID string `json:"id"`
	} `json:"task"`
}

func (c *Client) CreateIdea(ctx context.Context, in IdeaInput) (IdeaResult, error) {
	if !c.Enabled() {
		return IdeaResult{}, fmt.Errorf("tasks client not configured")
	}
	body, err := json.Marshal(in)
	if err != nil {
		return IdeaResult{}, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/api/internal/ideas", bytes.NewReader(body))
	if err != nil {
		return IdeaResult{}, err
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Content-Type", "application/json")
	res, err := c.http.Do(req)
	if err != nil {
		return IdeaResult{}, err
	}
	defer func() { _ = res.Body.Close() }()
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return IdeaResult{}, fmt.Errorf("tasks ideas API HTTP %d: %s", res.StatusCode, strings.TrimSpace(string(raw)))
	}
	var out IdeaResult
	if err := json.Unmarshal(raw, &out); err != nil {
		return IdeaResult{}, err
	}
	return out, nil
}
