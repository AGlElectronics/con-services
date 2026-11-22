# Intercom

Intercom is the Con Services staff communications module. The 1.1 scaffold
starts with the Telegram bridge from the roadmap notes: department groups
can ask the board with `/board`, capture ideas with `/idea`, and get
board answers relayed back. Official notices, meeting cards and Feedback
routing stay for later fine-tuning — see the
[staff communications proposal](../../proposals/staff-communications.md).

## What works now

- Long-poll the staff bot (`INTERCOM_TELEGRAM_BOT_TOKEN` or
  `TELEGRAM_BOT_TOKEN`).
- `/board <question>` in a group or forum topic → formatted post in the
  board chat/topic.
- Reply to that board message → Intercom posts the answer back in the
  source chat (threaded when possible).
- `/idea <text>` in a group or a private chat with the bot → creates a
  task in **Tasks → Intercom → Ideas**, stores the capture in Intercom,
  and posts it for the board.
- A small local UI listing recent board questions and ideas (with task
  keys when the Tasks bridge is on).

## What is not in this cut

- Department topic map, digests, Feedback bot, Den unread strip,
  OIDC/denlink, or production Kubernetes charts.

Only **one** service may call Telegram `getUpdates` for a given bot
token. While Intercom owns the staff bot, keep Stash Lost & Found Telegram
off for that same token (or use a second bot for Stash).

See [Setup](setup.md), [Configuration](configuration.md), the
[API](api.md) and [Personal data](../../operations/personal-data.md#intercom).
