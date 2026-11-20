# Feedback

Feedback collects staff notes through a private Telegram conversation and
shows them in a small inbox. Positive or negative, anonymous or named,
routed to a department (including the board), with an optional board
notify. Delivery into Telegram is coordinated with
[Intercom](../intercom/index.md) so one staff bot token can still long-poll.

## Conversation

1. DM the staff bot `/feedback` (or `/start`).
2. **Positive** or **Negative** — Telegram buttons.
3. **Anonymous**, **Named**, or **Use default** (negative → anonymous,
   positive → named) — buttons.
4. Department (includes Board) — one button per department.
5. The feedback text — free typing (keyboard hidden).
6. **Notify board** / **Don't notify board** / **Use default** (notify) —
   buttons.

`/cancel` or the **Cancel** button aborts. In a group, `/feedback` tells
people to open a private chat.

## What is not in this cut

- Dedicated `@…_feedback_bot` token (optional later).
- Live HR department catalogue (env list for now).
- Web compose form / OIDC / denlink.
- Audit unlock for anonymous notes.

See [Setup](setup.md), [Configuration](configuration.md) and the [API](api.md).
