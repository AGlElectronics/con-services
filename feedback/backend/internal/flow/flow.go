package flow

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/AGlElectronics/feedback/backend/internal/store"
	"github.com/AGlElectronics/feedback/backend/internal/telegram"
)

const (
	maxBody = 3500

	btnPositive     = "Positive"
	btnNegative     = "Negative"
	btnAnonymous    = "Anonymous"
	btnNamed        = "Named"
	btnUseDefault   = "Use default"
	btnNotifyBoard  = "Notify board"
	btnSkipBoard    = "Don't notify board"
	btnCancel       = "Cancel"
)

type Config struct {
	Departments   []string
	BoardChatID   int64
	BoardThreadID *int64
}

type Engine struct {
	store *store.Store
	tg    *telegram.Client
	cfg   Config
	log   *slog.Logger
}

func New(st *store.Store, tg *telegram.Client, cfg Config, log *slog.Logger) *Engine {
	if len(cfg.Departments) == 0 {
		cfg.Departments = []string{"Board", "Ops", "HR", "Tech", "Front of House"}
	}
	return &Engine{store: st, tg: tg, cfg: cfg, log: log}
}

// Message is the inbound Telegram message Intercom forwards.
type Message struct {
	ChatID         int64  `json:"chat_id"`
	ChatType       string `json:"chat_type"`
	MessageID      int64  `json:"message_id"`
	Text           string `json:"text"`
	TelegramUserID int64  `json:"telegram_user_id"`
	TelegramName   string `json:"telegram_name"`
}

type Result struct {
	Handled        bool                  `json:"handled"`
	Reply          string                `json:"reply,omitempty"`
	Keyboard       *telegram.ReplyKeyboard `json:"-"`
	RemoveKeyboard bool                  `json:"-"`
}

func (e *Engine) Handle(ctx context.Context, msg Message) (Result, error) {
	text := strings.TrimSpace(msg.Text)
	if text == "" {
		return Result{}, nil
	}
	cmd, arg := splitCommand(text)
	_ = arg

	// Group chats: only /feedback points people to a DM.
	if msg.ChatType != "private" {
		if cmd == "/feedback" {
			return Result{Handled: true, Reply: "Send me a private message and say /feedback — Feedback is a one-to-one conversation.", RemoveKeyboard: true}, nil
		}
		return Result{Handled: false}, nil
	}

	if cmd == "/cancel" || text == btnCancel {
		_ = e.store.ClearConversation(ctx, msg.ChatID)
		return Result{Handled: true, Reply: "Cancelled. Send /feedback whenever you want to start again.", RemoveKeyboard: true}, nil
	}

	conv, err := e.store.GetConversation(ctx, msg.ChatID)
	active := err == nil
	if errors.Is(err, store.ErrNoRows) {
		active = false
	} else if err != nil {
		return Result{}, err
	}

	start := cmd == "/feedback" || cmd == "/start" || (!active && cmd == "/help")
	if start || (!active && cmd == "/feedback") {
		return e.begin(ctx, msg)
	}
	if cmd == "/help" && !active {
		return Result{Handled: true, Reply: helpText(), RemoveKeyboard: true}, nil
	}
	if !active {
		if cmd == "/idea" || cmd == "/board" {
			return Result{Handled: false}, nil
		}
		return e.begin(ctx, msg)
	}

	return e.advance(ctx, conv, msg, text, cmd)
}

func (e *Engine) begin(ctx context.Context, msg Message) (Result, error) {
	uid := msg.TelegramUserID
	conv := store.Conversation{
		ChatID:         msg.ChatID,
		Step:           "polarity",
		TelegramUserID: &uid,
		TelegramName:   msg.TelegramName,
	}
	if err := e.store.UpsertConversation(ctx, conv); err != nil {
		return Result{}, err
	}
	return Result{
		Handled:  true,
		Reply:    "Feedback time.\n\nIs this positive or negative?\nTap a button below.",
		Keyboard: telegram.Buttons([]string{btnPositive, btnNegative}, []string{btnCancel}),
	}, nil
}

func (e *Engine) advance(ctx context.Context, conv store.Conversation, msg Message, text, cmd string) (Result, error) {
	if cmd == "/feedback" || cmd == "/start" {
		return e.begin(ctx, msg)
	}
	switch conv.Step {
	case "polarity":
		pol, ok := parsePolarity(text)
		if !ok {
			return Result{
				Handled:  true,
				Reply:    "Tap Positive or Negative.",
				Keyboard: telegram.Buttons([]string{btnPositive, btnNegative}, []string{btnCancel}),
			}, nil
		}
		conv.Polarity = &pol
		conv.Step = "anonymous"
		if err := e.store.UpsertConversation(ctx, conv); err != nil {
			return Result{}, err
		}
		def := btnAnonymous
		if pol == "positive" {
			def = btnNamed
		}
		return Result{
			Handled: true,
			Reply:   fmt.Sprintf("Stay anonymous?\nDefault for %s feedback is %s.\nTap a button.", pol, def),
			Keyboard: telegram.Buttons(
				[]string{btnAnonymous, btnNamed},
				[]string{btnUseDefault},
				[]string{btnCancel},
			),
		}, nil

	case "anonymous":
		anon, ok := parseAnonymous(text, conv.Polarity)
		if !ok {
			return Result{
				Handled: true,
				Reply:   "Tap Anonymous, Named, or Use default.",
				Keyboard: telegram.Buttons(
					[]string{btnAnonymous, btnNamed},
					[]string{btnUseDefault},
					[]string{btnCancel},
				),
			}, nil
		}
		conv.Anonymous = &anon
		conv.Step = "department"
		if err := e.store.UpsertConversation(ctx, conv); err != nil {
			return Result{}, err
		}
		return Result{
			Handled:  true,
			Reply:    "Which department is this for?\nTap a button.",
			Keyboard: e.departmentKeyboard(),
		}, nil

	case "department":
		dept, ok := e.parseDepartment(text)
		if !ok {
			return Result{
				Handled:  true,
				Reply:    "Tap a department button.",
				Keyboard: e.departmentKeyboard(),
			}, nil
		}
		conv.Department = dept
		conv.Step = "body"
		if err := e.store.UpsertConversation(ctx, conv); err != nil {
			return Result{}, err
		}
		return Result{
			Handled:        true,
			Reply:          "Write your feedback in one message.",
			RemoveKeyboard: true,
		}, nil

	case "body":
		if utf8.RuneCountInString(text) > maxBody {
			return Result{Handled: true, Reply: "That is a bit long — keep it under 3500 characters.", RemoveKeyboard: true}, nil
		}
		if text == "" || text == btnCancel {
			return Result{Handled: true, Reply: "Please send the feedback text.", RemoveKeyboard: true}, nil
		}
		conv.Body = text
		conv.Step = "board_notify"
		if err := e.store.UpsertConversation(ctx, conv); err != nil {
			return Result{}, err
		}
		return Result{
			Handled: true,
			Reply:   "Should the board also be notified?\nTap a button (default is notify).",
			Keyboard: telegram.Buttons(
				[]string{btnNotifyBoard, btnSkipBoard},
				[]string{btnUseDefault},
				[]string{btnCancel},
			),
		}, nil

	case "board_notify":
		notify, ok := parseBoardNotify(text)
		if !ok {
			return Result{
				Handled: true,
				Reply:   "Tap Notify board, Don't notify board, or Use default.",
				Keyboard: telegram.Buttons(
					[]string{btnNotifyBoard, btnSkipBoard},
					[]string{btnUseDefault},
					[]string{btnCancel},
				),
			}, nil
		}
		conv.BoardNotify = &notify
		return e.finish(ctx, conv)

	default:
		return e.begin(ctx, msg)
	}
}

func (e *Engine) finish(ctx context.Context, conv store.Conversation) (Result, error) {
	if conv.Polarity == nil || conv.Anonymous == nil || conv.Body == "" || conv.Department == "" {
		return e.begin(ctx, Message{ChatID: conv.ChatID})
	}
	notify := true
	if conv.BoardNotify != nil {
		notify = *conv.BoardNotify
	}

	sub := store.Submission{
		Polarity:       *conv.Polarity,
		Anonymous:      *conv.Anonymous,
		Department:     conv.Department,
		Body:           conv.Body,
		BoardNotify:    notify,
		TelegramUserID: conv.TelegramUserID,
		TelegramName:   conv.TelegramName,
		SourceChatID:   conv.ChatID,
	}
	if sub.Anonymous {
		sub.TelegramUserID = nil
		sub.TelegramName = ""
	}

	saved, err := e.store.SaveSubmission(ctx, sub)
	if err != nil {
		return Result{}, err
	}

	if notify && e.cfg.BoardChatID != 0 && e.tg.Configured() {
		who := "anonymous"
		if !saved.Anonymous {
			who = saved.TelegramName
			if who == "" {
				who = "named staff"
			}
		}
		post := fmt.Sprintf(
			"Feedback #%d · %s · %s\nFrom: %s\nBoard notify: yes\n\n%s",
			saved.ID, strings.ToUpper(saved.Polarity[:1])+saved.Polarity[1:], saved.Department, who, saved.Body,
		)
		sent, err := e.tg.SendMessage(ctx, e.cfg.BoardChatID, post, telegram.SendOpts{ThreadID: e.cfg.BoardThreadID})
		if err != nil {
			e.log.Warn("feedback board notify failed", "error", err)
		} else if err := e.store.SetBoardMessageID(ctx, saved.ID, sent.MessageID); err != nil {
			e.log.Warn("feedback board message id save failed", "error", err)
		}
	}

	_ = e.store.ClearConversation(ctx, conv.ChatID)

	reply := fmt.Sprintf("Thank you — feedback #%d is in.\nDepartment: %s · %s", saved.ID, saved.Department, saved.Polarity)
	if saved.Anonymous {
		reply += " · anonymous"
	}
	if notify {
		reply += "\nThe board was notified."
	} else {
		reply += "\nThe board was not notified."
	}
	reply += "\n\nSend /feedback to share another."
	return Result{Handled: true, Reply: reply, RemoveKeyboard: true}, nil
}

func (e *Engine) departmentKeyboard() *telegram.ReplyKeyboard {
	var rows [][]string
	row := make([]string, 0, 2)
	for _, d := range e.cfg.Departments {
		row = append(row, d)
		if len(row) == 2 {
			rows = append(rows, row)
			row = make([]string, 0, 2)
		}
	}
	if len(row) > 0 {
		rows = append(rows, row)
	}
	rows = append(rows, []string{btnCancel})
	return telegram.Buttons(rows...)
}

func (e *Engine) parseDepartment(text string) (string, bool) {
	text = strings.TrimSpace(text)
	for _, d := range e.cfg.Departments {
		if d == text {
			return d, true
		}
	}
	if n, err := strconv.Atoi(text); err == nil {
		if n >= 1 && n <= len(e.cfg.Departments) {
			return e.cfg.Departments[n-1], true
		}
		return "", false
	}
	lower := strings.ToLower(text)
	for _, d := range e.cfg.Departments {
		if strings.ToLower(d) == lower {
			return d, true
		}
	}
	var hit string
	for _, d := range e.cfg.Departments {
		if strings.HasPrefix(strings.ToLower(d), lower) {
			if hit != "" {
				return "", false
			}
			hit = d
		}
	}
	return hit, hit != ""
}

func parsePolarity(text string) (string, bool) {
	switch strings.ToLower(strings.TrimSpace(text)) {
	case "1", "positive", "pos", "+", "good", "p", strings.ToLower(btnPositive):
		return "positive", true
	case "2", "negative", "neg", "-", "bad", "n", strings.ToLower(btnNegative):
		return "negative", true
	default:
		return "", false
	}
}

func parseAnonymous(text string, polarity *string) (bool, bool) {
	switch strings.ToLower(strings.TrimSpace(text)) {
	case "anonymous", "yes", "y", "yeah", "yep", "1":
		return true, true
	case "named", "no", "n", "nope", "0":
		return false, true
	case "use default", "default", "skip":
		return polarity != nil && *polarity == "negative", true
	default:
		return false, false
	}
}

func parseBoardNotify(text string) (bool, bool) {
	switch strings.ToLower(strings.TrimSpace(text)) {
	case "notify board", "yes", "y", "yeah", "1":
		return true, true
	case "don't notify board", "dont notify board", "no", "n", "0":
		return false, true
	case "use default", "default", "skip":
		return true, true
	default:
		return false, false
	}
}

func splitCommand(text string) (cmd, arg string) {
	parts := strings.SplitN(text, " ", 2)
	cmd = strings.ToLower(parts[0])
	cmd = strings.SplitN(cmd, "@", 2)[0]
	if len(parts) > 1 {
		arg = parts[1]
	}
	return cmd, arg
}

func helpText() string {
	return "Feedback collects anonymous or named notes for departments and the board.\n\nSend /feedback to start — choices use buttons.\n/cancel (or Cancel) aborts an in-progress conversation."
}

// ApplyAnonymousDefault sets anonymity when the user sends "default".
func ApplyAnonymousDefault(polarity string) bool {
	return polarity == "negative"
}
