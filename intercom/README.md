# Intercom

> [!WARNING]
> Intercom is a 1.1 development scaffold. Fine-tuning (department topics,
> Feedback, Tasks/Wiki idea hooks, Den unread strip) comes later.

Intercom is the staff communications bridge. This cut ships the Telegram
commands from the 1.1 plan notes:

- `/board <question>` in a department group → posts to the board chat/topic
- Board members reply to that message → Intercom posts the answer back
- `/idea <text>` → stores the idea and posts it for the board

Documentation: [Intercom on the Con Services site](https://aglelectronics.github.io/con-services/modules/intercom/).
Changes: [CHANGELOG.md](CHANGELOG.md).

## Run locally

From the root `con-services` workspace (bot token and board chat already in
`.env` as the Telegram catch-all):

```sh
docker compose --profile intercom up --build intercom-frontend
```

Open <http://localhost:3012>. API: <http://localhost:8171/readyz>.

**Important:** only one service may long-poll a given bot token. Keep Stash
Lost & Found Telegram **off** while Intercom uses `TELEGRAM_BOT_TOKEN` (or give
Stash `STASH_TELEGRAM_BOT_TOKEN` with a second bot).

```sh
cd intercom/backend
go test ./...
```
