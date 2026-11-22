-- Feedback MVP: Telegram conversation state + submitted feedback.

CREATE TABLE IF NOT EXISTS conversations (
    chat_id           bigint PRIMARY KEY,
    step              text NOT NULL DEFAULT 'polarity',
    polarity          text,
    anonymous         boolean,
    department        text NOT NULL DEFAULT '',
    body              text NOT NULL DEFAULT '',
    board_notify      boolean,
    telegram_user_id  bigint,
    telegram_name     text NOT NULL DEFAULT '',
    updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS submissions (
    id                bigserial PRIMARY KEY,
    polarity          text NOT NULL CHECK (polarity IN ('positive', 'negative')),
    anonymous         boolean NOT NULL,
    department        text NOT NULL,
    body              text NOT NULL,
    board_notify      boolean NOT NULL DEFAULT true,
    telegram_user_id  bigint,
    telegram_name     text NOT NULL DEFAULT '',
    source_chat_id    bigint NOT NULL,
    board_message_id  bigint,
    created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS submissions_created_idx ON submissions (created_at DESC);
CREATE INDEX IF NOT EXISTS submissions_dept_idx ON submissions (department);
CREATE INDEX IF NOT EXISTS submissions_polarity_idx ON submissions (polarity);
