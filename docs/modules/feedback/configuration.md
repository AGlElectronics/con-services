# Feedback configuration

| Name | Default | Required | Secret | What it does |
| --- | --- | --- | --- | --- |
| `HTTP_ADDR` | `:8080` | no | no | Listen address. |
| `DATABASE_URL` | none | **yes** | **yes** | Postgres URL. |
| `FEEDBACK_SERVICE_TOKEN` | `feedback-dev-token` | no | **yes** | Bearer for Intercom → Feedback. |
| `FEEDBACK_TELEGRAM_BOT_TOKEN` / `TELEGRAM_BOT_TOKEN` | none | no | **yes** | Used to reply and notify the board (send only; Intercom polls). |
| `FEEDBACK_DEPARTMENTS` | Board,Ops,HR,Tech,Front of House | no | no | Comma-separated department names. |
| `FEEDBACK_BOARD_CHAT_ID` | catch-all / Intercom board | no | no | Chat for board notify. |
| `FEEDBACK_BOARD_THREAD_ID` | catch-all / Intercom thread | no | no | Forum topic for board notify. |

Bot tokens are secrets — see [Secrets](../../operations/secrets.md).
