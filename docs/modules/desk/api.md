# Desk API reference

Desk's web app is built entirely on this HTTP API, so anything the app can
do you can also script: create mailboxes, list and answer conversations,
assign them, and pair Desk with Den. This page lists **every route** in
[`backend/internal/http/router.go`](https://github.com/AGlElectronics/desk/blob/main/backend/internal/http/router.go),
with who may call it, the request and response bodies, the errors, and a
`curl` example.

The rules shared by every Con Services module (tokens, error shape, ids,
timestamps, how lists look) are on
[API conventions](../../concepts/api-conventions.md). This page only repeats
what you need to call Desk.

## Basics

| What | Value |
| --- | --- |
| Base address (browser, scripts) | The Desk address, for example `https://desk.example.org`. nginx forwards `/api/`, `/livez` and `/readyz` to the backend. |
| Base address (inside the cluster) | `https://desk-backend.conservices-desk.svc.cluster.local:8080` |
| Version prefix | `/api/v1` for everything except probes and the role catalog. |
| Request bodies | JSON, `Content-Type: application/json`. **Unknown fields are rejected** with `400` (the decoder is strict), so check spelling. |
| Ids | UUIDs. A malformed id in the path answers `400` `invalid <name> id: …`. |
| Times | RFC 3339 in UTC, for example `2026-11-06T12:00:00Z`. |
| Request id | Every response carries an `X-Request-ID` header; the same id is in the backend log line. Quote it when reporting a problem. |

In the examples, `$DESK` is the base address and `$TOKEN` is an access
token ([how to get one](../../concepts/api-conventions.md#get-a-token-for-curl)):

```sh
export DESK=https://desk.example.org
export TOKEN=eyJhbGciOi...   # access token from Keycloak for client desk-spa
```

## Authentication

| Caller | How | Accepted on |
| --- | --- | --- |
| Staff (production) | `Authorization: Bearer <token>` from Keycloak, verified against `OIDC_ISSUER_URL` | everything under `/api/v1` except the brand |
| Local development (`AUTH_MODE=dev` only) | `X-Dev-User: <name>` and optionally `X-Dev-Groups: desk-agent,…` (default `DEV_DEFAULT_USER`, `DEV_DEFAULT_GROUPS`) | the same routes |
| Anyone | nothing | probes, `/api/role-catalog`, `/api/v1/brand…` |

!!! danger "Dev mode trusts a header"
    In `AUTH_MODE=dev` anyone who can reach the backend can claim any user
    and any group. Use it only on your own machine. See
    [Authentication](../../concepts/authentication.md).

The first time someone signs in, Desk creates a local user for them (keyed
by token issuer and subject). Only people who have signed in at least once
appear in the assignee picker.

### Permissions

Groups in the token are mapped to roles by `infra/access-config.toml`; roles
carry permissions. A route answers `403` `permission denied` if you hold the
permission nowhere.

| Permission | What it allows | Default role (Keycloak group) |
| --- | --- | --- |
| `tickets.work` | Read and work conversations in **every** mailbox: reply, note, assign, change status, edit customers, download attachments. | `agent` (`desk-agent`), `organization_admin` (`desk-admin`) |
| `mailbox.manage` | Create, read, edit, test and delete mailboxes, including IMAP/SMTP settings. | `organization_admin` (`desk-admin`) |
| `settings.manage` | The Den pairing. | `organization_admin` (`desk-admin`) |

Per-mailbox access is planned, not built: today every agent sees every
mailbox.

## Errors

Every Desk error has this shape (see
[API conventions](../../concepts/api-conventions.md)):

```json
{"error":{"code":"validation_failed","message":"invalid mailbox","details":{"email":"must be a plain email address"}}}
```

| Status | `code` | Typical cause in Desk |
| --- | --- | --- |
| 400 | `bad_request` | Malformed JSON, unknown field, empty body, bad id, unknown `folder`, `kind` not `reply`/`note`, heartbeat `mode` wrong. |
| 401 | `unauthorized` | `missing bearer token` or `invalid token` (expired, wrong issuer or audience). |
| 403 | `forbidden` | You lack the permission the route needs. |
| 404 | `not_found` | `mailbox not found`, `conversation not found`, `thread not found`, `attachment not found`. |
| 409 | `conflict` | Duplicate mailbox email; undoing a reply that is already sending; retrying a reply that has not failed. |
| 422 | `validation_failed` | Field problems; `details` maps field name to the problem. |
| 500 | `internal` | Unexpected failure; the cause is in the backend log with the request id. |

The Den pairing routes add `pairing_failed` (422) and `sync_failed` (409
when not paired, 502 when Den cannot be reached).

## Endpoint overview

| # | Method | Path | Who |
| --- | --- | --- | --- |
| 1 | GET | `/livez` | anyone |
| 2 | GET | `/readyz` | anyone |
| 3 | GET | `/api/health` | anyone |
| 4 | GET | `/api/role-catalog` | anyone (HR) |
| 5 | GET | `/api/v1/brand` | anyone |
| 6 | GET | `/api/v1/brand/{role}` | anyone |
| 7 | GET | `/api/v1/me` | signed in |
| 8 | GET | `/api/v1/me/preferences` | signed in |
| 9 | PUT | `/api/v1/me/preferences` | signed in |
| 10 | GET | `/api/v1/users` | `tickets.work` |
| 11 | GET | `/api/v1/mailboxes` | `tickets.work` |
| 12 | POST | `/api/v1/mailboxes` | `mailbox.manage` |
| 13 | GET | `/api/v1/mailboxes/{mailbox}` | `mailbox.manage` |
| 14 | PATCH | `/api/v1/mailboxes/{mailbox}` | `mailbox.manage` |
| 15 | DELETE | `/api/v1/mailboxes/{mailbox}` | `mailbox.manage` |
| 16 | POST | `/api/v1/mailboxes/{mailbox}/test` | `mailbox.manage` |
| 17 | POST | `/api/v1/mailboxes/{mailbox}/fetch` | `mailbox.manage` |
| 18 | GET | `/api/v1/conversations` | `tickets.work` |
| 19 | POST | `/api/v1/conversations` | `tickets.work` |
| 20 | GET | `/api/v1/conversations/{conversation}` | `tickets.work` |
| 21 | PATCH | `/api/v1/conversations/{conversation}` | `tickets.work` |
| 22 | POST | `/api/v1/conversations/{conversation}/threads` | `tickets.work` |
| 23 | POST | `/api/v1/conversations/{conversation}/viewing` | `tickets.work` |
| 24 | POST | `/api/v1/threads/{thread}/undo` | `tickets.work` |
| 25 | POST | `/api/v1/threads/{thread}/retry` | `tickets.work` |
| 26 | PATCH | `/api/v1/customers/{customer}` | `tickets.work` |
| 27 | GET | `/api/v1/attachments/{attachment}` | `tickets.work` |
| 28 | GET | `/api/v1/den` | `settings.manage` |
| 29 | POST | `/api/v1/den/pair` | `settings.manage` |
| 30 | POST | `/api/v1/den/sync` | `settings.manage` |
| 31 | DELETE | `/api/v1/den/pair` | `settings.manage` |

**31 endpoints.**

---

## Probes and catalog

### `GET /livez`

Anyone. Answers `200` `{"status":"ok"}` while the process runs; it never
touches the database. Kubernetes restarts the pod when this fails.

### `GET /readyz`

Anyone. Pings PostgreSQL (2-second timeout).

```sh
curl -s $DESK/readyz
```

```json
{"status":"ok","database":"ok"}
```

When the database is unreachable it answers `503`
`{"status":"degraded","database":"down"}` (or `"not_configured"`), so
Kubernetes stops sending traffic without restarting the pod.

### `GET /api/health`

Anyone. The human-friendly version, with the build version and uptime.
`503` with `"status":"degraded"` when the database is down.

```sh
curl -s $DESK/api/health
```

```json
{"status":"ok","database":"ok","version":"0.3.0-1","uptime_sec":5400}
```

### `GET /api/role-catalog`

Anyone (HR calls it in-cluster to fill its access picker). One entry per
role and Keycloak group binding from the access configuration.

```sh
curl -s --cacert /etc/conservices-internal-ca/ca.crt https://desk-backend.conservices-desk.svc.cluster.local:8080/api/role-catalog
```

```json
{
  "module": "desk",
  "display_name": "Desk",
  "description": "Shared support inboxes and tickets.",
  "roles": [
    {"key": "agent", "label": "Agent",
     "description": "Answers support conversations: reply, note, assign, close.",
     "group": "desk-agent", "assignable": true, "scope": "organization:demo-org",
     "permissions": ["tickets.work"]},
    {"key": "organization_admin", "label": "Organization Admin",
     "description": "Manages mailboxes, every conversation and the module settings.",
     "group": "desk-admin", "assignable": true, "scope": "organization:demo-org",
     "permissions": ["mailbox.manage", "settings.manage", "tickets.work"]}
  ]
}
```

## Brand

### `GET /api/v1/brand`

Anyone (the sign-in screen needs it before sign-in). The local brand file,
overridden by Den's organisation name, logo, login background and theme once
paired. Sent with `Cache-Control: no-cache`.

```sh
curl -s $DESK/api/v1/brand
```

```json
{
  "revision": 4, "source": "den", "productName": "Desk",
  "organizationName": "Example Con", "logoUrl": "/api/v1/brand/logo?v=3f2a…",
  "colors": {"primary": "#6d28d9"}, "theme": {"primary": "#6d28d9"},
  "loginBackgroundUrl": "/api/v1/brand/login-background?v=91bc…",
  "loginLayout": "panel", "loginCaption": "Welcome back"
}
```

`source` is `standalone` before pairing; Den-only fields are then left out.

### `GET /api/v1/brand/{role}`

Anyone. The binary brand asset copied from Den, where `role` is `logo` or
`login-background`. Cached for a day (`Cache-Control: public, max-age=86400`).
`404` `no such brand asset` when Den has none or Desk is not paired.

```sh
curl -s -o logo.png "$DESK/api/v1/brand/logo"
```

## You

### `GET /api/v1/me`

Signed in. Who Desk thinks you are, your memberships and effective
permissions. The first thing to check when someone gets `403`.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $DESK/api/v1/me
```

```json
{
  "id": "5b1e0c44-8f1a-4c51-9a60-0d2c8e1f7a10",
  "display_name": "Alice Example",
  "email": "alice@example.org",
  "issuer": "https://auth.example.org/realms/conservices",
  "subject": "0a1b2c3d-1111-2222-3333-444455556666",
  "memberships": [{"organization_id": "0f1a9d2e-…", "role": "agent"}],
  "permissions": ["tickets.work"]
}
```

An empty `memberships` list means none of your Keycloak groups is bound to a
Desk role: add yourself to `desk-agent` or `desk-admin` and sign in again.

### `GET /api/v1/me/preferences`

Signed in. Your theme, stored in Den so every module shares it.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $DESK/api/v1/me/preferences
```

```json
{"theme":"dark","updated_at":"2026-11-01T18:20:00Z","synced":true}
```

`synced` is `false` (and `theme` falls back to `system`) when Desk is not
paired or Den is unreachable; the web app then keeps the choice locally.

### `PUT /api/v1/me/preferences`

Signed in. Body: `theme`, one of `system`, `light`, `dark`. Answers `200`
with the same shape as `GET`. `400` for invalid JSON, `422`
`theme must be system, light or dark`. If Den cannot be reached the request
still answers `200` with `synced:false`.

```sh
curl -s -X PUT $DESK/api/v1/me/preferences \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"theme":"light"}'
```

### `GET /api/v1/users`

`tickets.work`. Everyone who has signed in to Desk, sorted by name: the
assignee picker.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $DESK/api/v1/users
```

```json
{"people":[{"id":"5b1e…","display_name":"Alice Example","email":"alice@example.org"},
           {"id":"8d20…","display_name":"Bob Example","email":"bob@example.org"}]}
```

## Mailboxes

A **mailbox** is one shared support address with its own IMAP account
(incoming mail) and optionally its own SMTP server (outgoing mail). A
mailbox without `smtp_host` sends through the module-wide fallback set by
the `SMTP_*` variables ([Configuration](configuration.md)). Passwords are
encrypted at rest with `DESK_SECRET_KEY` and are **never returned**: responses
carry `imap_password_set` and `smtp_password_set` instead. See
[Secrets](../../operations/secrets.md).

### The mailbox object

| Field | Type | Notes |
| --- | --- | --- |
| `id`, `organization_id` | UUID | |
| `name` | string | Shown in the sidebar. Required. |
| `email` | string | A plain address (`support@example.org`, not `Support <…>`). Unique. Required. |
| `signature` | string | Appended to every reply. `{agent.name}` becomes the replying agent's name. |
| `imap_host`, `imap_port`, `imap_security`, `imap_username` | string, int, string, string | `imap_security` is `tls`, `starttls` or `none`. |
| `imap_password_set` | bool | Write with `imap_password`. |
| `smtp_host`, `smtp_port`, `smtp_security`, `smtp_username` | string, int, string, string | Empty `smtp_host` = use the module-wide fallback. |
| `smtp_password_set` | bool | Write with `smtp_password`. |
| `last_fetch_at` | time, optional | Last successful or attempted fetch. Left out until the first fetch. |
| `last_fetch_error` | string | `""` when the last fetch worked. |
| `created_at` | time | |

### `GET /api/v1/mailboxes`

`tickets.work`. Every mailbox, sorted by name, each with **folder counts from
your point of view** (`mine` counts conversations assigned to you).

```sh
curl -s -H "Authorization: Bearer $TOKEN" $DESK/api/v1/mailboxes
```

```json
{"mailboxes":[{
  "id":"c7e2a1d0-…","organization_id":"0f1a…","name":"Support","email":"support@example.org",
  "signature":"— {agent.name}, Support team","imap_host":"imap.example.org","imap_port":993,
  "imap_security":"tls","imap_username":"support@example.org","imap_password_set":true,
  "smtp_host":"","smtp_port":587,"smtp_security":"starttls","smtp_username":"","smtp_password_set":false,
  "last_fetch_at":"2026-11-06T11:59:00Z","last_fetch_error":"","created_at":"2026-11-01T09:00:00Z",
  "counts":{"unassigned":3,"mine":2,"assigned":5,"pending":4,"closed":120,"spam":1}}]}
```

### `POST /api/v1/mailboxes`

`mailbox.manage`. Creates a mailbox and asks the fetcher to read it right
away. Body: any field of the mailbox object plus `imap_password` and
`smtp_password`; `name` and `email` are required. Answers `201` with the
mailbox.

```sh
curl -s -X POST $DESK/api/v1/mailboxes \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"Support","email":"support@example.org","signature":"— {agent.name}, Support team",
       "imap_host":"imap.example.org","imap_port":993,"imap_security":"tls",
       "imap_username":"support@example.org","imap_password":"change-me"}'
```

```json
{"id":"c7e2a1d0-…","organization_id":"0f1a…","name":"Support","email":"support@example.org",
 "signature":"— {agent.name}, Support team","imap_host":"imap.example.org","imap_port":993,
 "imap_security":"tls","imap_username":"support@example.org","imap_password_set":true,
 "smtp_host":"","smtp_port":587,"smtp_security":"starttls","smtp_username":"","smtp_password_set":false,
 "last_fetch_error":"","created_at":"2026-11-06T12:00:00Z"}
```

| Status | When |
| --- | --- |
| `201` | Created. |
| `409` | `a mailbox with this email address already exists`. |
| `422` | `details` has `name: required`, `email: required` / `must be a plain email address`, or `imap_security` / `smtp_security: must be tls, starttls or none`. |

### `GET /api/v1/mailboxes/{mailbox}`

`mailbox.manage`. One mailbox (no folder counts). `404` `mailbox not found`.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $DESK/api/v1/mailboxes/c7e2a1d0-…
```

### `PATCH /api/v1/mailboxes/{mailbox}`

`mailbox.manage`. Changes only the fields you send. For passwords: **leave
the field out** to keep the stored one, send `""` to clear it. Changing
`imap_host` or `imap_username` makes Desk start again from the first message
of the new account. Triggers a fetch. Answers `200` with the mailbox; same
`404`, `409` and `422` as create.

```sh
curl -s -X PATCH $DESK/api/v1/mailboxes/c7e2a1d0-… \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"smtp_host":"smtp.example.org","smtp_port":587,"smtp_security":"starttls",
       "smtp_username":"support@example.org","smtp_password":"change-me"}'
```

### `DELETE /api/v1/mailboxes/{mailbox}`

`mailbox.manage`. Deletes the mailbox **and every conversation, thread and
attachment in it**. There is no undo. Answers `204`; `404` if it does not
exist.

```sh
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" $DESK/api/v1/mailboxes/c7e2a1d0-…
```

### `POST /api/v1/mailboxes/{mailbox}/test`

`mailbox.manage`. Logs in over IMAP (and opens `INBOX`) and over SMTP
without changing anything. Always `200` when the mailbox exists: read the
booleans.

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" $DESK/api/v1/mailboxes/c7e2a1d0-…/test
```

```json
{"imap_ok":true,"smtp_ok":false,"smtp_error":"dial tcp: i/o timeout","smtp_via":"smtp.example.org:587"}
```

`smtp_via` shows which server was tried, which tells you whether the
mailbox's own SMTP or the module-wide fallback is in use. `imap_error` is
`no IMAP server configured` when `imap_host` is empty.

### `POST /api/v1/mailboxes/{mailbox}/fetch`

`mailbox.manage`. Wakes the fetcher for this mailbox now instead of waiting
for `FETCH_INTERVAL`. Answers `202` `{"queued":true}`; the result shows up
later in `last_fetch_at` and `last_fetch_error`.

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" $DESK/api/v1/mailboxes/c7e2a1d0-…/fetch
```

## Conversations

A **conversation** (ticket) is one email thread with one customer. It has a
per-mailbox `number` (shown as `#17`), a `status` and at most one assignee.

| Status | Meaning |
| --- | --- |
| `active` | Needs an answer. |
| `pending` | Answered, waiting for the customer. A reply sets this by default. |
| `closed` | Done. `closed_at` is set. |
| `spam` | Hidden from every folder except Spam. |

### The conversation object

```json
{"id":"1d9b…","mailbox_id":"c7e2…","mailbox_name":"Support","number":17,
 "subject":"Lost badge","status":"active","preview":"Hi, I lost my badge on Saturday…",
 "customer":{"id":"55aa…","email":"guest@example.com","name":"Sam Guest","notes":""},
 "assignee_id":"5b1e…","assignee_name":"Alice Example","thread_count":2,
 "last_activity_at":"2026-11-06T11:58:00Z","created_at":"2026-11-06T09:12:00Z"}
```

`assignee_id`, `assignee_name` and `closed_at` are left out when empty.
`thread_count` counts customer messages, replies and notes, not system
lines. `preview` is the first 160 characters of the latest message.

### `GET /api/v1/conversations`

`tickets.work`. Query parameters, all optional:

| Parameter | Values |
| --- | --- |
| `mailbox` | A mailbox id; leave out for every mailbox. `400` `invalid mailbox id` if malformed. |
| `folder` | `unassigned` (default: active, nobody assigned), `mine` (active or pending, assigned to you), `assigned` (active or pending, assigned to anyone), `pending`, `closed`, `spam`, `all` (everything except spam). Anything else: `400` `unknown folder`. |
| `q` | Case-insensitive search in subject, customer email and name, and message text. `#17` or `17` also matches conversation number 17. |

At most 200 results, newest activity first. There is no paging yet.

```sh
curl -s -H "Authorization: Bearer $TOKEN" \
  "$DESK/api/v1/conversations?mailbox=c7e2a1d0-…&folder=all&q=badge"
```

```json
{"conversations":[{"id":"1d9b…","mailbox_id":"c7e2…","mailbox_name":"Support","number":17,
  "subject":"Lost badge","status":"active","preview":"Hi, I lost my badge on Saturday…",
  "customer":{"id":"55aa…","email":"guest@example.com","name":"Sam Guest","notes":""},
  "thread_count":1,"last_activity_at":"2026-11-06T11:58:00Z","created_at":"2026-11-06T09:12:00Z"}]}
```

### `POST /api/v1/conversations`

`tickets.work`. Starts a conversation from Desk (the agent writes first).
The customer is created or matched by email (stored lowercase); the body is
queued as the first reply, with the mailbox signature, exactly like
[a reply](#post-apiv1conversationsconversationthreads).

| Field | Required | Notes |
| --- | --- | --- |
| `mailbox_id` | yes | `404` `mailbox not found` if unknown. |
| `customer_email` | yes | `Name <addr>` is accepted; the name is used if `customer_name` is empty. |
| `customer_name` | no | Only fills an empty customer name; never overwrites one. |
| `subject` | yes | |
| `body` | yes | Plain text. |

Answers `201` with the conversation. Because a first reply is pending it
comes back with status `pending`, assigned to you.

```sh
curl -s -X POST $DESK/api/v1/conversations \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"mailbox_id":"c7e2a1d0-…","customer_email":"guest@example.com","customer_name":"Sam Guest",
       "subject":"Your dealer table","body":"Hi Sam, your table is confirmed for hall B."}'
```

```json
{"id":"4e01…","mailbox_id":"c7e2…","mailbox_name":"Support","number":18,"subject":"Your dealer table",
 "status":"pending","preview":"Hi Sam, your table is confirmed for hall B.",
 "customer":{"id":"55aa…","email":"guest@example.com","name":"Sam Guest","notes":""},
 "assignee_id":"5b1e…","assignee_name":"Alice Example","thread_count":1,
 "last_activity_at":"2026-11-06T12:05:00Z","created_at":"2026-11-06T12:05:00Z"}
```

`422` `invalid conversation` with `details` for `customer_email`, `subject`
or `body`.

### `GET /api/v1/conversations/{conversation}`

`tickets.work`. The full conversation: the conversation object plus
`threads` (oldest first, each with attachment metadata), `history` (the
customer's 20 most recent other conversations) and `viewers` (other agents
seen on it in the last 30 seconds).

```sh
curl -s -H "Authorization: Bearer $TOKEN" $DESK/api/v1/conversations/1d9b…
```

```json
{
  "id":"1d9b…","mailbox_id":"c7e2…","mailbox_name":"Support","number":17,"subject":"Lost badge",
  "status":"pending","preview":"We found it — pick it up at the info desk.",
  "customer":{"id":"55aa…","email":"guest@example.com","name":"Sam Guest","notes":"VIP"},
  "assignee_id":"5b1e…","assignee_name":"Alice Example","thread_count":2,
  "last_activity_at":"2026-11-06T12:01:00Z","created_at":"2026-11-06T09:12:00Z",
  "threads":[
    {"id":"a001…","kind":"customer","from_email":"guest@example.com","to":["support@example.org"],"cc":[],
     "body_html":"<p>Hi, I lost my badge on Saturday…</p>","body_text":"Hi, I lost my badge on Saturday…",
     "attachments":[{"id":"f9e8…","filename":"photo.jpg","content_type":"image/jpeg","size_bytes":183422}],
     "created_at":"2026-11-06T09:12:00Z"},
    {"id":"a002…","kind":"system","author_id":"5b1e…","author_name":"Alice Example","from_email":"",
     "to":[],"cc":[],"body_html":"Assigned to Alice Example","body_text":"Assigned to Alice Example",
     "attachments":[],"created_at":"2026-11-06T12:01:00Z"},
    {"id":"8c44…","kind":"reply","author_id":"5b1e…","author_name":"Alice Example",
     "from_email":"support@example.org","to":["guest@example.com"],"cc":[],
     "body_html":"We found it — pick it up at the info desk.<br>\n<br>\n— Alice Example, Support team",
     "body_text":"We found it — pick it up at the info desk.\n\n— Alice Example, Support team",
     "send_status":"sent","attachments":[],"created_at":"2026-11-06T12:01:00Z"}
  ],
  "history":[],
  "viewers":[{"user_id":"8d20…","display_name":"Bob Example","mode":"replying"}]
}
```

Thread fields:

| Field | Notes |
| --- | --- |
| `kind` | `customer` (incoming email), `reply` (agent email out), `note` (internal, never emailed), `system` (status or assignee change). |
| `send_status` | Replies only: `queued` (waiting, can be undone for 10 seconds), `sent`, `failed`. |
| `send_error`, `next_attempt_at` | Replies only, while retrying. Failed sends retry after 1, 5, 15 and 60 minutes, then stay `failed`. |
| `attachments[]` | `id`, `filename`, `content_type`, `size_bytes`. Download with [`GET /api/v1/attachments/{attachment}`](#get-apiv1attachmentsattachment). |

### `PATCH /api/v1/conversations/{conversation}`

`tickets.work`. Change status, assignee, or both. Each real change adds a
`system` thread ("Status changed to closed", "Assigned to Alice Example",
"Unassigned"). Sending the current value changes nothing.

| Field | Values |
| --- | --- |
| `status` | `active`, `pending`, `closed`, `spam`. |
| `assignee_id` | A Desk user id to assign; `""` to unassign; leave out to keep. |

```sh
curl -s -X PATCH $DESK/api/v1/conversations/1d9b… \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"assignee_id":"8d20…","status":"active"}'
```

Answers `200` with the conversation object (without threads).

| Status | When |
| --- | --- |
| `400` | `invalid assignee_id` (not a UUID). |
| `404` | Conversation not found. |
| `422` | `status: must be active, pending, closed or spam`, or `assignee_id: not a Desk user` (they never signed in). |

### `POST /api/v1/conversations/{conversation}/threads`

`tickets.work`. Reply to the customer or add an internal note.

| Field | Required | Notes |
| --- | --- | --- |
| `kind` | yes | `reply` or `note`. |
| `body` | yes | Plain text; Desk makes the HTML version. |
| `status` | no | Replies only: status afterwards, default `pending`. |

A **reply** gets the mailbox signature, is queued and sent **10 seconds
later**, so [undo](#post-apiv1threadsthreadundo) can take it back.
Answering an unassigned conversation assigns it to you. A **note** is only
stored. Answers `201` with the new thread id.

```sh
curl -s -X POST $DESK/api/v1/conversations/1d9b…/threads \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"kind":"reply","body":"We found it — pick it up at the info desk.","status":"closed"}'
```

```json
{"id":"8c44f0a2-…"}
```

| Status | When |
| --- | --- |
| `400` | `kind must be reply or note`. |
| `422` | `body: required`, or an invalid `status`. |

### `POST /api/v1/conversations/{conversation}/viewing`

`tickets.work`. Collision-detection heartbeat: tells Desk you are looking at
or typing in this conversation. The web app sends it repeatedly while the
conversation is open; other agents see you in `viewers` for 30 seconds after the last one.

Body: `{"mode":"viewing"}` or `{"mode":"replying"}`. Answers `204`. `400`
`mode must be viewing or replying`.

```sh
curl -s -X POST $DESK/api/v1/conversations/1d9b…/viewing \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"mode":"replying"}'
```

### `POST /api/v1/threads/{thread}/undo`

`tickets.work`. Deletes a reply that is still waiting in its 10-second
window. Answers `204`. `404` `thread not found`; `409`
`too late: the reply is already being sent`.

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" $DESK/api/v1/threads/8c44f0a2-…/undo
```

Undoing does not revert the status or assignee change the reply made.

### `POST /api/v1/threads/{thread}/retry`

`tickets.work`. Puts a `failed` reply back in the queue for an immediate
attempt. Answers `204`. `404` `thread not found`; `409`
`only failed replies can be retried`.

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" $DESK/api/v1/threads/8c44f0a2-…/retry
```

## Customers and attachments

### `PATCH /api/v1/customers/{customer}`

`tickets.work`. Change a customer's `name` and/or `notes` (fields you leave
out stay). Answers `204`. The customer's email cannot be changed: it is how
incoming mail is matched. An unknown id also answers `204` (nothing is
changed).

```sh
curl -s -X PATCH $DESK/api/v1/customers/55aa… \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"notes":"VIP; prefers phone."}'
```

### `GET /api/v1/attachments/{attachment}`

`tickets.work`. Downloads an attachment. Always served as a download
(`Content-Disposition: attachment; filename=…`) with
`X-Content-Type-Options: nosniff`, so a hostile attachment cannot run in
the browser. `404` `attachment not found`.

```sh
curl -s -OJ -H "Authorization: Bearer $TOKEN" $DESK/api/v1/attachments/f9e8…
```

## Den pairing

Pairing connects Desk to Den for brand, settings and shared preferences
([Pairing](../../concepts/pairing.md)). All four routes need
`settings.manage`.

### `GET /api/v1/den`

```sh
curl -s -H "Authorization: Bearer $TOKEN" $DESK/api/v1/den
```

```json
{"paired":true,"den_base_url":"https://den-backend.conservices-den.svc.cluster.local:8080",
 "module_id":"3c9d…","paired_at":"2026-11-01T09:00:00Z","synced_at":"2026-11-06T11:55:00Z"}
```

Unpaired: `{"paired":false}`. `last_error` appears when the last sync failed.

### `POST /api/v1/den/pair`

Body: `pairing_url`, the one-time link from Den's **Modules** page. Answers
`200` with the status. `400` for invalid JSON; `422` `pairing_failed` with
Den's reason (link expired or used, Den unreachable).

```sh
curl -s -X POST $DESK/api/v1/den/pair \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"pairing_url":"https://den.example.org/pair/abc123…"}'
```

### `POST /api/v1/den/sync`

Fetches brand and settings from Den now. Answers `200` with the status.
`409` `sync_failed` when not paired, `502` `sync_failed` when Den cannot be
reached.

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" $DESK/api/v1/den/sync
```

### `DELETE /api/v1/den/pair`

Forgets the pairing; Desk falls back to its own brand file. Answers `204`.

```sh
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" $DESK/api/v1/den/pair
```

## Troubleshooting

| Symptom | Likely cause and fix |
| --- | --- |
| `401` `missing bearer token` | No `Authorization: Bearer` header; in `curl`, check `$TOKEN` is set. |
| `401` `invalid token` | Token expired (they last minutes), or issued by a different realm than `OIDC_ISSUER_URL`. Get a fresh one. |
| `403` `permission denied` everywhere | `GET /api/v1/me` shows empty `permissions`: add the person to `desk-agent` or `desk-admin` in Keycloak and sign in again. |
| `403` on `GET /api/v1/mailboxes/{id}` but the list works | Reading one mailbox's settings needs `mailbox.manage`; the list only needs `tickets.work`. |
| `400` `invalid JSON: json: unknown field "…"` | Desk rejects unknown fields. Check the field names in the tables above. |
| `last_fetch_error` set, no new conversations | Run `POST …/test`. `imap_error` tells you whether it is DNS, TLS (`imap_security`) or the login. |
| Replies stuck as `failed` | `send_error` on the thread says why; fix SMTP with `PATCH`, test, then `POST /api/v1/threads/{id}/retry`. |
| `stored password cannot be decrypted (was DESK_SECRET_KEY changed?)` | `DESK_SECRET_KEY` changed since the password was saved. Restore the old key or re-enter the mailbox passwords. See [Secrets](../../operations/secrets.md). |
| `409` on undo | More than 10 seconds passed; the reply is on its way. Send a follow-up instead. |
