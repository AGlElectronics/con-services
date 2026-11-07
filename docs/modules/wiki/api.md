# Wiki API reference

Wiki's backend serves a JSON API over HTTP. The web app is built on it, and
you can use it from scripts too: to create a handbook space for a new team,
import pages, find pages that mention a topic, or publish a read-only link
for guests. This page documents **every endpoint** with who may call it,
what to send, what comes back and which errors to expect.

The route list is taken from the backend's router,
[`backend/internal/http/router.go`](https://github.com/AGlElectronics/wiki/blob/main/backend/internal/http/router.go),
and the handlers next to it. Conventions shared by every module (error
shape, request ids, time formats) are described once in
[API conventions](../../concepts/api-conventions.md); this page only repeats
what is specific to Wiki.

!!! note "One replica"
    Live editing state, websocket tickets and the share-link rate limiter
    live in the backend's memory, and the edit buffer is on its disk. The
    backend therefore always runs **exactly one replica**
    ([why](setup.md#why-the-backend-must-stay-at-one-replica)). Nothing in
    the API needs sticky sessions, because there is only ever one process.

## Basics

### Base address

| Where you call from | Base URL |
| --- | --- |
| A browser or script outside the cluster | `https://wiki.example.org` (the web app's nginx forwards `/api/` to the backend) |
| Another pod inside the cluster | `https://wiki-backend.conservices-wiki.svc.cluster.local:8080` |
| Docker Compose development | `http://localhost:<frontend port>` (see [Setup](setup.md#option-4-development-on-docker)) |

All examples below use these shell variables:

```sh
WIKI=https://wiki.example.org
TOKEN=...   # see "Getting a token" below
```

### Path layout

| Prefix | Who calls it | Authentication |
| --- | --- | --- |
| `/livez`, `/readyz` | Kubernetes probes | none |
| `/api/health`, `/api/role-catalog` | humans, HR | none |
| `/api/v1/brand…` | the login screen | none |
| `/api/v1/…` (everything else) | the web app, your scripts | user token |
| `/api/v1/pages/{page}/live` | the editor's websocket | one-time ticket in the URL |
| `/api/public/v1/shares/…` | anyone with a share link | the link token in the URL; rate limited |
| `/api/internal/…` | HR, server to server | `WIKI_SERVICE_TOKEN` |

### Authentication

- **Production (`AUTH_MODE=oidc`).** Send a Keycloak access token:
  `Authorization: Bearer <token>`. Wiki checks the signature, issuer and
  audience, creates the person on their first request, and reads their
  roles from the token's `groups` claim **on every request**. Removing
  someone from a group takes effect on their next call. See
  [Authentication](../../concepts/authentication.md).
- **Development only (`AUTH_MODE=dev`).** Send `X-Dev-User: alice` and,
  optionally, `X-Dev-Groups: wiki-admin,dept-crew`. Never enable this mode on
  a reachable server.

**Roles** (granted through Keycloak groups, configured in the
[access config file](configuration.md#access-config-file)):

| Role (default group) | Permissions | What it unlocks in the API |
| --- | --- | --- |
| `organization_admin` (`wiki-admin`) | `wiki.manage`, `space.create`, `settings.manage` | Full access to every team space (never to private spaces); create spaces; the `/api/v1/den` routes. |
| `space_creator` (`wiki-editor`) | `space.create` | `POST /api/v1/spaces`. |
| Everyone signed in | none | Their private space, and whatever is shared with them. |

**Access levels.** Apart from those permissions, every space and page
check is about the caller's **access level** on the object:
`view` < `comment` < `edit` < `full`. A level comes from the space's
"everyone" level, grants to the person or one of their groups, and grants
on the page or its ancestors (unless a page is *restricted*, which stops
inheritance). The strongest wins.

!!! important "404, not 403, for things you cannot see"
    If you cannot even **view** a space, page, file, thread, revision or
    share link, Wiki answers `404 not_found`, exactly as if it did not
    exist. You only get `403 forbidden` when you can see the object but
    your level is too low for the action ("needs edit access").

### Getting a token

For quick tests against the development Keycloak (the client must allow
the password grant; never do this in production):

```sh
TOKEN=$(curl -s https://auth.conservices.test/realms/conservices/protocol/openid-connect/token \
  -d grant_type=password -d client_id=wiki-spa \
  -d username=admin -d password=change-me | jq -r .access_token)
```

### Errors

Every error has the same body:

```json
{"error":{"code":"validation_failed","message":"invalid space","details":{"name":"required"}}}
```

| HTTP | `code` | When |
| --- | --- | --- |
| 400 | `bad_request` | Malformed JSON, an **unknown JSON field** (bodies are decoded strictly), an id that is not a UUID. |
| 401 | `unauthorized` | No token, an invalid or expired token, a used or expired live ticket, a wrong service token. |
| 403 | `forbidden` | You can see the object but your level or permission is too low. |
| 404 | `not_found` | It does not exist, **or you may not see it**. |
| 409 | `conflict` | The current state does not allow it (deleting a private space, a restore already running). |
| 422 | `validation_failed` | Field problems; `details` maps field to reason. |
| 429 | `too_many_requests` | Public share links only; wait (`Retry-After: 60`). |
| 503 | `unavailable` | Object storage is off (`S3_ENDPOINT` empty), or the server is restarting. |
| 500 | `internal` | Unexpected; quote the `X-Request-ID` response header when reporting it. |

Requests time out after 60 seconds (except the live websocket).

### Common objects

These shapes are returned by many endpoints; later sections refer to them.

**Space**

```json
{
  "id": "5d2e8c1a-3f4b-4c6d-9e7f-0a1b2c3d4e5f",
  "kind": "team",
  "name": "Crew handbook",
  "icon": "📘",
  "description": "Everything a new crew member needs.",
  "everyone_level": "view",
  "created_at": "2026-11-06T12:00:00Z",
  "access": "full",
  "orphaned_at": null,
  "grants": [
    {"principal_kind": "group", "principal": "dept-crew", "level": "edit", "display_name": "dept-crew"}
  ]
}
```

| Field | Notes |
| --- | --- |
| `kind` | `private` (one per person, created on first sign-in) or `team`. |
| `everyone_level` | Level every signed-in person gets; `null` = closed. |
| `access` | **Your** level on the space. |
| `orphaned_at` | Set when the owner of a private space was offboarded (see [Offboarding hook](#offboarding-hook-hr)). |

**Page** (the full form, from `GET /api/v1/pages/{page}` and most page writes)

```json
{
  "id": "9a41d2c7-6b8e-4f10-a2b3-c4d5e6f70812",
  "parent_id": null,
  "position": 1,
  "title": "Radio etiquette",
  "icon": "📻",
  "kind": "page",
  "restricted": false,
  "is_template": false,
  "access": "full",
  "space_id": "5d2e8c1a-3f4b-4c6d-9e7f-0a1b2c3d4e5f",
  "space_name": "Crew handbook",
  "space_kind": "team",
  "updated_at": "2026-11-06T12:01:00Z",
  "breadcrumbs": [],
  "grants": [],
  "can_trash": true
}
```

| Field | Notes |
| --- | --- |
| `kind` | `page` or `database` ([databases](#databases)). Never changes. |
| `position` | A float; siblings sort by it. |
| `restricted` | `true` = the page does not inherit access from its parent. |
| `breadcrumbs` | Visible ancestors, root first: `[{"id","title","icon"}]`. |
| `grants` | Grants set **on this page** (not inherited ones). |
| `can_trash` | Whether you may trash it (`full`, or `edit` on a page you created). |

A **page node** (in trees and database rows) is the first nine fields
(`id` to `access`) only.

---

## Health and discovery

### `GET /livez`, `GET /readyz`, `GET /api/health`

Who may call: anyone. `/livez` answers `{"status":"ok"}` while the process
runs. `/readyz` answers `200 {"status":"ok","database":"ok"}` when
PostgreSQL answers, otherwise `503` with `"database":"down"`. `/api/health`
is the human-friendly version:

```sh
curl -s $WIKI/api/health
```

```json
{"status":"ok","database":"ok","version":"1.2.0-1","uptime_sec":5231}
```

### `GET /api/role-catalog`

Who may call: anyone. HR reads it to offer Wiki roles when onboarding
someone. Lists each role with its permissions and the group that grants it.

```sh
curl -s $WIKI/api/role-catalog
```

```json
{
  "module": "wiki",
  "display_name": "Wiki",
  "description": "Pages, team spaces and shared knowledge.",
  "roles": [
    {"key": "organization_admin", "label": "Organization Admin",
     "description": "Full access to every team space and page, and the module settings.",
     "group": "wiki-admin", "assignable": true, "scope": "organization:demo-org",
     "permissions": ["settings.manage", "space.create", "wiki.manage"]},
    {"key": "space_creator", "label": "Space Creator",
     "description": "Creates new team spaces.",
     "group": "wiki-editor", "assignable": true, "scope": "organization:demo-org",
     "permissions": ["space.create"]}
  ]
}
```

Only roles bound to a group in the access config appear. Reading and
editing pages is not a role; it comes from grants inside Wiki.

### `GET /api/v1/brand`, `GET /api/v1/brand/{role}`

Who may call: anyone (the login screen needs it before sign-in). `/brand`
returns the active brand: Den's colours, logo and copy once paired
(`"source": "den"`), otherwise `"source": "standalone"`. `/brand/{role}`
streams a brand asset copied from Den (`logo`, `login-background`);
`404` when there is none. See [Pairing](../../concepts/pairing.md).

---

## You, people and groups

### `GET /api/v1/me`

Who may call: signed in. Your identity and effective permissions; the web
app uses it to decide which buttons to show (the server still checks every
call).

```sh
curl -s $WIKI/api/v1/me -H "Authorization: Bearer $TOKEN"
```

```json
{
  "id": "0f3c9a52-1d2e-4b7a-8c6d-5e4f3a2b1c0d",
  "display_name": "Alice Example",
  "email": "alice@example.org",
  "issuer": "https://auth.example.org/realms/conservices",
  "subject": "6f1d2a7e-1c8b-4f0e-9d55-8c1b2f9a0e11",
  "memberships": [{"organization_id": "a1b2c3d4-0000-4000-8000-000000000001", "role": "space_creator"}],
  "permissions": ["space.create"]
}
```

### `GET /api/v1/me/preferences`, `PUT /api/v1/me/preferences`

Who may call: signed in. Your theme, shared across modules through Den.
Body for `PUT`: `{"theme": "system" | "light" | "dark"}`; anything else is
`422`. When Wiki is not paired with Den the value is echoed back and kept in
the browser only.

```sh
curl -s -X PUT $WIKI/api/v1/me/preferences -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"theme":"dark"}'
```

```json
{"theme":"dark"}
```

### `GET /api/v1/users`

Who may call: signed in. The people picker of the share dialog: people who
have signed in to Wiki at least once, at most 50, sorted by name.

| Query | Meaning |
| --- | --- |
| `q` | Filter by name or email (substring, case-insensitive). |
| `ids` | Comma-separated user ids to look up (at most 100), for showing comment authors. Takes precedence over `q`. |

```sh
curl -s "$WIKI/api/v1/users?q=ali" -H "Authorization: Bearer $TOKEN"
```

```json
{"people":[{"id":"0f3c9a52-1d2e-4b7a-8c6d-5e4f3a2b1c0d","display_name":"Alice Example","email":"alice@example.org"}]}
```

Errors: `400` when an `ids` entry is not a UUID.

### `GET /api/v1/groups`

Who may call: signed in. The group picker: every Keycloak group name Wiki
has seen in someone's token, sorted, as
`{"groups": ["dept-crew", "wiki-editor", ...]}`.

---

## Spaces

### `GET /api/v1/spaces`

Who may call: signed in. Your spaces, pages shared with you from spaces you
cannot otherwise see, and whether you may create team spaces.

```sh
curl -s $WIKI/api/v1/spaces -H "Authorization: Bearer $TOKEN"
```

```json
{
  "spaces": [
    {"id": "0b7c5f6e-6f1a-4a43-9a8e-2b1d7f1c9a10", "kind": "private", "name": "Alice's space",
     "icon": "", "description": "", "everyone_level": null, "created_at": "2026-11-02T09:14:03Z",
     "access": "full", "orphaned_at": null, "grants": []}
  ],
  "shared": [
    {"id": "77aa…", "parent_id": null, "position": 3, "title": "Budget 2027", "icon": "💶",
     "kind": "page", "restricted": true, "is_template": false, "access": "comment",
     "space_id": "c0ffee00-…", "space_name": "Finance"}
  ],
  "can_create": true
}
```

### `POST /api/v1/spaces`

Who may call: `space.create` (Editor or Admin). Creates a **team** space;
you get `full` access on it.

| Field | Type | Required | Rules |
| --- | --- | --- | --- |
| `name` | string | yes | 1–120 characters. |
| `icon` | string | no | One emoji or short text, at most 32 bytes. |
| `description` | string | no | |
| `everyone_level` | string | no | `view`, `comment`, `edit`, `full`, or `""`/omitted for a closed space. |

```sh
curl -s -X POST $WIKI/api/v1/spaces -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"Crew handbook","icon":"📘","everyone_level":"view"}'
```

Response `201`: a [Space](#common-objects).

| Status | When |
| --- | --- |
| `403` | Missing `space.create` (`"missing permission: space.create"`). |
| `422` | `details.name`, `details.icon` or `details.everyone_level`. |

### `GET /api/v1/spaces/{space}`

Who may call: `view` on the space. Returns a Space. `404` below `view`.

### `PATCH /api/v1/spaces/{space}`

Who may call: `full` on the space. Same fields as create, all optional;
only the fields you send change. Sending `"everyone_level": ""` closes the
space. A **private** space keeps its name and stays private: sending `name`
or `everyone_level` for one is `422`.

```sh
curl -s -X PATCH $WIKI/api/v1/spaces/5d2e8c1a-3f4b-4c6d-9e7f-0a1b2c3d4e5f \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"description":"Read this before your first shift."}'
```

Response `200`: the Space. Errors: `403` below `full`, `404`, `422`.

### `DELETE /api/v1/spaces/{space}`

Who may call: `full` on the space. Deletes the space, every page in it and
their stored content and files. Answers `204`.

A private space can only be deleted **after** its owner was offboarded
(`orphaned_at` set); before that the answer is `409 "a private space cannot
be deleted"`.

### `PUT /api/v1/spaces/{space}/grants`

Who may call: `full` on the space. Adds, changes or removes **one** grant.

| Field | Rules |
| --- | --- |
| `principal_kind` | `user` or `group`. |
| `principal` | For `user`: a person's id (from `GET /api/v1/users`), who must exist. For `group`: a Keycloak group name, 1–200 characters. |
| `level` | `view`, `comment`, `edit`, `full`; `""` **removes** the grant. |

```sh
curl -s -X PUT $WIKI/api/v1/spaces/5d2e8c1a-3f4b-4c6d-9e7f-0a1b2c3d4e5f/grants \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"principal_kind":"group","principal":"dept-front-of-house","level":"edit"}'
```

Response `200`: the updated Space. Removing your own access is allowed; the
response then shows your new (lower) `access`. Group grants follow the
token's `groups` claim, so removing someone from the group in Keycloak
revokes access on their next request.

Errors: `422` for a bad field, an unknown person, or a **private** space
("share single pages from a private space, not the whole space").

### `GET /api/v1/spaces/{space}/pages`

Who may call: `view` on the space, or on at least one page in it. The page
**tree**: every live page you can view, in tree order, as page nodes. A
page under a restricted page you cannot see is re-parented onto its nearest
visible ancestor, so the tree never has holes.

```sh
curl -s $WIKI/api/v1/spaces/5d2e8c1a-3f4b-4c6d-9e7f-0a1b2c3d4e5f/pages -H "Authorization: Bearer $TOKEN"
```

```json
{"pages":[
  {"id":"9a41d2c7-…","parent_id":null,"position":1,"title":"Radio etiquette","icon":"📻","kind":"page","restricted":false,"is_template":false,"access":"full"},
  {"id":"3b7e…","parent_id":"9a41d2c7-…","position":1,"title":"Call signs","icon":"","kind":"page","restricted":false,"is_template":false,"access":"full"}
]}
```

### `GET /api/v1/spaces/{space}/trash`

Who may call: `view` on the space. Trashed pages **you could restore**
(`full`, or `edit` on pages you created):
`{"pages":[{"id","title","icon","deleted_at"}]}`.

---

## Pages

### `POST /api/v1/spaces/{space}/pages`

Who may call: `edit` on the space root, or on the parent page. Creates a
page at the end of its parent. The page **body is not part of this call**;
it is written through [live editing](#live-editing).

| Field | Rules |
| --- | --- |
| `parent_id` | Optional page id in the same space; omitted = space root. |
| `title` | At most 300 characters; may be empty ("Untitled"). |
| `icon` | At most 32 bytes. |
| `is_template` | `true` marks it as a template ([templates](#templates-and-duplicating)). |
| `kind` | `page` (default) or `database`. A database gets a default "Table" view. |

```sh
curl -s -X POST $WIKI/api/v1/spaces/5d2e8c1a-3f4b-4c6d-9e7f-0a1b2c3d4e5f/pages \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"title":"Radio etiquette","icon":"📻"}'
```

Response `201`: a [Page](#common-objects).

| Status | When |
| --- | --- |
| `403` | Your level at the destination is below `edit`. |
| `404` | Space or parent page not visible (`"parent page not found"`). |
| `422` | `title` too long, `icon` too long, `kind` not `page`/`database`. |

### `GET /api/v1/pages/{page}`

Who may call: `view`. Returns a Page. Trashed pages are `404`.

### `PATCH /api/v1/pages/{page}`

Who may call: `edit`. Changes `title`, `icon` and/or `is_template`.
Sending `parent_id` is `422` ("use the move endpoint"); sending `kind` is
`422` ("a page never changes kind").

```sh
curl -s -X PATCH $WIKI/api/v1/pages/9a41d2c7-6b8e-4f10-a2b3-c4d5e6f70812 \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"title":"Radio etiquette (2026)"}'
```

Response `200`: the Page.

### `POST /api/v1/pages/{page}/move`

Who may call: `edit` on the page **and** on the destination. Moves a page
(with everything under it) within its space.

| Field | Meaning |
| --- | --- |
| `parent_id` | New parent page id; `null` or omitted = space root. |
| `position` | New float position among the new siblings; omitted = at the end. To drop between two siblings, send the midpoint of their positions. |

```sh
curl -s -X POST $WIKI/api/v1/pages/3b7e…/move -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"parent_id":null,"position":1.5}'
```

Response `200`: the Page. Errors: `422` when the parent is in another space
or under the page itself; `403`/`404` as usual.

### `POST /api/v1/pages/{page}/trash`

Who may call: `full`, or `edit` on a page you created. Moves the page and
its subtree to the space's trash. Answers `204`. Open editors of those
pages are disconnected (websocket close code `4404`).

### `POST /api/v1/pages/{page}/restore`

Who may call: same as trash. Takes a page out of the trash. If its parent
is still in the trash, it comes back at the space root. Response `200`: the
Page. `404 "trashed page not found"` if it is not in the trash.

### `DELETE /api/v1/pages/{page}`

Who may call: `full`. Deletes a **trashed** page and everything under it
forever, including stored content, revisions and uploads. Answers `204`.
A page that is not in the trash is `404`; trash it first.

### `PUT /api/v1/pages/{page}/grants`

Who may call: `full` on the page. Same body as
[space grants](#put-apiv1spacesspacegrants); works on pages in private
spaces too (that is how you share one page from your private space).
Response `200`: the Page. If you removed your own access, the response is
the page with `"access": "none"`.

### `PUT /api/v1/pages/{page}/restricted`

Who may call: `full`. Body `{"restricted": true}` stops the page inheriting
access from its parent and space; only grants on the page (and admins)
apply. If restricting would lock **you** out, Wiki first gives you a `full`
grant on the page. `{"restricted": false}` restores inheritance. Response
`200`: the Page.

### `GET /api/v1/pages/{page}/backlinks`

Who may call: `view`. Pages that link to this one (via `@page` mentions or
links), newest first, filtered to the ones you can view, at most 20:

```json
{"hits":[{"id":"…","space_id":"…","space_name":"Crew handbook","title":"Onboarding checklist","icon":"✅","snippet":""}]}
```

---

## Live editing

Page **content** is not a JSON field. It is a [Yjs](https://yjs.dev)
document edited by several browsers at once over a websocket, relayed and
stored by the backend without decoding it. The protocol is Wiki's own small
framing, **not** y-websocket, so standard Yjs providers cannot connect. The
full design (frame types, compaction, snapshots) is in
[ADR 0001](https://github.com/AGlElectronics/wiki/blob/main/docs/adr/0001-yjs-relay-in-go.md).
All of this needs object storage; without it these endpoints answer `503`.

### `POST /api/v1/pages/{page}/live-ticket`

Who may call: `view`. Issues a **one-time ticket**, valid for 30 seconds,
for opening the websocket, plus your level (which decides whether your
edits are accepted).

```sh
curl -s -X POST $WIKI/api/v1/pages/9a41d2c7-6b8e-4f10-a2b3-c4d5e6f70812/live-ticket \
  -H "Authorization: Bearer $TOKEN"
```

```json
{"ticket":"q3Vx9mT2kLr8ZpN4wYc7bHf1sJd6aGe0uKo5iMtRvXE","level":"edit"}
```

Tickets are kept in the backend's memory (single replica) and are consumed
on use.

### `GET /api/v1/pages/{page}/live?ticket=…` (websocket)

Who may call: whoever holds a fresh ticket for **this** page. This is a
websocket upgrade, not a JSON call; the `Origin` header must be one of
`CORS_ALLOWED_ORIGINS`. No `Authorization` header is needed (browsers
cannot set one on websockets); the ticket authenticates.

| Before upgrade | Status |
| --- | --- |
| Ticket missing, used, expired or for another page | `401` |
| Page gone or access lost since the ticket | `404` |
| A revision restore is running, or the server is shutting down | `503` |

**Frames** (summary; see ADR 0001 for the byte layout):

| Frame | Direction | Content |
| --- | --- | --- |
| binary `1` | both | One Yjs update. |
| binary `2` | to browser, on join | Stored snapshot plus every later update. |
| binary `3` | both | Awareness (cursors, who is here); relayed, never stored. |
| binary `5` | to server | A snapshot the server asked for (with plain text and links for search and backlinks). |
| text `synced` | to browser | After the batch; carries your level and the last sequence number. |
| text `access` | to browser | Your level changed while connected. |
| text `compact` | to browser | Please send a snapshot up to sequence N. |
| text `error` | to browser | For example a `view`-only person's edit was refused. |
| text `refresh` | to server | A new ticket, every minute, so group changes apply. |

**Close codes** the client must handle:

| Code | Meaning | What the client does |
| --- | --- | --- |
| `4401` | Session expired. | Get a new ticket and reconnect. |
| `4404` | Page deleted or trashed, or access removed. | Stop; show "page not available". |
| `4409` | A revision was restored. | **Drop the local document** and reconnect fresh; re-syncing the old copy would undo the restore. |
| `1012` | Server restarting. | Reconnect after a short wait. |

---

## Files

Uploads are stored in the bucket under the page and only served through the
backend after the page access check. Without object storage these answer
`503 "uploads need object storage (S3_ENDPOINT)"`.

### `POST /api/v1/pages/{page}/files`

Who may call: `edit`. Multipart upload with one part named `file`. Limits:
**25 MB** for `image/*`, **50 MB** for anything else. The filename is
cleaned (path removed, at most 200 characters).

```sh
curl -s -X POST $WIKI/api/v1/pages/9a41d2c7-6b8e-4f10-a2b3-c4d5e6f70812/files \
  -H "Authorization: Bearer $TOKEN" -F "file=@channel-plan.pdf;type=application/pdf"
```

Response `201`:

```json
{
  "id": "e4f5a6b7-c8d9-4e0f-a1b2-c3d4e5f6a7b8",
  "page_id": "9a41d2c7-6b8e-4f10-a2b3-c4d5e6f70812",
  "filename": "channel-plan.pdf",
  "content_type": "application/pdf",
  "size_bytes": 184233,
  "created_at": "2026-11-06T12:10:00Z",
  "url": "/api/v1/files/e4f5a6b7-c8d9-4e0f-a1b2-c3d4e5f6a7b8"
}
```

The upload only stores the file; the editor then inserts a block pointing
at `url`. Errors: `400` (no `file` part), `403` (below `edit`), `422`
(`details.file` is `"empty"` or `"at most 25 MB"`/`"at most 50 MB"`).

### `GET /api/v1/files/{file}`

Who may call: `view` on the file's page. Streams the bytes. Images are sent
`inline` (so `<img>` works), everything else as `attachment`, with
`X-Content-Type-Options: nosniff` and `Cache-Control: private, max-age=3600`.
`404` when the file does not exist or you cannot see its page.

```sh
curl -s -OJ $WIKI/api/v1/files/e4f5a6b7-c8d9-4e0f-a1b2-c3d4e5f6a7b8 -H "Authorization: Bearer $TOKEN"
```

---

## History (revisions)

Wiki keeps a revision of a page's document at most every 10 minutes of
editing, plus one whenever a restore replaces the current state.

### `GET /api/v1/pages/{page}/revisions`

Who may call: `view`. Newest first.

```json
{"revisions":[
  {"id":"5c6d7e8f-…","page_id":"9a41d2c7-…","size_bytes":20481,"reason":"auto","created_at":"2026-11-06T11:40:00Z"},
  {"id":"1a2b3c4d-…","page_id":"9a41d2c7-…","size_bytes":19876,"reason":"restore","created_at":"2026-11-05T18:02:00Z"}
]}
```

`reason` is `auto` (periodic), `restore` (the state a restore replaced) or
`manual`.

### `GET /api/v1/revisions/{revision}`

Who may call: `view` on its page. Returns the revision's raw Yjs document
(`Content-Type: application/octet-stream`, cached for a day because
revisions never change). The web app renders it read-only. `404` when you
cannot see the page; `503` without object storage.

### `POST /api/v1/revisions/{revision}/restore`

Who may call: `edit` on its page. Makes the revision the page's current
document. The state being replaced is kept first as a `restore` revision.
Every open editor of the page is disconnected with close code **`4409`**
and must reload the document from scratch.

```sh
curl -s -X POST $WIKI/api/v1/revisions/5c6d7e8f-0a1b-4c2d-8e3f-4a5b6c7d8e9f/restore \
  -H "Authorization: Bearer $TOKEN"
```

Response `200`: the Page.

| Status | When |
| --- | --- |
| `403` | Below `edit`. |
| `404` | Unknown revision, or page not visible. |
| `409` | Another restore of the same page is running. |
| `503` | No object storage. |

---

## Search and favourites

### `GET /api/v1/search?q=…`

Who may call: signed in. Searches page titles (substring) and body text
(full-text, words), returning at most 20 pages **you can view**. Title
matches rank first. `snippet` is a highlighted fragment of body text, or
`""` for title-only matches. An empty `q` or one longer than 200 characters
returns no hits.

```sh
curl -s "$WIKI/api/v1/search?q=radio" -H "Authorization: Bearer $TOKEN"
```

```json
{"hits":[{"id":"9a41d2c7-…","space_id":"5d2e8c1a-…","space_name":"Crew handbook","title":"Radio etiquette","icon":"📻","snippet":"…always say your call sign on the <b>radio</b> before…"}]}
```

Body text is indexed when a page is compacted, so a just-typed sentence may
take up to about 30 seconds of quiet to become searchable.

### `GET /api/v1/me/favorites`

Who may call: signed in. Your favourites you can still see, in your order:
`{"favorites":[{"id","space_id","space_name","title","icon","snippet"}]}`.

### `PUT /api/v1/me/favorites/{page}`, `DELETE /api/v1/me/favorites/{page}`

Who may call: `view` on the page. Add or remove a favourite. Both answer
`204` and are safe to repeat.

---

## Comments

Comments live in **threads** attached to a page (usually anchored to a
text selection; the anchor is opaque `metadata` owned by the editor).
Comment `body` is opaque JSON too (the editor's rich-text format), at most
64 KB.

### `GET /api/v1/pages/{page}/threads`

Who may call: `view`. Threads oldest first, each with its comments and
reactions.

```json
{"threads":[{
  "id":"7d8e9f00-…","page_id":"9a41d2c7-…","resolved":false,"resolved_by":null,"resolved_at":null,
  "metadata":{"anchor":"block-3f2a"},
  "created_at":"2026-11-06T12:20:00Z","updated_at":"2026-11-06T12:25:00Z",
  "comments":[
    {"id":"c1…","user_id":"0f3c9a52-…","body":[{"type":"paragraph","content":"Should this mention channel 4?"}],
     "metadata":null,"reactions":[{"emoji":"👍","created_at":"2026-11-06T12:22:00Z","user_ids":["5b1e…"]}],
     "created_at":"2026-11-06T12:20:00Z","updated_at":"2026-11-06T12:20:00Z","deleted_at":null}
  ]
}]}
```

A deleted comment keeps its place with `"body": null` and `deleted_at` set.
Look up author names with `GET /api/v1/users?ids=…`.

### `POST /api/v1/pages/{page}/threads`

Who may call: `comment`. Starts a thread with its first comment.

```sh
curl -s -X POST $WIKI/api/v1/pages/9a41d2c7-6b8e-4f10-a2b3-c4d5e6f70812/threads \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"body":[{"type":"paragraph","content":"Should this mention channel 4?"}],"metadata":{"anchor":"block-3f2a"}}'
```

Response `201`: the Thread. Errors: `403` below `comment`; `422`
`details.body = "required"` when `body` is missing, `null` or over 64 KB.

### Thread and comment actions

| Method and path | Who | Body | Response |
| --- | --- | --- | --- |
| `POST /api/v1/threads/{thread}/comments` | `comment` | `{"body": …}` | `201` Thread |
| `POST /api/v1/threads/{thread}/resolve` | `comment` | none | `200` Thread |
| `POST /api/v1/threads/{thread}/unresolve` | `comment` | none | `200` Thread |
| `DELETE /api/v1/threads/{thread}` | `edit` | none | `204` |
| `PATCH /api/v1/comments/{comment}` | the author | `{"body": …}` | `200` Thread |
| `DELETE /api/v1/comments/{comment}` | the author, or `edit` | none | `200` Thread |
| `POST /api/v1/comments/{comment}/reactions` | `comment` | `{"emoji":"👍"}` | `200` Thread |
| `DELETE /api/v1/comments/{comment}/reactions` | `comment` | `{"emoji":"👍"}` | `200` Thread |

Pattern:

```sh
curl -s -X POST $WIKI/api/v1/threads/7d8e9f00-…/resolve -H "Authorization: Bearer $TOKEN"
```

Errors: `403 "only the author may edit a comment"`, `403 "needs edit
access, or being the author"`, `404` for an unknown or deleted comment,
`422 details.emoji = "one emoji"` (empty or over 32 bytes). Adding the same
reaction twice is a no-op.

---

## Templates and duplicating

A **template** is any page with `is_template: true`. "New page from
template" and plain "Duplicate" are the same call.

### `POST /api/v1/pages/{page}/duplicate`

Who may call: `view` on the source **and** `edit` at the destination.
Copies the page and its live, visible subtree into the same space. Copies
are never templates and carry no grants or restriction. Content is copied
byte for byte when object storage is on; without it the copies are empty.

| Field | Meaning |
| --- | --- |
| `parent_id` | Where the copy goes; omitted or `null` = space root. |
| `title` | Title of the root copy, at most 300 characters. Default: `"<source> (copy)"`, or the template's own title. |

```sh
curl -s -X POST $WIKI/api/v1/pages/aa11bb22-…/duplicate -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"parent_id":null,"title":"Meeting notes 2026-11-06"}'
```

```json
{"page":{"id":"dd44…","parent_id":null,"position":7,"title":"Meeting notes 2026-11-06","kind":"page","is_template":false,"access":"full","space_id":"5d2e8c1a-…","…":"…"}}
```

If some content could not be copied the response is still `201`, with
`"warning": "some page content could not be copied"`. Uploads are **not**
copied: file blocks in the copy point at the source's files.

Errors: `403` below `edit` at the destination; `422` "a page cannot be
copied under itself" or a title over 300 characters.

---

## Databases

A **database** is a page with `kind: "database"`; its **rows** are its
direct child pages, and its **properties** are typed columns. **Views**
(table, board, calendar) save a filter, sort and grouping. Design:
[ADR 0002](https://github.com/AGlElectronics/wiki/blob/main/docs/adr/0002-databases-as-pages.md).
Every call below answers `422 "not a database page"` when the page is not a
database. Create one with `POST /api/v1/spaces/{space}/pages` and
`"kind": "database"`; add a row by creating a child page.

### `GET /api/v1/pages/{page}/database`

Who may call: `view`. Columns and views.

```json
{
  "properties": [
    {"id":"p1…","database_id":"db…","name":"Status","type":"select","options":{"choices":["Open","Done"]},"position":1},
    {"id":"p2…","database_id":"db…","name":"Due","type":"date","options":null,"position":2}
  ],
  "views": [
    {"id":"v1…","database_id":"db…","name":"Table","kind":"table","config":{},"position":1}
  ]
}
```

Property `type` is one of `text`, `number`, `select`, `multi_select`,
`date`, `person`, `checkbox`, `url`. `options` is free JSON for the editor
(at most 16 KB), for example the choices of a select.

### `GET /api/v1/pages/{page}/rows[?view=<view id>]`

Who may call: `view`. Rows you can view, each a page node plus `values`
keyed by property id. With `view`, that view's filter and sort are applied
server-side; without it, rows come in tree order.

```json
{"rows":[
  {"id":"r1…","parent_id":"db…","position":1,"title":"Order radios","icon":"","kind":"page","restricted":false,"is_template":false,"access":"edit",
   "values":{"p1…":"Open","p2…":"2026-11-20"}}
]}
```

Errors: `400` when `view` is not a UUID; `404` when the view does not belong
to this database.

### `PUT /api/v1/pages/{page}/values`

Who may call: `edit` on the **row** (`{page}` is the row page). Sets some
property values; `null` removes one.

| Property type | Value |
| --- | --- |
| `text`, `url`, `date`, `select` | JSON string (`date` as `YYYY-MM-DD`). |
| `person` | A user id string. |
| `number` | JSON number. |
| `checkbox` | `true` / `false`. |
| `multi_select` | Array of strings. |

```sh
curl -s -X PUT $WIKI/api/v1/pages/r1…/values -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"values":{"p1…":"Done","p2…":null}}'
```

Response `200`: the row. Errors: `404` unknown property; `422` "not a
database row", "the property belongs to another database", or
`details.<property name>` such as `"a number"`.

### Properties and views

| Method and path | Who | Body | Response |
| --- | --- | --- | --- |
| `POST /api/v1/pages/{page}/properties` | `edit` | `name` (1–120, required), `type` (required), `options` | `201` Property |
| `PATCH /api/v1/properties/{property}` | `edit` | `name`, `options`, `position` | `200` Property |
| `DELETE /api/v1/properties/{property}` | `edit` | none | `204`; removes every value in that column |
| `POST /api/v1/pages/{page}/views` | `edit` | `name` (required), `kind` (`table`, `board`, `calendar`; required), `config` | `201` View |
| `PATCH /api/v1/views/{view}` | `edit` | `name`, `config`, `position` | `200` View |
| `DELETE /api/v1/views/{view}` | `edit` | none | `204` |

A property never changes `type` and a view never changes `kind` (`422`).
A view's `config` has this shape (all parts optional):

```json
{
  "filter": [{"property": "p1…", "equals": "Open"}],
  "sort": [{"property": "p2…", "desc": false}],
  "group_by": "p1…",
  "date_property": "p2…"
}
```

`filter` keeps rows where every condition matches (for `multi_select`, the
array contains the value). `group_by` drives board columns and
`date_property` the calendar.

```sh
curl -s -X POST $WIKI/api/v1/pages/db…/views -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"By status","kind":"board","config":{"group_by":"p1…"}}'
```

---

## Share links

A **share link** gives anyone with the URL read-only access to one page
(optionally with its sub-pages), without an account. Links only work when
the organisation allows it: Den's `wiki_public_links` setting once paired,
otherwise `PUBLIC_LINKS_ENABLED` ([Configuration](configuration.md)).

### Managing links (signed in, `full` on the page)

| Method and path | Body | Response |
| --- | --- | --- |
| `GET /api/v1/pages/{page}/share-links` | none | `200 {"links":[ShareLink…]}`, newest first |
| `POST /api/v1/pages/{page}/share-links` | `include_children` (bool), `expires_in_days` (0 = never, at most 3650) | `201 {"link": ShareLink, "token": "wsl_…"}` |
| `DELETE /api/v1/share-links/{link}` | none | `204`; revoked for good |

```sh
curl -s -X POST $WIKI/api/v1/pages/9a41d2c7-6b8e-4f10-a2b3-c4d5e6f70812/share-links \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"include_children":true,"expires_in_days":30}'
```

```json
{
  "link": {"id":"5e6f…","page_id":"9a41d2c7-…","include_children":true,"created_at":"2026-11-06T12:30:00Z",
           "expires_at":"2026-12-06T12:30:00Z","revoked_at":null,"last_used_at":null},
  "token": "wsl_mY3x2QeVd1b7nR0kTq4sWc9uZf6aHj8LpG5oNiBvXyE"
}
```

!!! warning "The token is shown once"
    Wiki stores only a SHA-256 hash of the token. Copy it from this response;
    it cannot be shown again. The web app builds the public URL from it.

Errors: `403` below `full`; `422 details.expires_in_days`.

### Public access (no account): `/api/public/v1/shares/{token}`

Who may call: anyone with the token. Rate limited per client IP to about
**120 requests a minute** with bursts of 30 (`429`, `Retry-After: 60`).
Responses carry `X-Robots-Tag: noindex, nofollow`.

Every path answers the **same `404`** when share links are switched off,
the token is unknown, revoked or expired, or the page is in the trash, so a
response never confirms that anything exists.

| Method and path | Returns |
| --- | --- |
| `GET /api/public/v1/shares/{token}` | `{"page": {id, parent_id, title, icon}, "pages": [...]}`: the root page and, with `include_children`, its live subtree. |
| `GET /api/public/v1/shares/{token}/pages/{page}/doc` | `{"updates": ["<base64>", ...]}`: the page's Yjs document as updates the browser merges. `Cache-Control: no-store`. `404` for a page outside the link. |
| `GET /api/public/v1/shares/{token}/files/{file}` | The file's bytes, when its page is inside the link. |

```sh
curl -s $WIKI/api/public/v1/shares/wsl_mY3x2QeVd1b7nR0kTq4sWc9uZf6aHj8LpG5oNiBvXyE
```

```json
{"page":{"id":"9a41d2c7-…","parent_id":null,"title":"Radio etiquette","icon":"📻"},
 "pages":[{"id":"3b7e…","parent_id":"9a41d2c7-…","title":"Call signs","icon":""}]}
```

---

## Offboarding hook (HR)

### `POST /api/internal/offboarded`

Who may call: **HR, server to server**, after it deletes someone's
account. Authenticated with `Authorization: Bearer <WIKI_SERVICE_TOKEN>`
(compared in constant time), not a user token. The whole route answers
`404` while `WIKI_SERVICE_TOKEN` is empty, so it is off by default. The
token is a secret; see [Secrets](../../operations/secrets.md).

| Field | Required | Meaning |
| --- | --- | --- |
| `subject` | yes | The person's identity-provider subject (Keycloak user id). |
| `username` | no | For the log line only. |

The person's private space is marked orphaned and handed to the Wiki
admins, who can export it; it is deleted automatically after
`WIKI_OFFBOARD_GRACE_DAYS` (default 30). The call is **idempotent**: a
repeat, or a subject Wiki never saw, also answers `204`.

```sh
curl -s --cacert /etc/conservices-internal-ca/ca.crt -o /dev/null -w '%{http_code}\n' -X POST \
  https://wiki-backend.conservices-wiki.svc.cluster.local:8080/api/internal/offboarded \
  -H "Authorization: Bearer change-me" -H "Content-Type: application/json" \
  -d '{"subject":"6f1d2a7e-1c8b-4f0e-9d55-8c1b2f9a0e11","username":"bob"}'
```

```text
204
```

| Status | When |
| --- | --- |
| `204` | Done, or nothing to do. |
| `400` | Malformed JSON or an unknown field. |
| `401` | Missing or wrong token. |
| `404` | `WIKI_SERVICE_TOKEN` is empty on Wiki: the endpoint is off. |
| `422` | `details.subject = "required"`. |

A NetworkPolicy only lets HR's pods reach this path; see
[Network policies](../../operations/network-policies.md).

---

## Den connection

Who may call: `settings.manage` (Admin). The same pairing API as every
module; see [Pairing](../../concepts/pairing.md).

| Method and path | Result |
| --- | --- |
| `GET /api/v1/den` | Status: `{"paired": true, "den_base_url", "module_id", "paired_at", "synced_at"}`, or `{"paired": false}`. |
| `POST /api/v1/den/pair` | Body `{"pairing_url": "<from Den>"}`. `422 pairing_failed` with the reason (expired token, Den unreachable). |
| `POST /api/v1/den/sync` | Fetch Den's brand and settings now. `409` when not paired, `502` when Den fails. |
| `DELETE /api/v1/den/pair` | Unpair, `204`. Wiki falls back to its own settings. |

```sh
curl -s -X POST $WIKI/api/v1/den/pair -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"pairing_url":"https://den.example.org/api/v1/integrations/pairing/redeem?token=change-me"}'
```

---

## All endpoints at a glance

71 routes. "Level" means your access level on the page or space in the path.

| Method | Path | Who |
| --- | --- | --- |
| GET | `/livez`, `/readyz`, `/api/health` | anyone |
| GET | `/api/role-catalog` | anyone |
| GET | `/api/v1/brand`, `/api/v1/brand/{role}` | anyone |
| POST | `/api/internal/offboarded` | `WIKI_SERVICE_TOKEN` |
| GET | `/api/public/v1/shares/{token}` | share token |
| GET | `/api/public/v1/shares/{token}/pages/{page}/doc` | share token |
| GET | `/api/public/v1/shares/{token}/files/{file}` | share token |
| GET | `/api/v1/pages/{page}/live?ticket=` | live ticket (websocket) |
| GET | `/api/v1/me` | signed in |
| GET, PUT | `/api/v1/me/preferences` | signed in |
| GET | `/api/v1/users`, `/api/v1/groups` | signed in |
| GET | `/api/v1/me/favorites` | signed in |
| PUT, DELETE | `/api/v1/me/favorites/{page}` | `view` |
| GET | `/api/v1/search` | signed in |
| GET | `/api/v1/spaces` | signed in |
| POST | `/api/v1/spaces` | `space.create` |
| GET | `/api/v1/spaces/{space}` | `view` |
| PATCH, DELETE | `/api/v1/spaces/{space}` | `full` |
| PUT | `/api/v1/spaces/{space}/grants` | `full` |
| GET | `/api/v1/spaces/{space}/pages`, `/trash` | `view` |
| POST | `/api/v1/spaces/{space}/pages` | `edit` at the destination |
| GET | `/api/v1/pages/{page}` | `view` |
| PATCH | `/api/v1/pages/{page}` | `edit` |
| POST | `/api/v1/pages/{page}/move` | `edit` on page and destination |
| POST | `/api/v1/pages/{page}/trash`, `/restore` | `full`, or `edit` on your own page |
| DELETE | `/api/v1/pages/{page}` | `full` (trashed pages only) |
| PUT | `/api/v1/pages/{page}/grants`, `/restricted` | `full` |
| POST | `/api/v1/pages/{page}/live-ticket` | `view` |
| POST | `/api/v1/pages/{page}/files` | `edit` |
| GET | `/api/v1/files/{file}` | `view` on its page |
| GET | `/api/v1/pages/{page}/revisions` | `view` |
| GET | `/api/v1/revisions/{revision}` | `view` |
| POST | `/api/v1/revisions/{revision}/restore` | `edit` |
| GET | `/api/v1/pages/{page}/backlinks` | `view` |
| POST | `/api/v1/pages/{page}/duplicate` | `view` on source, `edit` at destination |
| GET | `/api/v1/pages/{page}/threads` | `view` |
| POST | `/api/v1/pages/{page}/threads` | `comment` |
| POST | `/api/v1/threads/{thread}/comments`, `/resolve`, `/unresolve` | `comment` |
| DELETE | `/api/v1/threads/{thread}` | `edit` |
| PATCH | `/api/v1/comments/{comment}` | author |
| DELETE | `/api/v1/comments/{comment}` | author, or `edit` |
| POST, DELETE | `/api/v1/comments/{comment}/reactions` | `comment` |
| GET | `/api/v1/pages/{page}/database`, `/rows` | `view` |
| PUT | `/api/v1/pages/{page}/values` | `edit` on the row |
| POST | `/api/v1/pages/{page}/properties`, `/views` | `edit` |
| PATCH, DELETE | `/api/v1/properties/{property}`, `/api/v1/views/{view}` | `edit` |
| GET, POST | `/api/v1/pages/{page}/share-links` | `full` |
| DELETE | `/api/v1/share-links/{link}` | `full` |
| GET | `/api/v1/den` | `settings.manage` |
| POST | `/api/v1/den/pair`, `/api/v1/den/sync` | `settings.manage` |
| DELETE | `/api/v1/den/pair` | `settings.manage` |

## Troubleshooting

**Every call returns `404`, even for a page I can open in the browser.**
Check the token belongs to the same person: `GET /api/v1/me`. Wiki answers
`404` for anything you cannot view, so a token for another user (or a dev
header in production) looks like "not found".

**`400 invalid JSON: json: unknown field "…"`.** Request bodies are decoded
strictly. Remove fields the endpoint does not list (for example `parent_id`
on `PATCH /pages/{page}`; use `/move`).

**`503 unavailable` on live editing, files, revisions or duplicate.**
`S3_ENDPOINT` is empty, so object storage is off. Page content lives only in
the bucket; configure it ([Configuration](configuration.md)).

**The websocket closes immediately with `401`.** The ticket was used,
older than 30 seconds, or issued for another page. Request a fresh
`live-ticket` right before connecting, once per connection.

**A share link answers `404`.** In order: is `wiki_public_links` on in Den
(or `PUBLIC_LINKS_ENABLED=true` when standalone)? Was the link revoked or
did it expire (`GET /share-links`)? Is the page in the trash?

**`POST /api/internal/offboarded` answers `404`.** `WIKI_SERVICE_TOKEN` is
not set on Wiki. Set the same value in Wiki and HR
([Secrets](../../operations/secrets.md)).
