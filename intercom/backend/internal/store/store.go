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
	if err := s.migrate(ctx); err != nil {
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

func (s *Store) migrate(ctx context.Context) error {
	sqlBytes, err := migrationFS.ReadFile("migrations/00001_init.sql")
	if err != nil {
		return fmt.Errorf("read migration: %w", err)
	}
	_, err = s.pool.Exec(ctx, string(sqlBytes))
	return err
}

func (s *Store) Offset(ctx context.Context) (int64, error) {
	var offset int64
	err := s.pool.QueryRow(ctx, `SELECT update_offset FROM telegram_state WHERE id = 1`).Scan(&offset)
	if err != nil {
		return 0, err
	}
	return offset, nil
}

func (s *Store) SetOffset(ctx context.Context, offset int64) error {
	_, err := s.pool.Exec(ctx, `
		UPDATE telegram_state SET update_offset = $1, updated_at = now() WHERE id = 1`, offset)
	return err
}

type BoardRelay struct {
	ID               int64     `json:"id"`
	SourceChatID     int64     `json:"source_chat_id"`
	SourceChatTitle  string    `json:"source_chat_title"`
	SourceThreadID   *int64    `json:"source_thread_id,omitempty"`
	SourceMessageID  int64     `json:"source_message_id"`
	SourceUserID     *int64    `json:"source_user_id,omitempty"`
	SourceUserName   string    `json:"source_user_name"`
	Question         string    `json:"question"`
	BoardChatID      int64     `json:"board_chat_id"`
	BoardThreadID    *int64    `json:"board_thread_id,omitempty"`
	BoardMessageID   int64     `json:"board_message_id"`
	CreatedAt        time.Time `json:"created_at"`
}

func (s *Store) SaveBoardRelay(ctx context.Context, r BoardRelay) (BoardRelay, error) {
	err := s.pool.QueryRow(ctx, `
		INSERT INTO board_relays (
			source_chat_id, source_chat_title, source_thread_id, source_message_id,
			source_user_id, source_user_name, question,
			board_chat_id, board_thread_id, board_message_id
		) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
		RETURNING id, created_at`,
		r.SourceChatID, r.SourceChatTitle, r.SourceThreadID, r.SourceMessageID,
		r.SourceUserID, r.SourceUserName, r.Question,
		r.BoardChatID, r.BoardThreadID, r.BoardMessageID,
	).Scan(&r.ID, &r.CreatedAt)
	return r, err
}

func (s *Store) FindBoardRelay(ctx context.Context, boardChatID, boardMessageID int64) (BoardRelay, error) {
	var r BoardRelay
	err := s.pool.QueryRow(ctx, `
		SELECT id, source_chat_id, source_chat_title, source_thread_id, source_message_id,
		       source_user_id, source_user_name, question,
		       board_chat_id, board_thread_id, board_message_id, created_at
		FROM board_relays
		WHERE board_chat_id = $1 AND board_message_id = $2`,
		boardChatID, boardMessageID,
	).Scan(
		&r.ID, &r.SourceChatID, &r.SourceChatTitle, &r.SourceThreadID, &r.SourceMessageID,
		&r.SourceUserID, &r.SourceUserName, &r.Question,
		&r.BoardChatID, &r.BoardThreadID, &r.BoardMessageID, &r.CreatedAt,
	)
	if err != nil {
		return BoardRelay{}, err
	}
	return r, nil
}

func (s *Store) ListBoardRelays(ctx context.Context, limit int) ([]BoardRelay, error) {
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	rows, err := s.pool.Query(ctx, `
		SELECT id, source_chat_id, source_chat_title, source_thread_id, source_message_id,
		       source_user_id, source_user_name, question,
		       board_chat_id, board_thread_id, board_message_id, created_at
		FROM board_relays
		ORDER BY created_at DESC
		LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []BoardRelay
	for rows.Next() {
		var r BoardRelay
		if err := rows.Scan(
			&r.ID, &r.SourceChatID, &r.SourceChatTitle, &r.SourceThreadID, &r.SourceMessageID,
			&r.SourceUserID, &r.SourceUserName, &r.Question,
			&r.BoardChatID, &r.BoardThreadID, &r.BoardMessageID, &r.CreatedAt,
		); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

type Idea struct {
	ID              int64     `json:"id"`
	SourceChatID    int64     `json:"source_chat_id"`
	SourceChatTitle string    `json:"source_chat_title"`
	SourceThreadID  *int64    `json:"source_thread_id,omitempty"`
	SourceMessageID *int64    `json:"source_message_id,omitempty"`
	SourceUserID    *int64    `json:"source_user_id,omitempty"`
	SourceUserName  string    `json:"source_user_name"`
	Body            string    `json:"body"`
	BoardChatID     *int64    `json:"board_chat_id,omitempty"`
	BoardThreadID   *int64    `json:"board_thread_id,omitempty"`
	BoardMessageID  *int64    `json:"board_message_id,omitempty"`
	TaskID          *string   `json:"task_id,omitempty"`
	TaskKey         string    `json:"task_key,omitempty"`
	CreatedAt       time.Time `json:"created_at"`
}

func (s *Store) SaveIdea(ctx context.Context, idea Idea) (Idea, error) {
	err := s.pool.QueryRow(ctx, `
		INSERT INTO ideas (
			source_chat_id, source_chat_title, source_thread_id, source_message_id,
			source_user_id, source_user_name, body,
			board_chat_id, board_thread_id, board_message_id, task_id, task_key
		) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)
		RETURNING id, created_at`,
		idea.SourceChatID, idea.SourceChatTitle, idea.SourceThreadID, idea.SourceMessageID,
		idea.SourceUserID, idea.SourceUserName, idea.Body,
		idea.BoardChatID, idea.BoardThreadID, idea.BoardMessageID, idea.TaskID, idea.TaskKey,
	).Scan(&idea.ID, &idea.CreatedAt)
	return idea, err
}

func (s *Store) ListIdeas(ctx context.Context, limit int) ([]Idea, error) {
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	rows, err := s.pool.Query(ctx, `
		SELECT id, source_chat_id, source_chat_title, source_thread_id, source_message_id,
		       source_user_id, source_user_name, body,
		       board_chat_id, board_thread_id, board_message_id, task_id::text, task_key, created_at
		FROM ideas
		ORDER BY created_at DESC
		LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Idea
	for rows.Next() {
		var idea Idea
		var taskID *string
		if err := rows.Scan(
			&idea.ID, &idea.SourceChatID, &idea.SourceChatTitle, &idea.SourceThreadID, &idea.SourceMessageID,
			&idea.SourceUserID, &idea.SourceUserName, &idea.Body,
			&idea.BoardChatID, &idea.BoardThreadID, &idea.BoardMessageID, &taskID, &idea.TaskKey, &idea.CreatedAt,
		); err != nil {
			return nil, err
		}
		idea.TaskID = taskID
		out = append(out, idea)
	}
	return out, rows.Err()
}

// ErrNoRows re-exports pgx.ErrNoRows for handlers.
var ErrNoRows = pgx.ErrNoRows
