package bot

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/AGlElectronics/intercom/backend/internal/feedbackclient"
	"github.com/AGlElectronics/intercom/backend/internal/store"
	"github.com/AGlElectronics/intercom/backend/internal/tasksclient"
	"github.com/AGlElectronics/intercom/backend/internal/telegram"
)

const maxText = 3500

type Config struct {
	BoardChatID   int64
	BoardThreadID *int64
	IdeasThreadID *int64 // nil = same as board thread
}

type Bot struct {
	tg       *telegram.Client
	store    *store.Store
	tasks    *tasksclient.Client
	feedback *feedbackclient.Client
	cfg      Config
	log      *slog.Logger
	botUser  string
}

func New(tg *telegram.Client, st *store.Store, tasks *tasksclient.Client, feedback *feedbackclient.Client, cfg Config, log *slog.Logger) *Bot {
	return &Bot{tg: tg, store: st, tasks: tasks, feedback: feedback, cfg: cfg, log: log}
}

func (b *Bot) Run(ctx context.Context) {
	if b.tg == nil || !b.tg.Configured() {
		b.log.Warn("intercom telegram: no bot token; poller idle")
		<-ctx.Done()
		return
	}
	if b.cfg.BoardChatID == 0 {
		b.log.Warn("intercom telegram: INTERCOM_BOARD_CHAT_ID unset; /board and /idea will refuse until set")
	}
	_ = b.tg.DeleteWebhook(ctx)
	if name, err := b.tg.BotUsername(ctx); err == nil {
		b.botUser = name
		b.log.Info("intercom telegram poller on", "bot", name, "board_chat", b.cfg.BoardChatID)
	}
	_ = b.tg.SetMyCommands(ctx, []map[string]string{
		{"command": "board", "description": "Ask the board (group chats)"},
		{"command": "idea", "description": "Capture an idea for the board"},
		{"command": "feedback", "description": "Give department or board feedback (DM)"},
		{"command": "help", "description": "How Intercom commands work"},
	})

	for ctx.Err() == nil {
		if err := b.pollOnce(ctx); err != nil && ctx.Err() == nil {
			b.log.Warn("intercom telegram poll failed", "error", err)
			sleep(ctx, 10*time.Second)
		}
	}
}

func (b *Bot) pollOnce(ctx context.Context) error {
	offset, err := b.store.Offset(ctx)
	if err != nil {
		return err
	}
	updates, err := b.tg.GetUpdates(ctx, offset)
	if err != nil {
		return err
	}
	for _, u := range updates {
		if err := b.handle(ctx, u); err != nil {
			b.log.Warn("intercom telegram handle failed", "update_id", u.UpdateID, "error", err)
		}
		if u.UpdateID >= offset {
			offset = u.UpdateID + 1
		}
	}
	if len(updates) == 0 {
		return nil
	}
	return b.store.SetOffset(ctx, offset)
}

func (b *Bot) handle(ctx context.Context, u telegram.Update) error {
	if u.Message == nil {
		return nil
	}
	msg := u.Message
	if msg.From != nil && msg.From.IsBot {
		return nil
	}

	// Reply-back: board answers a relayed /board message.
	if msg.ReplyToMessage != nil && msg.Chat.ID == b.cfg.BoardChatID {
		if err := b.handleBoardReply(ctx, msg); err != nil {
			return err
		}
		// Still allow /commands in the board chat below.
	}

	text := strings.TrimSpace(msg.Text)
	if text == "" {
		return nil
	}
	cmd, arg := splitCommand(text)

	// Feedback owns private conversations (and /feedback anywhere).
	if b.feedback.Enabled() && (cmd == "/feedback" || (msg.Chat.Type == "private" && cmd != "/idea" && cmd != "/board" && cmd != "/help")) {
		if cmd == "/start" && msg.Chat.Type == "private" {
			// /start in DM opens Feedback; Intercom help stays on /help.
		}
		handled, err := b.routeFeedback(ctx, msg)
		if err != nil {
			return err
		}
		if handled {
			return nil
		}
	}

	switch cmd {
	case "/help":
		return b.reply(ctx, msg, helpText())
	case "/start":
		if msg.Chat.Type == "private" && b.feedback.Enabled() {
			_, err := b.routeFeedback(ctx, msg)
			return err
		}
		return b.reply(ctx, msg, helpText())
	case "/board":
		return b.handleBoard(ctx, msg, arg)
	case "/idea":
		return b.handleIdea(ctx, msg, arg)
	default:
		return nil
	}
}

func (b *Bot) routeFeedback(ctx context.Context, msg *telegram.Message) (bool, error) {
	var uid int64
	name := ""
	if msg.From != nil {
		uid = msg.From.ID
		name = msg.From.Display()
	}
	res, err := b.feedback.HandleMessage(ctx, feedbackclient.Message{
		ChatID:         msg.Chat.ID,
		ChatType:       msg.Chat.Type,
		MessageID:      msg.MessageID,
		Text:           msg.Text,
		TelegramUserID: uid,
		TelegramName:   name,
	})
	if err != nil {
		b.log.Warn("intercom feedback bridge failed", "error", err)
		return false, nil
	}
	return res.Handled, nil
}

func (b *Bot) handleBoard(ctx context.Context, msg *telegram.Message, question string) error {
	question = strings.TrimSpace(question)
	if question == "" {
		return b.reply(ctx, msg, "Ask the board like this:\n/board Do we have budget for more radios?")
	}
	if b.cfg.BoardChatID == 0 {
		return b.reply(ctx, msg, "Intercom is not configured with a board chat yet.")
	}
	if msg.Chat.Type == "private" {
		return b.reply(ctx, msg, "/board is for department group chats. Open the staff group and try again there.")
	}
	if utf8.RuneCountInString(question) > maxText {
		return b.reply(ctx, msg, "That question is too long; keep it under 3500 characters.")
	}

	title := msg.Chat.Title
	if title == "" {
		title = fmt.Sprintf("chat %d", msg.Chat.ID)
	}
	body := fmt.Sprintf(
		"Board question from %s\nFrom: %s\n\n%s",
		title, msg.From.Display(), question,
	)
	sent, err := b.tg.SendMessage(ctx, b.cfg.BoardChatID, body, telegram.SendOpts{ThreadID: b.cfg.BoardThreadID})
	if err != nil {
		return err
	}
	var userID *int64
	if msg.From != nil {
		id := msg.From.ID
		userID = &id
	}
	var thread *int64
	if msg.MessageThreadID > 0 {
		t := msg.MessageThreadID
		thread = &t
	}
	_, err = b.store.SaveBoardRelay(ctx, store.BoardRelay{
		SourceChatID:    msg.Chat.ID,
		SourceChatTitle: title,
		SourceThreadID:  thread,
		SourceMessageID: msg.MessageID,
		SourceUserID:    userID,
		SourceUserName:  msg.From.Display(),
		Question:        question,
		BoardChatID:     b.cfg.BoardChatID,
		BoardThreadID:   b.cfg.BoardThreadID,
		BoardMessageID:  sent.MessageID,
	})
	if err != nil {
		return err
	}
	return b.reply(ctx, msg, "Sent to the board. They can reply to that message and Intercom will bring the answer back here.")
}

func (b *Bot) handleBoardReply(ctx context.Context, msg *telegram.Message) error {
	if msg.ReplyToMessage == nil {
		return nil
	}
	relay, err := b.store.FindBoardRelay(ctx, msg.Chat.ID, msg.ReplyToMessage.MessageID)
	if errors.Is(err, store.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	answer := strings.TrimSpace(msg.Text)
	if answer == "" {
		return nil
	}
	if utf8.RuneCountInString(answer) > maxText {
		answer = string([]rune(answer)[:maxText]) + "…"
	}
	body := fmt.Sprintf("Board reply from %s:\n\n%s", msg.From.Display(), answer)
	opts := telegram.SendOpts{ThreadID: relay.SourceThreadID, ReplyToMessage: &relay.SourceMessageID}
	_, err = b.tg.SendMessage(ctx, relay.SourceChatID, body, opts)
	return err
}

func (b *Bot) handleIdea(ctx context.Context, msg *telegram.Message, body string) error {
	body = strings.TrimSpace(body)
	if body == "" {
		return b.reply(ctx, msg, "Capture an idea like this:\n/idea Put water stations near the outdoor stage")
	}
	if b.cfg.BoardChatID == 0 {
		return b.reply(ctx, msg, "Intercom is not configured with a board chat yet.")
	}
	if utf8.RuneCountInString(body) > maxText {
		return b.reply(ctx, msg, "That idea is too long; keep it under 3500 characters.")
	}

	title := msg.Chat.Title
	if title == "" {
		if msg.Chat.Type == "private" {
			title = "private chat"
		} else {
			title = fmt.Sprintf("chat %d", msg.Chat.ID)
		}
	}
	ideasThread := b.cfg.IdeasThreadID
	if ideasThread == nil {
		ideasThread = b.cfg.BoardThreadID
	}
	var taskKey, taskID string
	if b.tasks.Enabled() {
		created, err := b.tasks.CreateIdea(ctx, tasksclient.IdeaInput{
			Body:            body,
			SourceUserName:  msg.From.Display(),
			SourceChatTitle: title,
		})
		if err != nil {
			b.log.Warn("intercom tasks idea failed", "error", err)
			return b.reply(ctx, msg, "Could not create the Tasks card in the Intercom space. Try again in a moment.")
		}
		taskKey = created.TaskKey
		taskID = created.Task.ID
	}

	post := fmt.Sprintf("Idea from %s\nFrom: %s\n\n%s", title, msg.From.Display(), body)
	if taskKey != "" {
		post += "\n\nTasks: " + taskKey + " (Intercom → Ideas)"
	}
	sent, err := b.tg.SendMessage(ctx, b.cfg.BoardChatID, post, telegram.SendOpts{ThreadID: ideasThread})
	if err != nil {
		return err
	}
	var userID *int64
	if msg.From != nil {
		id := msg.From.ID
		userID = &id
	}
	var thread *int64
	if msg.MessageThreadID > 0 {
		t := msg.MessageThreadID
		thread = &t
	}
	msgID := msg.MessageID
	boardMsg := sent.MessageID
	boardChat := b.cfg.BoardChatID
	var taskIDPtr *string
	if taskID != "" {
		taskIDPtr = &taskID
	}
	idea, err := b.store.SaveIdea(ctx, store.Idea{
		SourceChatID:    msg.Chat.ID,
		SourceChatTitle: title,
		SourceThreadID:  thread,
		SourceMessageID: &msgID,
		SourceUserID:    userID,
		SourceUserName:  msg.From.Display(),
		Body:            body,
		BoardChatID:     &boardChat,
		BoardThreadID:   ideasThread,
		BoardMessageID:  &boardMsg,
		TaskID:          taskIDPtr,
		TaskKey:         taskKey,
	})
	if err != nil {
		return err
	}
	if taskKey != "" {
		return b.reply(ctx, msg, fmt.Sprintf("Idea saved as %s in Tasks → Intercom → Ideas.", taskKey))
	}
	return b.reply(ctx, msg, fmt.Sprintf("Idea saved (#%d) and posted for the board (Tasks bridge not configured).", idea.ID))
}

func (b *Bot) reply(ctx context.Context, msg *telegram.Message, text string) error {
	var thread *int64
	if msg.MessageThreadID > 0 {
		t := msg.MessageThreadID
		thread = &t
	}
	replyTo := msg.MessageID
	_, err := b.tg.SendMessage(ctx, msg.Chat.ID, text, telegram.SendOpts{
		ThreadID:       thread,
		ReplyToMessage: &replyTo,
	})
	return err
}

func helpText() string {
	return strings.TrimSpace(`
Intercom staff bot

/board <question> — in a department group, relay a question to the board chat. Board members reply to that message; Intercom posts the answer back in your group.

/idea <text> — capture an idea as a task in Tasks → Intercom → Ideas (and post it for the board).

/feedback — private chat: give positive or negative feedback to a department or the board.

/help — this text.
`)
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

func sleep(ctx context.Context, d time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(d):
	}
}
