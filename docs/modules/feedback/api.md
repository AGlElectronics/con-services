# Feedback API

Dev scaffold — unauthenticated reads for the local inbox. The Telegram
ingress is service-token protected.

## `GET /readyz`

```bash
curl -s http://localhost:8172/readyz
```

## `GET /api/v1/status`

Counts and department list for the UI.

## `GET /api/v1/submissions`

Query: `polarity=positive|negative`, `department=Ops`.

```bash
curl -s "http://localhost:8172/api/v1/submissions?polarity=negative"
```

## `POST /api/v1/telegram/message`

Who may call: Intercom with `Authorization: Bearer <FEEDBACK_SERVICE_TOKEN>`.

```bash
curl -s -X POST http://localhost:8172/api/v1/telegram/message \
  -H "Authorization: Bearer feedback-dev-token" \
  -H "Content-Type: application/json" \
  -d '{"chat_id":123,"chat_type":"private","message_id":1,"text":"/feedback","telegram_user_id":1,"telegram_name":"Taire"}'
```

```json
{"handled":true,"reply":"Feedback time.\n\nIs this positive or negative?\nTap a button below."}
```

The HTTP response is only `handled` / `reply`. Reply keyboards are attached
by Feedback when it sends the Telegram message (not returned to Intercom).
