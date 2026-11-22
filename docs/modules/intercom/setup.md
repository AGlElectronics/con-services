# Set up Intercom

Intercom 1.1 is a development scaffold. It needs Postgres and a Telegram
bot token. OIDC is not enabled yet.

## Run locally

1. Put the staff bot token and board destination in the root `.env`. For
   local testing you can reuse the catch-all values:

   ```dotenv
   TELEGRAM_BOT_TOKEN=123456:AA…
   TELEGRAM_DEV_CATCHALL_CHAT_ID=-1003787521365
   TELEGRAM_DEV_CATCHALL_THREAD_ID=599
   ```

   Or set `INTERCOM_TELEGRAM_BOT_TOKEN`, `INTERCOM_BOARD_CHAT_ID` and
   `INTERCOM_BOARD_THREAD_ID` explicitly.

2. Make sure the `intercom` database exists (fresh Compose volumes create
   it from `infra/postgres/01-init-databases.sh`). On an older volume:

   ```sh
   docker compose exec -T postgres psql -U postgres -c "CREATE ROLE intercom LOGIN PASSWORD 'intercom';"
   docker compose exec -T postgres psql -U postgres -c "CREATE DATABASE intercom OWNER intercom;"
   ```

3. Start Intercom:

   ```sh
   docker compose --profile intercom up --build intercom-frontend
   ```

4. Open <http://localhost:3012> (or <https://intercom.conservices.test>
   when the proxy is up). Check the API:

   ```sh
   curl http://localhost:8171/readyz
   ```

5. In a **department group** where the bot is a member, send:

   ```text
   /board Do we have budget for more radios?
   ```

   You should get a confirmation in the group, and the board chat/topic
   should show the formatted question. Reply to that board message; the
   answer should appear back in the group.

6. Capture an idea (group or DM with the bot):

   ```text
   /idea Put water stations near the outdoor stage
   ```

## Add the bot to Telegram

1. Create or reuse the staff bot in BotFather
   (`@confuratio_staff_bot` in the plan notes).
2. Add it to the department groups and to the board forum chat.
3. Give it permission to post in the board topic you configure.
4. Privacy mode can stay on: Telegram still delivers `/commands` and
   replies to the bot’s own messages.

## Troubleshooting

**/board does nothing**
: Intercom is not running, the token is empty, or another process (for
  example Stash Lost & Found with the same token) is consuming
  `getUpdates`. Check `docker logs conservices-intercom-backend` and keep
  only one poller per token.

**/board says it is for group chats**
: Use it in a group or forum topic, not in a private DM.

**Board never gets the message**
: `INTERCOM_BOARD_CHAT_ID` / catch-all chat id is wrong, or the bot is not
  in that chat/topic. Confirm with `/readyz` (`board_chat_id`).

**Reply-back does not arrive**
: Reply **to the Intercom message** in the board chat (Telegram “Reply”),
  not as a free-standing message in the topic.

**Port 3012 or 8171 is already in use**
: Stop the process using the port or change the host-side port in the
  root `docker-compose.yml`. Do not change container port 8080.
