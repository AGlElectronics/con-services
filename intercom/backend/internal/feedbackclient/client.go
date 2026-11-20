package feedbackclient

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
	if baseURL == "" {
		return nil
	}
	return &Client{
		baseURL: baseURL,
		token:   token,
		http:    &http.Client{Timeout: 15 * time.Second},
	}
}

func (c *Client) Enabled() bool { return c != nil }

type Message struct {
	ChatID         int64  `json:"chat_id"`
	ChatType       string `json:"chat_type"`
	MessageID      int64  `json:"message_id"`
	Text           string `json:"text"`
	TelegramUserID int64  `json:"telegram_user_id"`
	TelegramName   string `json:"telegram_name"`
}

type Result struct {
	Handled bool   `json:"handled"`
	Reply   string `json:"reply"`
}

func (c *Client) HandleMessage(ctx context.Context, msg Message) (Result, error) {
	if !c.Enabled() {
		return Result{}, fmt.Errorf("feedback client not configured")
	}
	body, err := json.Marshal(msg)
	if err != nil {
		return Result{}, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/api/v1/telegram/message", bytes.NewReader(body))
	if err != nil {
		return Result{}, err
	}
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	req.Header.Set("Content-Type", "application/json")
	res, err := c.http.Do(req)
	if err != nil {
		return Result{}, err
	}
	defer func() { _ = res.Body.Close() }()
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return Result{}, fmt.Errorf("feedback HTTP %d: %s", res.StatusCode, strings.TrimSpace(string(raw)))
	}
	var out Result
	if err := json.Unmarshal(raw, &out); err != nil {
		return Result{}, err
	}
	return out, nil
}
