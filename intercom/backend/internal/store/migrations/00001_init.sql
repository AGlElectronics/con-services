-- Intercom staff-comms MVP: Telegram /board relay, /idea capture, poll offset.

CREATE TABLE IF NOT EXISTS telegram_state (
    id              smallint PRIMARY KEY CHECK (id = 1),
    update_offset   bigint NOT NULL DEFAULT 0,
    updated_at      timestamptz NOT NULL DEFAULT now()
);

INSERT INTO telegram_state (id, update_offset)
VALUES (1, 0)
ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS board_relays (
    id                  bigserial PRIMARY KEY,
    source_chat_id      bigint NOT NULL,
    source_chat_title   text NOT NULL DEFAULT '',
    source_thread_id    bigint,
    source_message_id   bigint NOT NULL,
    source_user_id      bigint,
    source_user_name    text NOT NULL DEFAULT '',
    question            text NOT NULL,
    board_chat_id       bigint NOT NULL,
    board_thread_id     bigint,
    board_message_id    bigint NOT NULL,
    created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS board_relays_board_msg_idx
    ON board_relays (board_chat_id, board_message_id);

CREATE TABLE IF NOT EXISTS ideas (
    id                  bigserial PRIMARY KEY,
    source_chat_id      bigint NOT NULL,
    source_chat_title   text NOT NULL DEFAULT '',
    source_thread_id    bigint,
    source_message_id   bigint,
    source_user_id      bigint,
    source_user_name    text NOT NULL DEFAULT '',
    body                text NOT NULL,
    board_chat_id       bigint,
    board_thread_id     bigint,
    board_message_id    bigint,
    task_id             uuid,
    task_key            text NOT NULL DEFAULT '',
    created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ideas_created_idx ON ideas (created_at DESC);

ALTER TABLE ideas ADD COLUMN IF NOT EXISTS task_id uuid;
ALTER TABLE ideas ADD COLUMN IF NOT EXISTS task_key text NOT NULL DEFAULT '';
