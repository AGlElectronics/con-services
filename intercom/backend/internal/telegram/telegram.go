// Package telegram is a minimal Bot API client for Intercom: long polling,
// sendMessage with optional forum topics, and reply threading.
package telegram

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const DefaultBaseURL = "https://api.telegram.org"
const PollTimeout = 25 * time.Second

var ErrNotConfigured = errors.New("telegram bot token not configured")

type Client struct {
	token   string
	baseURL string
	http    *http.Client
}

func New(token, baseURL string) *Client {
	if baseURL == "" {
		baseURL = DefaultBaseURL
	}
	return &Client{
		token:   token,
		baseURL: strings.TrimRight(baseURL, "/"),
		http:    &http.Client{Timeout: PollTimeout + 15*time.Second},
	}
}

func (c *Client) Configured() bool { return c != nil && c.token != "" }

type Update struct {
	UpdateID int64    `json:"update_id"`
	Message  *Message `json:"message"`
}

type Message struct {
	MessageID           int64    `json:"message_id"`
	MessageThreadID     int64    `json:"message_thread_id"`
	Date                int64    `json:"date"`
	Text                string   `json:"text"`
	Chat                Chat     `json:"chat"`
	From                *User    `json:"from"`
	ReplyToMessage      *Message `json:"reply_to_message"`
	IsTopicMessage      bool     `json:"is_topic_message"`
}

type Chat struct {
	ID    int64  `json:"id"`
	Type  string `json:"type"`
	Title string `json:"title"`
}

type User struct {
	ID        int64  `json:"id"`
	IsBot     bool   `json:"is_bot"`
	FirstName string `json:"first_name"`
	LastName  string `json:"last_name"`
	Username  string `json:"username"`
}

func (u *User) Display() string {
	if u == nil {
		return "someone"
	}
	name := strings.TrimSpace(u.FirstName + " " + u.LastName)
	if name == "" {
		name = "someone"
	}
	if u.Username != "" {
		return fmt.Sprintf("%s (@%s)", name, u.Username)
	}
	return name
}

type SentMessage struct {
	MessageID int64 `json:"message_id"`
	Chat      Chat  `json:"chat"`
}

type apiResponse struct {
	OK          bool            `json:"ok"`
	Result      json.RawMessage `json:"result"`
	Description string          `json:"description"`
}

func (c *Client) call(ctx context.Context, method string, params any, out any) error {
	if !c.Configured() {
		return ErrNotConfigured
	}
	body, err := json.Marshal(params)
	if err != nil {
		return err
	}
	endpoint := c.baseURL + "/bot" + url.PathEscape(c.token) + "/" + method
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	res, err := c.http.Do(req)
	if err != nil {
		var uerr *url.Error
		if errors.As(err, &uerr) {
			return fmt.Errorf("telegram %s: %w", method, uerr.Err)
		}
		return fmt.Errorf("telegram %s: request failed", method)
	}
	defer func() { _ = res.Body.Close() }()
	var r apiResponse
	if err := json.NewDecoder(io.LimitReader(res.Body, 4<<20)).Decode(&r); err != nil {
		return fmt.Errorf("telegram %s: HTTP %d, unreadable answer", method, res.StatusCode)
	}
	if !r.OK {
		return fmt.Errorf("telegram %s: %s", method, r.Description)
	}
	if out != nil {
		return json.Unmarshal(r.Result, out)
	}
	return nil
}

func (c *Client) GetUpdates(ctx context.Context, offset int64) ([]Update, error) {
	var out []Update
	err := c.call(ctx, "getUpdates", map[string]any{
		"offset":          offset,
		"timeout":         int(PollTimeout / time.Second),
		"allowed_updates": []string{"message"},
	}, &out)
	return out, err
}

type SendOpts struct {
	ThreadID       *int64
	ReplyToMessage *int64
}

func (c *Client) SendMessage(ctx context.Context, chatID int64, text string, opts SendOpts) (SentMessage, error) {
	body := map[string]any{"chat_id": chatID, "text": text}
	if opts.ThreadID != nil && *opts.ThreadID > 0 {
		body["message_thread_id"] = *opts.ThreadID
	}
	if opts.ReplyToMessage != nil && *opts.ReplyToMessage > 0 {
		body["reply_to_message_id"] = *opts.ReplyToMessage
	}
	var out SentMessage
	err := c.call(ctx, "sendMessage", body, &out)
	return out, err
}

func (c *Client) SetMyCommands(ctx context.Context, commands []map[string]string) error {
	return c.call(ctx, "setMyCommands", map[string]any{"commands": commands}, nil)
}

func (c *Client) DeleteWebhook(ctx context.Context) error {
	return c.call(ctx, "deleteWebhook", map[string]any{"drop_pending_updates": false}, nil)
}

func (c *Client) BotUsername(ctx context.Context) (string, error) {
	var me struct {
		Username string `json:"username"`
	}
	if err := c.call(ctx, "getMe", map[string]any{}, &me); err != nil {
		return "", err
	}
	return me.Username, nil
}
