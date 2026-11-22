# Intercom configuration

| Name | Default | Required | Secret | What it does |
| --- | --- | --- | --- | --- |
| `HTTP_ADDR` | `:8080` | no | no | Listen address. |
| `DATABASE_URL` | none | **yes** | **yes** | Postgres URL for the `intercom` database. |
| `INTERCOM_TELEGRAM_BOT_TOKEN` | none | no* | **yes** | Staff bot token. Prefer this over sharing with other modules. |
| `TELEGRAM_BOT_TOKEN` | none | no* | **yes** | Fallback bot token when `INTERCOM_TELEGRAM_BOT_TOKEN` is empty. |
| `INTERCOM_BOARD_CHAT_ID` | none | no† | no | Telegram chat id for board questions and ideas. |
| `INTERCOM_BOARD_THREAD_ID` | none | no | no | Forum topic id inside the board chat. |
| `INTERCOM_IDEAS_THREAD_ID` | board thread | no | no | Optional separate topic for `/idea` posts. |
| `TELEGRAM_DEV_CATCHALL_CHAT_ID` | none | no† | no | Local Compose fallback for the board chat. |
| `TELEGRAM_DEV_CATCHALL_THREAD_ID` | none | no | no | Local Compose fallback for the board topic. |
| `TASKS_INTERNAL_URL` | `http://tasks-backend:8080` | no | no | Tasks base URL for `/idea` → task create. |
| `TASKS_SERVICE_TOKEN` | none | no* | **yes** | Bearer for Tasks `POST /api/internal/ideas`. |

\* Required for `/idea` to create Tasks cards. Without it, Intercom still
stores the idea locally and posts to Telegram.

\* One of `INTERCOM_TELEGRAM_BOT_TOKEN` or `TELEGRAM_BOT_TOKEN` is required for
the poller to do anything useful.

† One of `INTERCOM_BOARD_CHAT_ID` or `TELEGRAM_DEV_CATCHALL_CHAT_ID` is
required before `/board` and `/idea` accept traffic.

Bot tokens are secrets — see [Secrets](../../operations/secrets.md). Never
commit real tokens; use placeholders such as `change-me` in examples.
