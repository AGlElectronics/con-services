# Changelog

All notable changes to Feedback are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

Compatible with Den MAJOR 1.
Needs Den: 1.0.0 or later (Den MAJOR 1).

### Added

- Development scaffold: Go backend, Postgres store, Compose profile
  `feedback` (also starts with `intercom`), host `feedback.conservices.test`,
  inbox UI on port 3014 / API on 8172.
- Telegram conversation (via Intercom poller → `POST /api/v1/telegram/message`):
  polarity → anonymity (defaults: negative anonymous, positive named) →
  department (incl. Board) → body → board notify (default yes).
- Choice steps use Telegram **reply keyboards** (Positive/Negative, Anonymous/
  Named, department buttons, board notify). Only the free-text body step
  hides the keyboard.
- Optional board Telegram notify using the catch-all / Intercom board chat.
- Inbox UI with polarity and department filters.
