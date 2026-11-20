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
		http:    &http.Client{Timeout: 20 * time.Second},
	}
}

func (c *Client) Configured() bool { return c != nil && c.token != "" }

// KeyboardButton is one reply-keyboard button (label is sent back as text).
type KeyboardButton struct {
	Text string `json:"text"`
}

// ReplyKeyboard is a custom keyboard under the message field.
type ReplyKeyboard struct {
	Keyboard        [][]KeyboardButton `json:"keyboard"`
	ResizeKeyboard  bool               `json:"resize_keyboard"`
	OneTimeKeyboard bool               `json:"one_time_keyboard"`
	IsPersistent    bool               `json:"is_persistent"`
}

// RemoveKeyboard hides a custom keyboard.
type RemoveKeyboard struct {
	RemoveKeyboard bool `json:"remove_keyboard"`
}

type SendOpts struct {
	ThreadID       *int64
	ReplyToMessage *int64
	Keyboard       *ReplyKeyboard
	RemoveKeyboard bool
}

type SentMessage struct {
	MessageID int64 `json:"message_id"`
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
		return fmt.Errorf("telegram %s: request failed", method)
	}
	defer func() { _ = res.Body.Close() }()
	var r apiResponse
	if err := json.NewDecoder(io.LimitReader(res.Body, 2<<20)).Decode(&r); err != nil {
		return fmt.Errorf("telegram %s: unreadable answer", method)
	}
	if !r.OK {
		return fmt.Errorf("telegram %s: %s", method, r.Description)
	}
	if out != nil {
		return json.Unmarshal(r.Result, out)
	}
	return nil
}

func (c *Client) SendMessage(ctx context.Context, chatID int64, text string, opts SendOpts) (SentMessage, error) {
	body := map[string]any{"chat_id": chatID, "text": text}
	if opts.ThreadID != nil && *opts.ThreadID > 0 {
		body["message_thread_id"] = *opts.ThreadID
	}
	if opts.ReplyToMessage != nil && *opts.ReplyToMessage > 0 {
		body["reply_to_message_id"] = *opts.ReplyToMessage
	}
	switch {
	case opts.Keyboard != nil:
		body["reply_markup"] = opts.Keyboard
	case opts.RemoveKeyboard:
		body["reply_markup"] = RemoveKeyboard{RemoveKeyboard: true}
	}
	var out SentMessage
	err := c.call(ctx, "sendMessage", body, &out)
	return out, err
}

// Buttons builds a reply keyboard from row labels.
func Buttons(rows ...[]string) *ReplyKeyboard {
	kb := &ReplyKeyboard{ResizeKeyboard: true, OneTimeKeyboard: true}
	for _, row := range rows {
		var buttons []KeyboardButton
		for _, label := range row {
			label = strings.TrimSpace(label)
			if label == "" {
				continue
			}
			buttons = append(buttons, KeyboardButton{Text: label})
		}
		if len(buttons) > 0 {
			kb.Keyboard = append(kb.Keyboard, buttons)
		}
	}
	if len(kb.Keyboard) == 0 {
		return nil
	}
	return kb
}
