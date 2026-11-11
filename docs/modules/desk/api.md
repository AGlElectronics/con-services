# Desk API reference

Desk's web app is built entirely on this HTTP API, so anything the app can
do you can also script: create mailboxes, list and answer conversations,
assign them, manage the trash and retention, and pair Desk with Den. This
page lists **every route** in
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
| Version prefix | `/api/v1` for everything except probes, the role catalog and `/api/den/state`. |
| Request bodies | JSON, `Content-Type: application/json`. **Unknown fields are rejected** with `400` (the decoder is strict), so check spelling. |
| Ids | UUIDs (audit entries: numbers). A malformed id in the path answers `400` `invalid <name> id: …`. |
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
| Staff (production) | `Authorization: Bearer <access token>` from Keycloak, audience `desk-api` (`OIDC_AUDIENCE`). ID tokens are refused. | everything under `/api/v1` except the brand and `den/state` |
| Local development (`AUTH_MODE=dev` and `APP_ENV=development`) | `X-Dev-User: <name>` and optionally `X-Dev-Groups: desk-info-manager,…` (default `DEV_DEFAULT_USER`, `DEV_DEFAULT_GROUPS`). The headers are removed in every other mode. | the same routes |
| HR's backend | `Authorization: Bearer <HR_SERVICE_TOKEN>` | only `GET /api/role-catalog` |
| Den's backend | `Authorization: Bearer <the module credential>` plus `X-Den-User-Issuer` and `X-Den-User-Subject` | only `GET /api/portal/todos` |
| Anyone | nothing | probes, `/api/den/state`, `/api/v1/brand…` |

!!! danger "Dev mode trusts a header"
    In `AUTH_MODE=dev` anyone who can reach the backend can claim any user
    and any group. Use it only on your own machine. See
    [Authentication](../../concepts/authentication.md).

The first time someone signs in, Desk creates a local user for them (keyed
by token issuer and subject) and remembers their groups. Only people who
have signed in at least once appear in the assignee picker.

### Who may do what

Access is **per mailbox** ([Access](access.md)). In the tables below:

| Shorthand | Means |
| --- | --- |
| **signed in** | Any valid token. |
| **viewer** | Any of the mailbox's roles (`desk-<slug>-viewer`, `-manager` or `-delete`), or Desk admin. |
| **manager** | The mailbox's `desk-<slug>-manager` role, or Desk admin. |
| **delete** | The mailbox's `desk-<slug>-delete` role, or Desk admin. |
| **admin** | Desk admin (`mailbox.manage`, group `desk-admin`) in the mailbox's organization. For routes without a mailbox: Desk admin anywhere. |
| **settings.manage** | The permission of that name (group `desk-admin`). |

A mailbox, conversation, thread, customer or attachment you may not view
answers **404**, never 403, so ids cannot be probed. One you may view but
not change answers **403**, for example
`you need the manager role of this mailbox` or `only Desk admins may do this`.

## Errors

Every Desk error has this shape (see
[API conventions](../../concepts/api-conventions.md)):

```json
{"error":{"code":"validation_failed","message":"invalid mailbox","details":{"email":"must be a plain email address"}}}
```

| Status | `code` | Typical cause in Desk |
| --- | --- | --- |
| 400 | `bad_request` | Malformed JSON, unknown field, empty body, bad id, unknown `folder`, bad `cursor`, `kind` not `reply`/`note`, heartbeat `mode` wrong, merging something into itself. |
| 401 | `unauthorized` | `missing bearer token` or `invalid token` (expired, wrong issuer or audience, or an ID token). Also a wrong credential on `GET /api/portal/todos`. |
| 413 | `request_too_large` | JSON body over 1 MiB, or over 20 MiB on a message (new conversation, reply, forward, mailbox signature, saved reply). |
| 429 | `rate_limited` | Too many calls to `GET /api/portal/todos` from one client. `Retry-After` says how long to wait. |
| 403 | `forbidden` | You see the mailbox but lack the role for this action. |
| 404 | `not_found` | Does not exist, or you have no role for its mailbox. |
| 409 | `conflict` | Duplicate mailbox address; already in or not in the trash; undo too late; retry of a reply that has not failed; Google refused. |
| 422 | `validation_failed` | Field problems; `details` maps field name to the problem. |
| 500 | `internal` | Unexpected failure; the cause is in the backend log with the request id. |
| 503 | `den_pairing_required` | `DEN_MODE=required` and Desk is not paired yet (all `/api` routes except health, role catalog, brand, `me` and `den`). |

The Den pairing routes add `pairing_failed` (422) and `sync_failed` (409
when not paired, 502 when Den cannot be reached).

## Endpoint overview

| # | Method | Path | Who |
| --- | --- | --- | --- |
| 1 | GET | `/livez` | anyone |
| 2 | GET | `/readyz` | anyone |
| 3 | GET | `/api/health` | anyone |
| 4 | GET | `/api/role-catalog` | HR's service token, or any signed-in staff member |
| 4b | GET | `/api/portal/todos` | Den, with the module credential |
| 5 | GET | `/api/den/state` (also `/api/v1/den/state`) | anyone |
| 6 | GET | `/api/v1/brand` | anyone |
| 7 | GET | `/api/v1/brand/{role}` | anyone |
| 8 | GET | `/api/v1/me` | signed in |
| 9 | GET | `/api/v1/me/preferences` | signed in |
| 10 | PUT | `/api/v1/me/preferences` | signed in |
| 11 | GET | `/api/v1/me/notifications` | signed in |
| 12 | PUT | `/api/v1/me/notifications` | signed in |
| 13 | GET | `/api/v1/mailboxes` | signed in (lists what you may view) |
| 14 | POST | `/api/v1/mailboxes` | admin |
| 15 | GET | `/api/v1/mailboxes/trash` | admin |
| 16 | GET | `/api/v1/mailboxes/{mailbox}` | viewer |
| 17 | PATCH | `/api/v1/mailboxes/{mailbox}` | manager (signature, auto-reply), admin (everything) |
| 18 | DELETE | `/api/v1/mailboxes/{mailbox}` | admin |
| 19 | POST | `/api/v1/mailboxes/{mailbox}/restore` | admin |
| 20 | POST | `/api/v1/mailboxes/{mailbox}/purge` | admin |
| 21 | POST | `/api/v1/mailboxes/{mailbox}/provision` | admin |
| 22 | POST | `/api/v1/mailboxes/{mailbox}/test` | admin |
| 23 | POST | `/api/v1/mailboxes/{mailbox}/fetch` | admin |
| 24 | GET | `/api/v1/mailboxes/{mailbox}/import-failures` | admin |
| 25 | GET | `/api/v1/mailboxes/{mailbox}/saved-replies` | viewer |
| 26 | GET | `/api/v1/conversations` | signed in (searches what you may view) |
| 27 | POST | `/api/v1/conversations` | manager |
| 28 | GET | `/api/v1/conversations/{conversation}` | viewer |
| 29 | PATCH | `/api/v1/conversations/{conversation}` | manager |
| 30 | DELETE | `/api/v1/conversations/{conversation}` | delete |
| 31 | POST | `/api/v1/conversations/{conversation}/restore` | delete |
| 32 | POST | `/api/v1/conversations/{conversation}/threads` | manager |
| 33 | POST | `/api/v1/conversations/{conversation}/forward` | manager |
| 34 | POST | `/api/v1/conversations/{conversation}/merge` | manager of both |
| 35 | POST | `/api/v1/conversations/{conversation}/move` | manager of both mailboxes |
| 36 | PUT | `/api/v1/conversations/{conversation}/star` | viewer |
| 37 | DELETE | `/api/v1/conversations/{conversation}/star` | viewer |
| 38 | POST | `/api/v1/conversations/{conversation}/viewing` | viewer |
| 39 | POST | `/api/v1/threads/{thread}/undo` | the reply's author |
| 40 | POST | `/api/v1/threads/{thread}/retry` | the author, or manager |
| 41 | DELETE | `/api/v1/threads/{thread}` | delete |
| 42 | POST | `/api/v1/threads/{thread}/restore` | delete |
| 43 | GET | `/api/v1/customers` | signed in (searches what you may view) |
| 44 | GET | `/api/v1/customers/{customer}` | viewer of one of their conversations |
| 45 | PATCH | `/api/v1/customers/{customer}` | manager of one of their conversations' mailboxes |
| 46 | POST | `/api/v1/customers/{customer}/merge` | manager for both customers |
| 47 | GET | `/api/v1/attachments/{attachment}` | viewer |
| 48 | GET | `/api/v1/users` | viewer of `mailbox`; admin without it |
| 49 | GET | `/api/v1/tags` | signed in |
| 50 | POST | `/api/v1/saved-replies` | manager (mailbox), admin (global) |
| 51 | PATCH | `/api/v1/saved-replies/{reply}` | same |
| 52 | DELETE | `/api/v1/saved-replies/{reply}` | same |
| 53 | GET | `/api/v1/settings/retention` | admin |
| 54 | PUT | `/api/v1/settings/retention` | admin |
| 55 | GET | `/api/v1/settings/integrations` | admin |
| 56 | GET | `/api/v1/audit` | admin |
| 57 | GET | `/api/v1/den` | settings.manage |
| 58 | POST | `/api/v1/den/pair` | settings.manage |
| 59 | POST | `/api/v1/den/sync` | settings.manage |
| 60 | DELETE | `/api/v1/den/pair` | settings.manage |

**60 endpoints.**

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
{"status":"ok","database":"ok","version":"1.0.0-1","uptime_sec":5400}
```

### `GET /api/role-catalog`

HR's backend calls this with `Authorization: Bearer $HR_SERVICE_TOKEN`
(compared in constant time; the token allows nothing else). Anyone signed
in to Desk may also read it. With no token and no sign-in the answer is
`401 unauthorized`. Without `HR_SERVICE_TOKEN` configured, only a sign-in works.

One entry per module-wide role and Keycloak group binding, then **three
dynamic entries per mailbox** not in the trash (`dynamic: true`). `group`
is the normalised group name and `group_display` is the name as written.
`privileged` is true for Desk admin and for each mailbox's delete role.
`scope` is `organization` or `mailbox`. Mailbox entries have no permissions
and put the address in `note`. The body includes `revision`, also sent as
the `ETag` header. Send that value back as `If-None-Match` to get `304`.

```sh
curl -s --cacert /etc/conservices-internal-ca/ca.crt \
  -H "Authorization: Bearer $HR_SERVICE_TOKEN" \
  https://desk-backend.conservices-desk.svc.cluster.local:8080/api/role-catalog
```

```json
{
  "module": "desk",
  "display_name": "Desk",
  "description": "Shared support inboxes and tickets.",
  "roles": [
    {"key": "organization_admin", "label": "Desk admin",
     "description": "Desk admin: creates, configures and deletes mailboxes; full access to every mailbox (read, answer, delete, email any address from them); retention, audit log and module settings.",
     "group": "desk-admin", "assignable": true, "scope": "organization:demo-org",
     "permissions": ["mailbox.manage", "settings.manage"]},
    {"key": "desk_registration_viewer", "label": "Registration viewer",
     "description": "Reads the conversations of Registration (registration@example.org).",
     "group": "desk-registration-viewer", "assignable": true, "scope": "mailbox:registration",
     "permissions": [], "note": "registration@example.org"},
    {"key": "desk_registration_manager", "label": "Registration manager",
     "description": "Works Registration (registration@example.org): reply, note, assign, close, tags, saved replies, signature and auto-reply; can start conversations with any address from it.",
     "group": "desk-registration-manager", "assignable": true, "scope": "mailbox:registration",
     "permissions": [], "note": "registration@example.org"},
    {"key": "desk_registration_delete", "label": "Registration delete",
     "description": "Deletes and restores emails and conversations of Registration (registration@example.org); deleted mail also goes to the provider's trash.",
     "group": "desk-registration-delete", "assignable": true, "scope": "mailbox:registration",
     "permissions": [], "note": "registration@example.org"}
  ]
}
```

Slugs with dashes become underscores in the role key
(`lost-found` → `desk_lost_found_viewer`); the group keeps the dash
(`desk-lost-found-viewer`).

### `GET /api/portal/todos`

Den's backend calls this, server to server, to list what the signed-in
person should do in Desk. The browser never calls it. See
[Portal to-dos](../den/admin-guide.md#portal-to-dos).

**Who:** Den, with `Authorization: Bearer <the credential Desk received when it paired>`.
Not paired: `404 not_found`. A wrong credential, a revoked credential, or one
Desk cannot decrypt: `401 unauthorized` with `invalid or revoked credential`
(the answer does not say which). Missing `X-Den-User-Issuer` or
`X-Den-User-Subject`: `400 bad_request`.

**Headers:** `X-Den-User-Issuer` and `X-Den-User-Subject` name the person.
An unknown person gets `{"items": []}`, not an error.

**Response:** `200` with at most 50 open conversations (`active` or
`pending`) assigned to that person. `url` is `APP_BASE_URL` plus
`/conversations/<id>` (set `APP_BASE_URL` or Den drops the item). `severity`
is `warning` when the conversation is pending and `info` otherwise.

```sh
curl -s --cacert /etc/conservices-internal-ca/ca.crt \
  -H "Authorization: Bearer $DESK_MODULE_CREDENTIAL" \
  -H "X-Den-User-Issuer: https://auth.conservices.test/realms/conservices" \
  -H "X-Den-User-Subject: 0b6e2c4d-8f1a-4b3c-9d7e-5a6b7c8d9e0f" \
  https://desk-backend.conservices-desk.svc.cluster.local:8080/api/portal/todos
```

```json
{"items":[{"id":"6f1c2d7e-0b7a-4e57-9a7e-2b1d3c4e5f60","title":"Badge not printed","detail":"Registration","url":"https://desk.example.org/conversations/6f1c2d7e-0b7a-4e57-9a7e-2b1d3c4e5f60","severity":"info"}]}
```

The chart's network policy admits `den-backend` from `conservices-den` on the backend port.

### `GET /api/den/state`

Anyone. Also at `/api/v1/den/state`. Whether Desk must be paired and is.

```sh
curl -s $DESK/api/den/state
```

```json
{"mode":"required","paired":true}
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

Signed in. Who Desk thinks you are, your module roles and permissions,
whether you are Desk admin, and **every mailbox you can see with your
rights in it**. The first thing to check when someone gets `403` or `404`.

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
  "memberships": [],
  "permissions": [],
  "is_admin": false,
  "mailboxes": [
    {"id": "c7e2a1d0-…", "slug": "registration", "name": "Registration",
     "email": "registration@example.org",
     "access": {"view": true, "work": true, "delete": false, "admin": false}}
  ]
}
```

`memberships` and `permissions` only list module-wide roles (Desk admin).
`access.work` is the manager role, `access.delete` the delete role. An
empty `mailboxes` list means you have no mailbox role: see [Access](access.md).

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

### `GET /api/v1/me/notifications`

Signed in. Your email notification settings. Both are off until you turn
them on. `available` is `false` when the installation cannot send Desk's
own emails (no `NOTIFY_FROM`, or no way to send).

```sh
curl -s -H "Authorization: Bearer $TOKEN" $DESK/api/v1/me/notifications
```

```json
{"new_conversation":false,"assigned_to_me":true,"available":true}
```

### `PUT /api/v1/me/notifications`

Signed in. Body: both booleans. Answers `200` with the same shape as `GET`.

| Field | Sends you an email when |
| --- | --- |
| `new_conversation` | A new conversation arrives in a mailbox you can see. |
| `assigned_to_me` | Someone else assigns a conversation to you. |

```sh
curl -s -X PUT $DESK/api/v1/me/notifications \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"new_conversation":true,"assigned_to_me":true}'
```

## Mailboxes

A **mailbox** is one shared support address. Its **connector** says where
the mail lives: `google_user` or `google_group` in Google Workspace
([setup](google-workspace.md)), or `imap` on any IMAP/SMTP server
([setup](imap.md)). Its **slug** names its roles. Passwords are encrypted at
rest and **never returned**: responses carry `imap_password_set` and
`smtp_password_set` instead.

### The mailbox object

What you get depends on who you are. **Everyone with a role** gets the
summary:

| Field | Type | Notes |
| --- | --- | --- |
| `id`, `organization_id` | UUID | |
| `slug` | string | Names the roles. Set on create, never changes. |
| `name`, `email` | string | |
| `connector` | string | `imap`, `google_user` or `google_group`. |
| `signature` | string | Appended to every reply. `{agent.name}` becomes the replying person's name. |
| `auto_reply` | object | `enabled`, `subject`, `body_html`, `body_text`. |
| `access` | object | Your rights: `view`, `work`, `delete`, `admin`. |
| `counts` | object | Folder counts from your point of view: `unassigned`, `mine`, `assigned`, `pending`, `closed`, `spam`, `starred`, `trash`. |

**Desk admins** get the full configuration on top:

| Field | Type | Notes |
| --- | --- | --- |
| `imap_host`, `imap_port`, `imap_security`, `imap_username` | string, int, string, string | `imap_security`: `tls`, `starttls`, or `none` (development only). |
| `imap_password_set` | bool | Write with `imap_password`. |
| `imap_move_to` | string | IMAP folder to move handled mail to; `""` keeps it in `INBOX`. |
| `smtp_host`, `smtp_port`, `smtp_security`, `smtp_username`, `smtp_password_set` | | Empty `smtp_host` = the module-wide `SMTP_*` server. |
| `last_fetch_at`, `next_fetch_at` | time, optional | |
| `last_fetch_error` | string | `""` when the last fetch worked. Short and generic; details are in the log. |
| `fetch_failures` | int | Failures in a row; the wait doubles with each, up to an hour. |
| `provider_state`, `provider_error` | string | Google mailboxes: `active`, `suspended` or `error`, and the reason. |
| `deleted_at`, `purge_after` | time, optional | Set while the mailbox is in the trash. |
| `created_at` | time | |
| `roles` | array | The three roles: `key`, `group`, `level`. |

### `GET /api/v1/mailboxes`

Signed in. The mailboxes you can see (not in the trash), sorted by name,
with folder counts. Without any role the list is empty.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $DESK/api/v1/mailboxes
```

```json
{"mailboxes":[{
  "id":"c7e2a1d0-…","organization_id":"0f1a…","slug":"support","name":"Support",
  "email":"support@example.org","connector":"imap","signature":"-- {agent.name}, Support team",
  "auto_reply":{"enabled":true,"subject":"We got your message","body_html":"<p>We answer within a day.</p>","body_text":"We answer within a day."},
  "access":{"view":true,"work":true,"delete":false,"admin":false},
  "counts":{"unassigned":3,"mine":2,"assigned":5,"pending":4,"closed":120,"spam":1,"starred":1,"trash":0}}]}
```

### `POST /api/v1/mailboxes`

Admin. Creates a mailbox, for Google connectors also in Google, and asks
the fetcher to read it right away. Answers `201` with the full mailbox.

| Field | Required | Notes |
| --- | --- | --- |
| `name` | yes | |
| `email` | yes | Plain address. Google connectors: in `GOOGLE_WORKSPACE_DOMAIN`, not the shared account itself. |
| `connector` | no | `imap` (default), `google_user`, `google_group`. |
| `slug` | no | Lower-case letters, digits and dashes, 1 to 40 characters. Default: from the address (`lost.found@` → `lost-found`). |
| `organization_id` | if you are Desk admin in several organizations | |
| `signature`, `auto_reply` | no | |
| `imap_*`, `smtp_*`, `imap_password`, `smtp_password`, `imap_move_to` | `imap` only | See the mailbox object. |

```sh
curl -s -X POST $DESK/api/v1/mailboxes \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"Support","email":"support@example.org","connector":"imap",
       "signature":"-- {agent.name}, Support team",
       "imap_host":"imap.example.org","imap_port":993,"imap_security":"tls",
       "imap_username":"support@example.org","imap_password":"change-me"}'
```

```json
{"id":"c7e2a1d0-…","organization_id":"0f1a…","slug":"support","name":"Support","email":"support@example.org",
 "signature":"-- {agent.name}, Support team","imap_host":"imap.example.org","imap_port":993,
 "imap_security":"tls","imap_username":"support@example.org","imap_password_set":true,
 "smtp_host":"","smtp_port":587,"smtp_security":"starttls","smtp_username":"","smtp_password_set":false,
 "imap_move_to":"","last_fetch_error":"","fetch_failures":0,"connector":"imap","provider_state":"active",
 "provider_error":"","created_at":"2026-11-06T12:00:00Z",
 "auto_reply":{"enabled":false,"subject":"","body_html":"","body_text":""},
 "access":{"view":true,"work":true,"delete":true,"admin":true},
 "counts":{"unassigned":0,"mine":0,"assigned":0,"pending":0,"closed":0,"spam":0,"starred":0,"trash":0},
 "roles":[{"key":"desk_support_viewer","group":"desk-support-viewer","level":"viewer"},
          {"key":"desk_support_manager","group":"desk-support-manager","level":"manager"},
          {"key":"desk_support_delete","group":"desk-support-delete","level":"delete"}]}
```

A Google mailbox Google refused is still created, with `provider_state`
`error` and the reason in `provider_error`; fix the cause and call
[`provision`](#post-apiv1mailboxesmailboxprovision).

| Status | When |
| --- | --- |
| `201` | Created. |
| `403` | `only Desk admins may create mailboxes` (or not admin of `organization_id`). |
| `409` | `a mailbox with this email address already exists (also in Desk's trash)`. |
| `422` | `details` per field: `name: required`; `email: must be a plain email address` / `must be an address in example.org`; `slug: another mailbox already uses this slug` / `lower-case letters, digits and dashes, 1 to 40 characters`; `connector: Google Workspace is not configured (GOOGLE_WORKSPACE_DOMAIN)` / `group mailboxes need GOOGLE_SHARED_MAILBOX`; `imap_security: plaintext (none) is only allowed in development; use tls or starttls`; `organization_id: you are Desk admin in several organizations; choose one`; `auto_reply.body_html: required when the auto-reply is on`. |

### `GET /api/v1/mailboxes/trash`

Admin. Mailboxes in the trash of your organizations, soonest purge first,
with `deleted_at` and `purge_after`.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $DESK/api/v1/mailboxes/trash
```

```json
{"mailboxes":[{"id":"9a01…","slug":"press","name":"Press","email":"press@example.org","connector":"google_group",
  "provider_state":"suspended","deleted_at":"2026-11-02T10:00:00Z","purge_after":"2026-12-02T10:00:00Z","...":"..."}]}
```

### `GET /api/v1/mailboxes/{mailbox}`

Viewer. One mailbox with your folder counts: the summary, or the full
configuration for Desk admins.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $DESK/api/v1/mailboxes/c7e2a1d0-…
```

### `PATCH /api/v1/mailboxes/{mailbox}`

Changes only the fields you send. **Managers** may send only `signature`
and `auto_reply`; everything else is for Desk admins. `connector` and
`slug` cannot be changed.

Passwords: **leave the field out** to keep the stored one, send `""` to
clear it. Changing `imap_host` or `imap_username` needs `imap_password` in
the same request (likewise for SMTP), and makes Desk start again from the
first message of the new account. Answers `200` with the mailbox.

```sh
curl -s -X PATCH $DESK/api/v1/mailboxes/c7e2a1d0-… \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"auto_reply":{"enabled":true,"subject":"We got your message",
       "body_html":"<p>Thanks! We answer within a day.</p>"}}'
```

| Status | When |
| --- | --- |
| `403` | `managers may change the signature and the auto-reply; the rest is for Desk admins`, or you are only viewer. |
| `409` | Duplicate address. |
| `422` | As for create, plus `imap_password: enter the password again when the IMAP server or username changes` (or `smtp_password`), `connector: cannot be changed; create a new mailbox instead`, `slug: cannot be changed: it names the mailbox's roles and groups`, `auto_reply.subject: at most 200 characters`. |

### `DELETE /api/v1/mailboxes/{mailbox}`

Admin. Moves the mailbox to the **trash**: fetching and sending stop,
queued replies fail, a Google mailbox is suspended, and it is purged after
`mailbox_trash_days` (default 30) with reminders to Desk admins
([Operations](operations.md#the-trash)). Answers `200` with the mailbox
(`deleted_at`, `purge_after` set). `409` `the mailbox is already in the
trash`.

```sh
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" $DESK/api/v1/mailboxes/c7e2a1d0-…
```

### `POST /api/v1/mailboxes/{mailbox}/restore`

Admin. Takes the mailbox out of the trash (and unsuspends it in Google).
Answers `200` with the mailbox. `409` `the mailbox is not in the trash`, or
when another mailbox took the address meanwhile.

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" $DESK/api/v1/mailboxes/c7e2a1d0-…/restore
```

### `POST /api/v1/mailboxes/{mailbox}/purge`

Admin. Deletes a mailbox **in the trash** for good: in Google Workspace,
its files in S3, every conversation in Desk. **Cannot be undone.** Answers
`204`.

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" $DESK/api/v1/mailboxes/c7e2a1d0-…/purge
```

| Status | When |
| --- | --- |
| `409` | `only mailboxes in the trash can be purged; delete it first`, or `Google Workspace refused to delete the mailbox; it stays in the trash: …`. |

### `POST /api/v1/mailboxes/{mailbox}/provision`

Admin. Creates a Google mailbox in Google again, after an error. An
address that already exists there is taken over. Answers `200` with the
mailbox; read `provider_state` and `provider_error`.

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" $DESK/api/v1/mailboxes/9a01…/provision
```

```json
{"id":"9a01…","connector":"google_group","provider_state":"active","provider_error":"","...":"..."}
```

`400` `only Google Workspace mailboxes are provisioned`; `409` when Google
Workspace is not configured on this Desk.

### `POST /api/v1/mailboxes/{mailbox}/test`

Admin. For IMAP mailboxes: logs in over IMAP (and opens `INBOX`) and over
SMTP without changing anything. Always `200` when the mailbox exists: read
the booleans.

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" $DESK/api/v1/mailboxes/c7e2a1d0-…/test
```

```json
{"imap_ok":true,"smtp_ok":false,"smtp_error":"could not connect: the server did not answer in time","smtp_via":"smtp.example.org:587"}
```

`smtp_via` shows which server was tried: the mailbox's own or the
module-wide one. Errors are short and generic; the details are in the
backend log ([IMAP troubleshooting](imap.md#troubleshooting)).

### `POST /api/v1/mailboxes/{mailbox}/fetch`

Admin. Wakes the fetcher for this mailbox now instead of waiting. Answers
`202` `{"queued":true}`; the result shows up later in `last_fetch_at` and
`last_fetch_error`.

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" $DESK/api/v1/mailboxes/c7e2a1d0-…/fetch
```

### `GET /api/v1/mailboxes/{mailbox}/import-failures`

Admin. Messages Desk could not import (unreadable, or storing them failed)
and skipped, newest first.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $DESK/api/v1/mailboxes/c7e2a1d0-…/import-failures
```

```json
{"failures":[{"id":"e41c…","source":"imap:4711","subject":"Re: badge","from_email":"guest@example.com",
  "size_bytes":31873221,"error":"message too large","created_at":"2026-11-06T09:00:00Z"}]}
```

### `GET /api/v1/mailboxes/{mailbox}/saved-replies`

Viewer. The saved replies usable in this mailbox: its own and the global
ones (`mailbox_id` `null`), by name.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $DESK/api/v1/mailboxes/c7e2a1d0-…/saved-replies
```

```json
{"saved_replies":[{"id":"7b3e…","mailbox_id":"c7e2a1d0-…","name":"Badge pickup",
  "body_html":"<p>You can pick up your badge at the info desk.</p>","body_text":"You can pick up your badge at the info desk.",
  "updated_at":"2026-11-01T10:00:00Z"}]}
```

## Conversations

A **conversation** (ticket) is one email thread with one customer. It has a
per-mailbox `number` (shown as `#17`), a `status`, at most one assignee,
tags and a personal star.

| Status | Meaning |
| --- | --- |
| `active` | Needs an answer. |
| `pending` | Answered, waiting for the customer. A reply sets this by default. |
| `closed` | Done. `closed_at` is set. A customer reply reopens it. |
| `spam` | Hidden from every folder except Spam. |

### The conversation object

```json
{"id":"1d9b…","mailbox_id":"c7e2…","mailbox_name":"Support","number":17,
 "subject":"Lost badge","status":"active","preview":"Hi, I lost my badge on Saturday…",
 "customer":{"id":"55aa…","email":"guest@example.com","name":"Sam Guest","notes":""},
 "assignee_id":"5b1e…","assignee_name":"Alice Example","thread_count":2,
 "tags":["badge","saturday"],"starred":false,
 "last_activity_at":"2026-11-06T11:58:00Z","created_at":"2026-11-06T09:12:00Z"}
```

`assignee_id`, `assignee_name`, `closed_at` and `deleted_at` are left out
when empty. `thread_count` counts messages, replies and notes, not system
lines or deleted emails. `starred` is yours.

### `GET /api/v1/conversations`

Signed in. One page of conversations from every mailbox you can see,
newest activity first. Query parameters, all optional:

| Parameter | Values |
| --- | --- |
| `mailbox` | A mailbox id; leave out for every mailbox. `400` `invalid mailbox id`; `404` if you cannot see it. |
| `folder` | `unassigned` (default: active, nobody assigned), `mine` (active or pending, assigned to you), `assigned`, `pending`, `closed`, `spam`, `all` (everything except spam), `starred`, `trash` (only mailboxes where you have the delete role). Anything else: `400` `unknown folder: …`. |
| `q` | Full-text search in subject and messages, plus customer name and addresses. `#17` or `17` finds conversation number 17. |
| `tag` | Only conversations with this tag. |
| `limit` | 1 to 100, default 50. |
| `cursor` | `next_cursor` of the previous page. `400` `invalid cursor`. |

```sh
curl -s -H "Authorization: Bearer $TOKEN" \
  "$DESK/api/v1/conversations?mailbox=c7e2a1d0-…&folder=all&q=badge&limit=20"
```

```json
{"conversations":[{"id":"1d9b…","mailbox_id":"c7e2…","mailbox_name":"Support","number":17,
  "subject":"Lost badge","status":"active","preview":"Hi, I lost my badge on Saturday…",
  "customer":{"id":"55aa…","email":"guest@example.com","name":"Sam Guest","notes":""},
  "thread_count":1,"tags":[],"starred":false,
  "last_activity_at":"2026-11-06T11:58:00Z","created_at":"2026-11-06T09:12:00Z"}],
 "next_cursor":"MTc2MjQzMDI4MDAwMDAwMHwxZDli…"}
```

`next_cursor` is `""` on the last page.

### `POST /api/v1/conversations`

Manager of the mailbox. Starts a conversation from Desk (you write first).
The customer is found or created by address; the body is queued as the
first reply with the mailbox signature, exactly like
[a reply](#post-apiv1conversationsconversationthreads). Conversation and
reply are created together or not at all.

| Field | Required | Notes |
| --- | --- | --- |
| `mailbox_id` | yes | `404` if you cannot see it. |
| `customer_email` | yes | `Name <addr>` is accepted. |
| `customer_name` | no | Only fills an empty customer name. |
| `subject` | yes | |
| `body` or `body_html` | yes | Plain text, or HTML from the editor (sanitised; the plain text is derived). |
| `cc` | no | At most 20 addresses. |

Answers `201` with the conversation, status `pending`, assigned to you.

```sh
curl -s -X POST $DESK/api/v1/conversations \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"mailbox_id":"c7e2a1d0-…","customer_email":"guest@example.com","customer_name":"Sam Guest",
       "subject":"Your dealer table","body_html":"<p>Hi Sam, your table is confirmed for <b>hall B</b>.</p>"}'
```

```json
{"id":"4e01…","mailbox_id":"c7e2…","mailbox_name":"Support","number":18,"subject":"Your dealer table",
 "status":"pending","preview":"Hi Sam, your table is confirmed for hall B.",
 "customer":{"id":"55aa…","email":"guest@example.com","name":"Sam Guest","notes":""},
 "assignee_id":"5b1e…","assignee_name":"Alice Example","thread_count":1,"tags":[],"starred":false,
 "last_activity_at":"2026-11-06T12:05:00Z","created_at":"2026-11-06T12:05:00Z"}
```

`422` `invalid conversation` with `details` for `customer_email`, `subject`
or `body`; `cc: at most 20 addresses`.

### `GET /api/v1/conversations/{conversation}`

Viewer. The full conversation: the conversation object plus `threads`
(oldest first, at most the newest 500; `threads_truncated` says if more
exist), `history` (the customer's other conversations), `viewers` (others
seen on it in the last 30 seconds) and `access` (your rights in its
mailbox). A conversation in the trash is only visible with the delete role;
deleted emails are only included for that role, with `deleted_at` set.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $DESK/api/v1/conversations/1d9b…
```

```json
{
  "id":"1d9b…","mailbox_id":"c7e2…","mailbox_name":"Support","number":17,"subject":"Lost badge",
  "status":"pending","preview":"We found it - pick it up at the info desk.",
  "customer":{"id":"55aa…","email":"guest@example.com","name":"Sam Guest","notes":"VIP"},
  "assignee_id":"5b1e…","assignee_name":"Alice Example","thread_count":2,"tags":["badge"],"starred":true,
  "last_activity_at":"2026-11-06T12:01:00Z","created_at":"2026-11-06T09:12:00Z",
  "threads":[
    {"id":"a001…","kind":"customer","from_email":"guest@example.com","to":["support@example.org"],"cc":[],
     "body_html":"<p>Hi, I lost my badge on Saturday…</p>","body_text":"Hi, I lost my badge on Saturday…",
     "auto_submitted":false,
     "attachments":[{"id":"f9e8…","filename":"photo.jpg","content_type":"image/jpeg","size_bytes":183422,"inline":false}],
     "created_at":"2026-11-06T09:12:00Z"},
    {"id":"8c44…","kind":"reply","author_id":"5b1e…","author_name":"Alice Example",
     "from_email":"support@example.org","to":["guest@example.com"],"cc":[],
     "body_html":"<p>We found it - pick it up at the info desk.</p><br><br>-- Alice Example, Support team",
     "body_text":"We found it - pick it up at the info desk.\n\n-- Alice Example, Support team",
     "send_status":"sent","auto_submitted":false,"attachments":[],"created_at":"2026-11-06T12:01:00Z"}
  ],
  "threads_truncated":false,
  "history":[],
  "viewers":[{"user_id":"8d20…","display_name":"Bob Example","mode":"replying"}],
  "access":{"view":true,"work":true,"delete":false,"admin":false}
}
```

Thread fields:

| Field | Notes |
| --- | --- |
| `kind` | `customer` (incoming email), `reply` (email out), `note` (internal, never emailed), `forward` (sent to someone outside), `system` (status, assignee, merge and move lines). |
| `send_status` | Replies and forwards: `queued` (can be undone for 10 seconds), `sending`, `sent`, `failed`. |
| `send_error`, `next_attempt_at` | While retrying. Failed sends retry after 1, 5, 15 and 60 minutes, then stay `failed`. |
| `auto_submitted` | The customer message was automatic (out-of-office, list mail). |
| `attachments[]` | `id`, `filename`, `content_type`, `size_bytes`, `inline`, and `content_id` for inline images. Download with [`GET /api/v1/attachments/{attachment}`](#get-apiv1attachmentsattachment). |
| `deleted_at` | The email is in the trash (only shown with the delete role). |

### `PATCH /api/v1/conversations/{conversation}`

Manager. Change status, assignee, tags, or several. Status and assignee
changes add a `system` line; sending the current value changes nothing.

| Field | Values |
| --- | --- |
| `status` | `active`, `pending`, `closed`, `spam`. |
| `assignee_id` | A Desk user id who may work this mailbox; `""` to unassign; leave out to keep. |
| `tags` | The full list (replaces the old one): at most 20, each letters, digits, spaces, `-` and `_`, at most 32 characters; stored lower-case. |

```sh
curl -s -X PATCH $DESK/api/v1/conversations/1d9b… \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"assignee_id":"8d20…","status":"active","tags":["badge","saturday"]}'
```

Answers `200` with the conversation object (without threads).

| Status | When |
| --- | --- |
| `400` | `invalid assignee_id` (not a UUID). |
| `403` | `you need the manager role of this mailbox`. |
| `422` | `status: must be active, pending, closed or spam`; `assignee_id: not a Desk user` / `needs the manager role of this mailbox`; `tags: at most 20` / `"…": letters, digits, spaces, - and _, at most 32 characters`. |

### `DELETE /api/v1/conversations/{conversation}`

Delete role. Moves the conversation to the trash and, for Google mailboxes,
its messages to Gmail's trash. Queued replies in it are cancelled. Answers
`200` `{}`, or `{"warning":"…"}` when Google could not be reached (Desk's
trash still applies). `409` `already in the trash`.

```sh
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" $DESK/api/v1/conversations/1d9b…
```

```json
{}
```

### `POST /api/v1/conversations/{conversation}/restore`

Delete role. Takes it out of the trash (and out of Gmail's trash). Answers
`200` `{}` or `{"warning":"…"}`. `409` `the conversation is not in the trash`.

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" $DESK/api/v1/conversations/1d9b…/restore
```

### `POST /api/v1/conversations/{conversation}/threads`

Manager. Reply to the customer or add an internal note.

| Field | Required | Notes |
| --- | --- | --- |
| `kind` | yes | `reply` or `note`. |
| `body` or `body_html` | yes | Plain text, or HTML from the editor (sanitised; the plain text is derived). |
| `cc` | no | Replies only. Leave out for everyone in copy of the customer's last message, except the mailbox and the customer; `[]` for nobody. At most 20. |
| `status` | no | Replies only: status afterwards, default `pending`. |

A **reply** gets the mailbox signature and is sent as HTML with a
plain-text alternative **10 seconds later**, so
[undo](#post-apiv1threadsthreadundo) can take it back. Answering an
unassigned conversation assigns it to you. A **note** is only stored.
Answers `201` with the new thread id.

```sh
curl -s -X POST $DESK/api/v1/conversations/1d9b…/threads \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"kind":"reply","body_html":"<p>We found it - pick it up at the <b>info desk</b>.</p>","status":"closed"}'
```

```json
{"id":"8c44f0a2-…"}
```

| Status | When |
| --- | --- |
| `400` | `kind must be reply or note`. |
| `409` | `the conversation is in the trash; restore it first`. |
| `422` | `body: required`; `cc: … is not an email address` / `at most 20 addresses`; an invalid `status`. |

### `POST /api/v1/conversations/{conversation}/forward`

Manager. Forwards one message (with its attachments) to people outside the
conversation, from the mailbox address. The conversation's status does not
change.

| Field | Required | Notes |
| --- | --- | --- |
| `to` | yes | At most 20 addresses. |
| `thread_id` | no | The message to forward; default the customer's latest. |
| `body` or `body_html` | no | Your note above the forwarded message. |

```sh
curl -s -X POST $DESK/api/v1/conversations/1d9b…/forward \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"to":["security@example.org"],"body":"Can you check the lost and found box?"}'
```

```json
{"id":"b210…"}
```

`404` `message to forward not found`; `409` when the conversation is in
the trash; `422` `to: required`.

### `POST /api/v1/conversations/{conversation}/merge`

Manager of both mailboxes. Moves every message of this conversation into
`into_id` and removes this one. Answers `200` with the target conversation.

```sh
curl -s -X POST $DESK/api/v1/conversations/1d9b…/merge \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"into_id":"2a77…"}'
```

`400` `a conversation cannot be merged into itself` /
`conversations of different organizations cannot be merged`; `409`
`restore the conversation from the trash first`.

### `POST /api/v1/conversations/{conversation}/move`

Manager of both mailboxes. Moves the conversation to `mailbox_id` (same
organization). Answers `200` with the conversation.

```sh
curl -s -X POST $DESK/api/v1/conversations/1d9b…/move \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"mailbox_id":"d3c9…"}'
```

`400` `the conversation is already in this mailbox` /
`conversations can only move within one organization`; `409`
`the target mailbox is in the trash` /
`restore the conversation from the trash first`.

### `PUT /api/v1/conversations/{conversation}/star` and `DELETE …/star`

Viewer. Stars or unstars the conversation for you. Answers `204`.

```sh
curl -s -X PUT -H "Authorization: Bearer $TOKEN" $DESK/api/v1/conversations/1d9b…/star
```

### `POST /api/v1/conversations/{conversation}/viewing`

Viewer. Collision-detection heartbeat: tells Desk you are looking at or
typing in this conversation. The web app sends it repeatedly while the
conversation is open; others see you in `viewers` for 30 seconds after the
last one.

Body: `{"mode":"viewing"}` or `{"mode":"replying"}`. Answers `204`. `400`
`mode must be viewing or replying`.

```sh
curl -s -X POST $DESK/api/v1/conversations/1d9b…/viewing \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"mode":"replying"}'
```

## Threads (single emails)

### `POST /api/v1/threads/{thread}/undo`

The reply's author. Deletes a reply or forward that is still in its
10-second window. Answers `204`.

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" $DESK/api/v1/threads/8c44f0a2-…/undo
```

`403` `only the author can undo this reply`; `404` `thread not found`;
`409` `too late: the reply is already being sent`. Undoing does not revert
the status or assignee change the reply made.

### `POST /api/v1/threads/{thread}/retry`

The author, or a manager of the mailbox. Puts a `failed` reply back in the
queue for an immediate attempt. Answers `204`.

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" $DESK/api/v1/threads/8c44f0a2-…/retry
```

`403` `only the author or a manager of this mailbox can retry this reply`;
`409` `only failed replies can be retried`.

### `DELETE /api/v1/threads/{thread}`

Delete role. Moves one email (customer message, reply, note or forward) to
the trash, and for Google mailboxes the message to Gmail's trash. Answers
`200` `{}` or `{"warning":"…"}`.

```sh
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" $DESK/api/v1/threads/a001…
```

`400` `system lines cannot be deleted`; `409` `already in the trash` /
`this reply is still being sent; undo it instead`.

### `POST /api/v1/threads/{thread}/restore`

Delete role. Takes one email out of the trash. Answers `200` `{}` or
`{"warning":"…"}`. `409` `the email is not in the trash`.

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" $DESK/api/v1/threads/a001…/restore
```

## Customers

### `GET /api/v1/customers`

Signed in. Customers with a conversation in a mailbox you can see (Desk
admins: all of their organizations), whose name or an address contains
`q`. At most 20; `q` shorter than 2 characters returns an empty list.

```sh
curl -s -H "Authorization: Bearer $TOKEN" "$DESK/api/v1/customers?q=sam"
```

```json
{"customers":[{"id":"55aa…","email":"guest@example.com","name":"Sam Guest","notes":"VIP"}]}
```

### `GET /api/v1/customers/{customer}`

Viewer of one of the customer's conversations. The profile: every address,
their conversations in mailboxes you can see (newest 100), and whether you
may edit.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $DESK/api/v1/customers/55aa…
```

```json
{"id":"55aa…","email":"guest@example.com","name":"Sam Guest","notes":"VIP",
 "organization_id":"0f1a…","emails":["guest@example.com","sam@work.example"],
 "conversations":[{"id":"1d9b…","number":17,"subject":"Lost badge","status":"pending","...":"..."}],
 "created_at":"2026-10-01T08:00:00Z","can_edit":true}
```

### `PATCH /api/v1/customers/{customer}`

Manager of a mailbox the customer wrote to. Fields you leave out stay.
Answers `200` with the profile.

| Field | Notes |
| --- | --- |
| `name`, `notes` | |
| `add_email` | Another address the customer writes from. `409` if another customer has it: merge them instead. |
| `remove_email` | An extra address. The main address cannot be removed (`422`). |

```sh
curl -s -X PATCH $DESK/api/v1/customers/55aa… \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"notes":"VIP; prefers phone.","add_email":"sam@work.example"}'
```

### `POST /api/v1/customers/{customer}/merge`

Manager for both customers. Moves the addresses, conversations and notes of
`source_id` into this customer and deletes `source_id`. Answers `200` with
the merged profile.

```sh
curl -s -X POST $DESK/api/v1/customers/55aa…/merge \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"source_id":"6c01…"}'
```

`400` `a customer cannot be merged into itself` /
`customers of different organizations cannot be merged`.

## Attachments, people, tags

### `GET /api/v1/attachments/{attachment}`

Viewer of the conversation. Streams the file from S3. PNG, JPEG, GIF,
WebP, PDF and plain text are served `inline` with their type; everything
else as `application/octet-stream` download. Always with
`Content-Security-Policy: sandbox; default-src 'none'; …`,
`X-Content-Type-Options: nosniff` and `Cache-Control: private, no-store`,
so a hostile attachment cannot run in Desk's origin.

```sh
curl -s -OJ -H "Authorization: Bearer $TOKEN" $DESK/api/v1/attachments/f9e8…
```

`404` `attachment not found` (also when you cannot see the conversation),
`attachment content not found` when the file is missing in S3.

### `GET /api/v1/users`

The assignee picker. With `mailbox=<id>` (viewer of it): everyone who may
work that mailbox and has signed in. Without it (Desk admins only):
everyone. `q` filters by name or address.

```sh
curl -s -H "Authorization: Bearer $TOKEN" "$DESK/api/v1/users?mailbox=c7e2a1d0-…&q=bo"
```

```json
{"people":[{"id":"8d20…","display_name":"Bob Example","email":"bob@example.org"}]}
```

`400` `mailbox is required` (not admin) or `invalid mailbox id`.

### `GET /api/v1/tags`

Signed in. Tags in use, in `mailbox=<id>` or in every mailbox you can see, most used first (at most 200).

```sh
curl -s -H "Authorization: Bearer $TOKEN" "$DESK/api/v1/tags?mailbox=c7e2a1d0-…"
```

```json
{"tags":["badge","saturday","refund"]}
```

## Saved replies

A saved reply belongs to one mailbox (managed by its managers) or is
global (`mailbox_id` `null`, managed by Desk admins). List them with
[`GET /api/v1/mailboxes/{mailbox}/saved-replies`](#get-apiv1mailboxesmailboxsaved-replies).

### `POST /api/v1/saved-replies`

| Field | Required | Notes |
| --- | --- | --- |
| `mailbox_id` | no | `null` = global (Desk admins only). |
| `name` | yes | At most 120 characters. |
| `body_html` | yes | Sanitised. |
| `body_text` | no | Derived from the HTML when empty. |

```sh
curl -s -X POST $DESK/api/v1/saved-replies \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"mailbox_id":"c7e2a1d0-…","name":"Badge pickup","body_html":"<p>You can pick up your badge at the info desk.</p>"}'
```

```json
{"id":"7b3e…","mailbox_id":"c7e2a1d0-…","name":"Badge pickup",
 "body_html":"<p>You can pick up your badge at the info desk.</p>","body_text":"You can pick up your badge at the info desk.",
 "updated_at":"2026-11-06T12:00:00Z"}
```

`403` `only Desk admins manage saved replies for every mailbox`, or not
manager; `422` `name: required, at most 120 characters`, `body_html: required`.

### `PATCH /api/v1/saved-replies/{reply}`

Same rights. Same body as create; answers `200` with the saved reply.

```sh
curl -s -X PATCH $DESK/api/v1/saved-replies/7b3e… \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"mailbox_id":"c7e2a1d0-…","name":"Badge pickup","body_html":"<p>Badges: info desk, hall A.</p>"}'
```

### `DELETE /api/v1/saved-replies/{reply}`

Same rights. Answers `204`.

```sh
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" $DESK/api/v1/saved-replies/7b3e…
```

## Settings and audit (Desk admins)

### `GET /api/v1/settings/retention`

Admin. How long Desk keeps what ([Operations](operations.md#retention)):
`effective` (what the daily job uses), `desk` (Desk's own setting), `den`
(what Den's module settings send, when paired), `managed_by` (fields Den
controls) and `pending_legal_review` (periods still on "keep" by default).
`null` = keep.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $DESK/api/v1/settings/retention
```

```json
{"effective":{"closed_conversation_days":730,"attachment_days":null,"raw_mail_days":null,"trash_days":30,"mailbox_trash_days":30},
 "desk":{"closed_conversation_days":null,"attachment_days":null,"raw_mail_days":null,"trash_days":null,"mailbox_trash_days":null},
 "den":{"closed_conversation_days":730,"attachment_days":null,"raw_mail_days":null,"trash_days":null,"mailbox_trash_days":null},
 "managed_by":{"closed_conversation_days":"den"},
 "pending_legal_review":["attachment_days","raw_mail_days"]}
```

### `PUT /api/v1/settings/retention`

Admin. Replaces Desk's own setting (all five fields; `null` or left out =
keep). Each value 1 to 3650 days. Answers `200` with the same shape as
`GET`.

```sh
curl -s -X PUT $DESK/api/v1/settings/retention \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"closed_conversation_days":730,"attachment_days":365,"raw_mail_days":90,"trash_days":30,"mailbox_trash_days":30}'
```

`422` per field: `must be between 1 and 3650 days, or null to keep`, or
`set in Den (Modules → Desk → settings); change it there`.

### `GET /api/v1/settings/integrations`

Admin. The configured mail connectors and whether Desk can send its own
emails. `google` is `null` without Google Workspace.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $DESK/api/v1/settings/integrations
```

```json
{"google":{"domain":"example.org","shared_mailbox":"desk@example.org","label":"Desk",
  "shared_status":{"last_fetch_at":"2026-11-06T11:59:00Z","error":"","unrouted":0}},
 "notifications":true,"notify_from":"Desk <desk@example.org>","module_smtp":false}
```

### `GET /api/v1/audit`

Admin. The audit log, newest first.

| Parameter | Values |
| --- | --- |
| `action` | One of `mailbox.create`, `mailbox.update`, `mailbox.trash`, `mailbox.restore`, `mailbox.provision`, `mailbox.purge`, `mailbox.purge_reminder`, `conversation.delete`, `conversation.restore`, `conversation.forward`, `conversation.merge`, `conversation.move`, `thread.delete`, `thread.restore`, `customer.update`, `customer.merge`, `settings.retention`, `retention.purge`. |
| `mailbox` | A mailbox id. |
| `before` | An entry `id`: entries older than it (paging). |
| `limit` | 1 to 200, default 100. |

```sh
curl -s -H "Authorization: Bearer $TOKEN" "$DESK/api/v1/audit?action=mailbox.trash&limit=20"
```

```json
{"entries":[{"id":412,"actor_id":"5b1e…","actor_name":"Alice Example","action":"mailbox.trash",
  "mailbox_id":"9a01…","target_type":"mailbox","target_id":"9a01…","summary":"moved press@example.org to the trash",
  "details":{"email":"press@example.org","connector":"google_group","purge_days":30},"created_at":"2026-11-02T10:00:00Z"}]}
```

Entries by the daily job have no `actor_id`.

## Den pairing

Pairing connects Desk to Den for brand, settings, retention and shared
preferences ([Pairing](../../concepts/pairing.md)). All four routes need
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

Forgets the pairing; Desk falls back to its own brand file and retention
setting. Answers `204`.

```sh
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" $DESK/api/v1/den/pair
```

## Troubleshooting

| Symptom | Likely cause and fix |
| --- | --- |
| `401` `missing bearer token` | No `Authorization: Bearer` header; in `curl`, check `$TOKEN` is set. |
| `401` `invalid token` | Token expired (they last minutes), or issued by a different realm than `OIDC_ISSUER_URL`. Get a fresh one. |
| `404` for a mailbox or conversation that exists | You have no role for its mailbox. `GET /api/v1/me` lists what you can see; see [Access](access.md). |
| `403` `you need the manager role of this mailbox` | You are only viewer (or only delete). |
| `403` `only Desk admins may do this` | Mailbox setup, trash, retention and audit need `desk-admin`. |
| `400` `invalid JSON: json: unknown field "…"` | Desk rejects unknown fields. Check the field names in the tables above. |
| `last_fetch_error` set, no new conversations | IMAP: run `POST …/test`. Google: check `provider_error` and **Settings → Mail connectors**. |
| Replies stuck as `failed` | `send_error` on the thread says why; fix the mail server, then `POST /api/v1/threads/{id}/retry`. |
| `the stored password cannot be decrypted …` | `DESK_SECRET_KEY` changed without the old key in `DESK_SECRET_KEY_PREVIOUS`. See [Rotate DESK_SECRET_KEY](operations.md#rotate-desk_secret_key). |
| `409` on undo | More than 10 seconds passed; the reply is on its way. Send a follow-up instead. |
| `503` `den_pairing_required` | Pair Desk with Den, or run with `DEN_MODE=standalone`. |
