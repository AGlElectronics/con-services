# Intercom API

The 1.1 scaffold exposes unauthenticated read endpoints for local
development. Production auth (OIDC / denlink) is not implemented yet.

Who may call today: anyone who can reach the Intercom backend on the local
network. Treat the UI and API as a **dev-only** surface.

## Health

### `GET /livez`

```bash
curl -s http://localhost:8171/livez
```

```json
{"status":"ok"}
```

### `GET /readyz`

```bash
curl -s http://localhost:8171/readyz
```

```json
{
  "status": "ok",
  "version": "dev",
  "telegram": true,
  "board_chat_id": -1003787521365,
  "board_thread_set": true
}
```

## Status

### `GET /api/v1/status`

Module status for the local UI.

```bash
curl -s http://localhost:8171/api/v1/status
```

```json
{
  "version": "dev",
  "module": "intercom",
  "telegram": true,
  "board_chat_id": -1003787521365,
  "board_thread_set": true,
  "ideas_thread_set": false
}
```

## Board relays

### `GET /api/v1/board-relays`

Recent `/board` questions Intercom forwarded to the board chat.

```bash
curl -s http://localhost:8171/api/v1/board-relays
```

```json
{
  "relays": [
    {
      "id": 1,
      "source_chat_id": -1003787521365,
      "source_chat_title": "[Confuratio] Board Chat",
      "source_user_name": "Taire (@Tairecat)",
      "question": "Do we have budget for more radios?",
      "board_chat_id": -1003787521365,
      "board_message_id": 640,
      "created_at": "2026-11-17T20:40:00Z"
    }
  ]
}
```

## Ideas

### `GET /api/v1/ideas`

Recent `/idea` captures.

```bash
curl -s http://localhost:8171/api/v1/ideas
```

```json
{
  "ideas": [
    {
      "id": 1,
      "source_chat_title": "Ops",
      "source_user_name": "Taire (@Tairecat)",
      "body": "Put water stations near the outdoor stage",
      "created_at": "2026-11-17T20:41:00Z"
    }
  ]
}
```

## Telegram commands (not HTTP)

| Command | Where | Effect |
| --- | --- | --- |
| `/board <question>` | Group / forum topic | Relay to board chat; store reply mapping |
| `/idea <text>` | Group or private DM | Store + post for the board |
| `/help` | Anywhere the bot sees the message | Short usage text |

Errors the bot answers in chat: missing question/idea text, board chat
not configured, `/board` used in a private DM, text over 3500 characters.
