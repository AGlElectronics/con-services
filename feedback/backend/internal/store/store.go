package store

import (
	"context"
	"embed"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed migrations/*.sql
var migrationFS embed.FS

type Store struct {
	pool *pgxpool.Pool
}

func Connect(ctx context.Context, databaseURL string) (*Store, error) {
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		return nil, err
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, err
	}
	s := &Store{pool: pool}
	sqlBytes, err := migrationFS.ReadFile("migrations/00001_init.sql")
	if err != nil {
		pool.Close()
		return nil, fmt.Errorf("read migration: %w", err)
	}
	if _, err := pool.Exec(ctx, string(sqlBytes)); err != nil {
		pool.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() {
	if s != nil && s.pool != nil {
		s.pool.Close()
	}
}

type Conversation struct {
	ChatID         int64
	Step           string
	Polarity       *string
	Anonymous      *bool
	Department     string
	Body           string
	BoardNotify    *bool
	TelegramUserID *int64
	TelegramName   string
	UpdatedAt      time.Time
}

func (s *Store) GetConversation(ctx context.Context, chatID int64) (Conversation, error) {
	var c Conversation
	err := s.pool.QueryRow(ctx, `
		SELECT chat_id, step, polarity, anonymous, department, body, board_notify,
		       telegram_user_id, telegram_name, updated_at
		FROM conversations WHERE chat_id = $1`, chatID).Scan(
		&c.ChatID, &c.Step, &c.Polarity, &c.Anonymous, &c.Department, &c.Body, &c.BoardNotify,
		&c.TelegramUserID, &c.TelegramName, &c.UpdatedAt,
	)
	return c, err
}

func (s *Store) UpsertConversation(ctx context.Context, c Conversation) error {
	_, err := s.pool.Exec(ctx, `
		INSERT INTO conversations (
			chat_id, step, polarity, anonymous, department, body, board_notify,
			telegram_user_id, telegram_name, updated_at
		) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9, now())
		ON CONFLICT (chat_id) DO UPDATE SET
			step = EXCLUDED.step,
			polarity = EXCLUDED.polarity,
			anonymous = EXCLUDED.anonymous,
			department = EXCLUDED.department,
			body = EXCLUDED.body,
			board_notify = EXCLUDED.board_notify,
			telegram_user_id = EXCLUDED.telegram_user_id,
			telegram_name = EXCLUDED.telegram_name,
			updated_at = now()`,
		c.ChatID, c.Step, c.Polarity, c.Anonymous, c.Department, c.Body, c.BoardNotify,
		c.TelegramUserID, c.TelegramName,
	)
	return err
}

func (s *Store) ClearConversation(ctx context.Context, chatID int64) error {
	_, err := s.pool.Exec(ctx, `DELETE FROM conversations WHERE chat_id = $1`, chatID)
	return err
}

type Submission struct {
	ID             int64     `json:"id"`
	Polarity       string    `json:"polarity"`
	Anonymous      bool      `json:"anonymous"`
	Department     string    `json:"department"`
	Body           string    `json:"body"`
	BoardNotify    bool      `json:"board_notify"`
	TelegramUserID *int64    `json:"telegram_user_id,omitempty"`
	TelegramName   string    `json:"telegram_name,omitempty"`
	SourceChatID   int64     `json:"source_chat_id"`
	BoardMessageID *int64    `json:"board_message_id,omitempty"`
	CreatedAt      time.Time `json:"created_at"`
}

func (s *Store) SaveSubmission(ctx context.Context, sub Submission) (Submission, error) {
	err := s.pool.QueryRow(ctx, `
		INSERT INTO submissions (
			polarity, anonymous, department, body, board_notify,
			telegram_user_id, telegram_name, source_chat_id, board_message_id
		) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
		RETURNING id, created_at`,
		sub.Polarity, sub.Anonymous, sub.Department, sub.Body, sub.BoardNotify,
		sub.TelegramUserID, sub.TelegramName, sub.SourceChatID, sub.BoardMessageID,
	).Scan(&sub.ID, &sub.CreatedAt)
	return sub, err
}

func (s *Store) ListSubmissions(ctx context.Context, polarity, department string, limit int) ([]Submission, error) {
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	rows, err := s.pool.Query(ctx, `
		SELECT id, polarity, anonymous, department, body, board_notify,
		       telegram_user_id, telegram_name, source_chat_id, board_message_id, created_at
		FROM submissions
		WHERE ($1 = '' OR polarity = $1)
		  AND ($2 = '' OR department ILIKE $2)
		ORDER BY created_at DESC
		LIMIT $3`, polarity, department, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Submission
	for rows.Next() {
		var sub Submission
		if err := rows.Scan(
			&sub.ID, &sub.Polarity, &sub.Anonymous, &sub.Department, &sub.Body, &sub.BoardNotify,
			&sub.TelegramUserID, &sub.TelegramName, &sub.SourceChatID, &sub.BoardMessageID, &sub.CreatedAt,
		); err != nil {
			return nil, err
		}
		out = append(out, sub)
	}
	return out, rows.Err()
}

func (s *Store) SetBoardMessageID(ctx context.Context, id, messageID int64) error {
	_, err := s.pool.Exec(ctx, `UPDATE submissions SET board_message_id = $2 WHERE id = $1`, id, messageID)
	return err
}

func (s *Store) Counts(ctx context.Context) (total, positive, negative int, err error) {
	err = s.pool.QueryRow(ctx, `
		SELECT count(*),
		       count(*) FILTER (WHERE polarity = 'positive'),
		       count(*) FILTER (WHERE polarity = 'negative')
		FROM submissions`).Scan(&total, &positive, &negative)
	return
}

var ErrNoRows = pgx.ErrNoRows
