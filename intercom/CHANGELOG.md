# Changelog

All notable changes to Intercom are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

Compatible with Den MAJOR 1.
Needs Den: 1.0.0 or later (Den MAJOR 1).

### Added

- Development scaffold: Go backend, Postgres store, static inbox UI, Compose
  profile `intercom`, `intercom.conservices.test` proxy host.
- Telegram staff commands on `INTERCOM_TELEGRAM_BOT_TOKEN` /
  `TELEGRAM_BOT_TOKEN`:
  - `/board <question>` in group chats relays to the configured board
    chat/topic and stores a reply mapping.
  - Board replies to a relayed message are posted back into the source chat.
  - `/idea <text>` creates a task in Tasks → **Intercom** → **Ideas**
    (via `POST /api/internal/ideas`), stores the capture locally, and posts
    it to the board (optional `INTERCOM_IDEAS_THREAD_ID`).
  - `/help` explains the commands.
- Public read APIs for recent board relays and ideas (dev scaffold; no OIDC
  yet).
- Renamed from the working title “Herald” to **Intercom** (Compose profile,
  host `intercom.conservices.test`, env `INTERCOM_*`).
- Forwards private Telegram chats and `/feedback` to the Feedback module
  (`FEEDBACK_INTERNAL_URL`) so one bot token can still long-poll.
