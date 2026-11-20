# Set up Feedback

1. Ensure the `feedback` database exists (Compose init creates it on fresh
   volumes). On an older volume:

   ```sh
   docker compose exec -T postgres psql -U postgres -c "CREATE ROLE feedback LOGIN PASSWORD 'feedback';"
   docker compose exec -T postgres psql -U postgres -c "CREATE DATABASE feedback OWNER feedback;"
   ```

2. Start Feedback with Intercom (Intercom owns `getUpdates`):

   ```sh
   docker compose --profile intercom up --build feedback-frontend intercom-frontend
   ```

3. Open <http://localhost:3014> (or <https://feedback.conservices.test>).

4. DM `@Confuratio_staff_bot` (or your token’s bot) with `/feedback` and
   walk through the prompts. Finished notes appear in the inbox; board
   notify posts into the configured board chat/topic.

## Troubleshooting

**/feedback does nothing**
: Intercom must be running (it polls Telegram) and
  `FEEDBACK_INTERNAL_URL` must reach `feedback-backend`. Check both logs.

**Board never gets a copy**
: Board notify was answered `no`, or board chat id is unset. Check
  `/readyz` on Feedback for `board_chat_id`.

**Wrong department list**
: Set `FEEDBACK_DEPARTMENTS` in `.env` (comma-separated) and recreate
  `feedback-backend`.
