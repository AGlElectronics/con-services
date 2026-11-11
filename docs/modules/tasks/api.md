# Tasks API reference

Tasks' backend serves a JSON API over HTTP. The web app is built on it,
and you can use it from scripts too: to create the task list for a new
convention day, import tasks from a spreadsheet, move everything that is
overdue into a "Handoffs" list, or show "my open tasks" on a kiosk. This
page documents **every endpoint** with who may call it, what to send, what
comes back and which errors to expect.

The route list is taken from the backend's router,
[`backend/internal/http/router.go`](https://github.com/AGlElectronics/tasks/blob/main/backend/internal/http/router.go),
and the handlers next to it (`tasks.go`, `features.go`, `planning.go`,
`admin.go`, `stream.go`, `internal_api.go`).
Conventions shared by every module (error shape, request ids, time formats)
are described once in [API conventions](../../concepts/api-conventions.md);
this page only repeats what is specific to Tasks.

## Basics

### Base address

| Where you call from | Base URL |
| --- | --- |
| A browser or script outside the cluster | `https://tasks.example.org` (the web app's nginx forwards `/api/` to the backend) |
| Another pod inside the cluster | `https://tasks-backend.conservices-tasks.svc.cluster.local:8080` |

All examples below use these shell variables:

```sh
TASKS=https://tasks.example.org
TOKEN=...   # see "Getting a token" below
```

### Words used on this page

| Term | Meaning |
| --- | --- |
| **Space** | A team's area, with its own **key** (`CREW`), statuses, folders, lists and sharing. |
| **Folder** | Groups lists inside a space. Optional. |
| **List** | Holds tasks. The web app shows a list as a table or as a **board** (columns = statuses). |
| **Status** | A board column, with a category: `not_started`, `active` or `done`. |
| **Task key** | `<space key>-<number>`, for example `CREW-42`. |
| **Level** | Your access: `view` < `edit` < `manage`. |

### Authentication

- **Production (`AUTH_MODE=oidc`).** Send a Keycloak access token:
  `Authorization: Bearer <token>`. Tasks creates the person on their first
  request and reads their roles from the token's `groups` claim **on every
  request**. See [Authentication](../../concepts/authentication.md).
- **Development only (`AUTH_MODE=dev`).** Send `X-Dev-User: alice` and
  optionally `X-Dev-Groups: tasks-admin`. Never on a reachable server.

**Roles** (granted through Keycloak groups; see
[Configuration](configuration.md)):

| Role (default group) | Permissions | What it unlocks |
| --- | --- | --- |
| `organization_admin` (`tasks-admin`) | `space.manage`, `space.create`, `settings.manage` | `manage` on every space; the `/api/v1/den` routes; people's emails in the picker. |
| `space_creator` (`tasks-creator`) | `space.create` | Create spaces; `manage` on the spaces **they created**. |
| Everyone signed in | none | Whatever is shared with them. |

**Access levels.** Your level on a space, list or task is the strongest of:

1. `manage` from `space.manage`, or from `space.create` on a space you created;
2. the space's `everyone_level` (`null` = closed space);
3. a space grant to you or one of your groups;
4. a **list** grant (sharing one list without the whole space);
5. being **assigned** to a task gives `edit` on that one task;
6. **watching** a task gives `view` on that one task.

A **private list** is hidden from people whose access comes only from the
space (below `manage`); they need a direct list grant.

!!! important "404, not 403, for things you cannot see"
    Below `view`, spaces, lists, tasks, comments and attachments answer
    `404 not_found`, exactly as if they did not exist. You get
    `403 forbidden` only when you can see the object but your level is too
    low.

### Task ids and keys

Wherever a path says `{task}`, send either the task's UUID **or** its key,
case-insensitive: `/api/v1/tasks/CREW-42` and `/api/v1/tasks/crew-42` both
work. Keys keep resolving after the space key is renamed or the task moves
to another space.

### Limits

| Limit | Value |
| --- | --- |
| Rate limit | About 20 requests a second per person, bursts of 100. Above: `429`, `Retry-After: 1`. Applies to `/api/v1/*` after sign-in. |
| Request body | 1 MB; attachment uploads 25 MB plus 1 MB of form overhead; imports 11 MB (a 5 MB file, JSON-escaped). |
| Request time | 60 seconds, except the live-update stream (`GET /api/v1/stream`), which stays open up to 30 minutes. |
| Live-update streams | 5 open streams per person; the 6th is `429`. |
| Task title / description / comment | 500 / 100,000 / 20,000 characters. |
| Tag name | 50 characters. |
| Custom fields | 50 per space, 100 options per select field, 5,000 characters per text value. |
| Dependencies | 50 per task. |
| Time entry | 1 to 1,440 minutes (one day). |
| Calendar | At most 120 days and 2,000 tasks per request. |
| Import | 5 MB and 2,000 tasks per file. |
| Sidebar | `GET /api/v1/spaces` returns at most 1,000 spaces (`"truncated": true` when there are more). |
| Task detail | The newest 100 comments and 200 activity entries; page through the rest with `…/comments` and `…/events`. |

### Paging

`GET /api/v1/lists/{list}/tasks`, `GET /api/v1/my-work`,
`GET /api/v1/tasks/{task}/comments`, `GET /api/v1/tasks/{task}/events` and
`GET /api/v1/audit` return at most `limit` rows (default 200, max 500). When there are more, the response has
an **`X-Next-Cursor`** header; send it back as `?cursor=` to get the next
page. The body shape never changes, so a client that ignores paging still
works on small lists.

```sh
curl -s -D - "$TASKS/api/v1/lists/8e2f0c1d-…/tasks?limit=2" -H "Authorization: Bearer $TOKEN" -o page1.json
# ... X-Next-Cursor: eyJwIjoyLCJuIjo0Mn0
curl -s "$TASKS/api/v1/lists/8e2f0c1d-…/tasks?limit=2&cursor=eyJwIjoyLCJuIjo0Mn0" -H "Authorization: Bearer $TOKEN"
```

### Getting a token

For quick tests against the development Keycloak (password grant must be
allowed for the client; never in production):

```sh
TOKEN=$(curl -s https://auth.conservices.test/realms/conservices/protocol/openid-connect/token \
  -d grant_type=password -d client_id=tasks-spa \
  -d username=admin -d password=change-me | jq -r .access_token)
```

### Errors

```json
{"error":{"code":"validation_failed","message":"invalid task","details":{"title":"required"}}}
```

| HTTP | `code` | When |
| --- | --- | --- |
| 400 | `bad_request` | Malformed JSON, an **unknown JSON field** (bodies are decoded strictly), an id that is not a UUID, a bad cursor. |
| 401 | `unauthorized` | No token, an invalid or expired one, or a wrong service token. |
| 403 | `forbidden` | You can see it, but your level or role is too low. |
| 404 | `not_found` | It does not exist, **or you may not see it**. |
| 409 | `conflict` | Stale `version`, a duplicate space key, tag or field name, deleting a space's last list, a test email without SMTP. |
| 413 | | Body over the size limit. |
| 422 | `validation_failed` | Field problems; `details` maps field to reason. |
| 429 | `rate_limited` | Rate limit, or more than 5 live-update streams. |
| 503 | `unavailable` | Attachments without object storage (`S3_ENDPOINT` unset), live updates off, the mail server refused a test email. |
| 500 | `internal` | Unexpected; quote the `X-Request-ID` response header. |

### Common objects

**Space** (as returned by space endpoints, with your capabilities added)

```json
{
  "id": "3c1b2a90-5d4e-4f3a-8b2c-1d0e9f8a7b6c",
  "name": "Crew",
  "key": "CREW",
  "color": "#3b82f6",
  "description": "Stage crew tasks for the weekend.",
  "created_by": "5b1e7c2d-…",
  "created_at": "2026-11-01T10:00:00Z",
  "everyone_level": null,
  "archived": false,
  "department_id": null,
  "lists": [
    {"id": "8e2f0c1d-…", "space_id": "3c1b2a90-…", "folder_id": null, "name": "General",
     "description": "", "position": 1, "private": false, "archived": false,
     "open_tasks": 4, "done_tasks": 9}
  ],
  "folders": [{"id": "f1…", "space_id": "3c1b2a90-…", "name": "Load-in", "position": 1}],
  "statuses": [
    {"id": "a1…", "name": "To do", "color": "#9ca3af", "category": "not_started", "position": 0},
    {"id": "a2…", "name": "In progress", "color": "#3b82f6", "category": "active", "position": 1},
    {"id": "a3…", "name": "Review", "color": "#a855f7", "category": "active", "position": 2},
    {"id": "a4…", "name": "Done", "color": "#22c55e", "category": "done", "position": 3}
  ],
  "my_level": "edit",
  "can_edit": true,
  "can_manage": false
}
```

`shared_only: true` appears when you have no access to the space itself
and only see lists shared with you directly. `archived` spaces are hidden
from the sidebar and search; `department_id` is the HR department a space
belongs to (set by the [department hook](#department-hook-hr)).

**Task**

```json
{
  "id": "f04d6e2a-…", "key": "CREW-43", "number": 43,
  "space_id": "3c1b2a90-…", "list_id": "8e2f0c1d-…", "list_name": "General",
  "parent_id": null, "parent_key": null, "parent_title": null,
  "title": "Print badges", "description": "",
  "status": {"id": "a1…", "name": "To do", "color": "#9ca3af", "category": "not_started"},
  "priority": "high", "start_at": null, "due_at": "2026-11-20",
  "position": 12, "completed_at": null, "version": 1,
  "created_at": "2026-11-06T12:00:00Z", "updated_at": "2026-11-06T12:00:00Z",
  "created_by": "5b1e7c2d-…",
  "assignees": [{"id": "0f3c…", "display_name": "Alice Example"}],
  "tags": [{"id": "t1…", "name": "printing", "color": "#f59e0b"}],
  "subtask_count": 0, "subtask_done": 0, "comment_count": 0,
  "checklist_total": 0, "checklist_done": 0,
  "fields": {"c7d1…": 1250.5, "c7d2…": "o1…"},
  "recurrence": {"freq": "weekly", "interval": 1},
  "blocked_by_open": 1,
  "estimate_minutes": 120, "time_spent_minutes": 45
}
```

| Field | Notes |
| --- | --- |
| `priority` | `urgent`, `high`, `normal`, `low`, or `null`. |
| `start_at`, `due_at` | Dates, `YYYY-MM-DD`, or `null`. |
| `version` | Increases on every change. Send it back on `PATCH` (see [version check](#patch-apiv1taskstask)). |
| `completed_at` | Set while the task is in a `done` status. |
| `fields` | [Custom field](#custom-fields) id → value: a string (text, URL, `YYYY-MM-DD` date, or the id of a select option), a number or a boolean. Unset fields are left out. |
| `recurrence` | `null`, or how the task [repeats](#recurring-tasks). |
| `blocked_by_open` | How many unfinished tasks this one [waits for](#dependencies). |
| `estimate_minutes`, `time_spent_minutes` | Planned effort (or `null`) and the [logged time](#time-tracking). |

---

## Health and discovery

| Method and path | Who | Response |
| --- | --- | --- |
| `GET /livez` | anyone | `{"status":"ok"}` while the process runs. |
| `GET /readyz` | anyone | `200 {"status":"ok","database":"ok"}`, or `503` with `"database":"down"`. |
| `GET /api/health` | anyone | `{"status":"ok","database":"ok","version":"1.0.0-1","uptime_sec":5231}` |
| `GET /api/role-catalog` | anyone | Roles HR can grant, with their groups and permissions. |
| `GET /api/v1/brand`, `GET /api/v1/brand/{role}` | anyone | Brand from Den once paired (`"source":"den"`), else `"standalone"`; `{role}` streams a logo or login background. |

```sh
curl -s $TASKS/api/role-catalog
```

```json
{
  "module": "tasks", "display_name": "Tasks",
  "roles": [
    {"key": "organization_admin", "label": "Organization Admin",
     "description": "Manages every space, its lists and statuses, and the module settings.",
     "group": "tasks-admin", "assignable": true, "scope": "organization:demo-org",
     "permissions": ["settings.manage", "space.create", "space.manage"]},
    {"key": "space_creator", "label": "Space Creator",
     "description": "Creates new spaces and manages the spaces they created.",
     "group": "tasks-creator", "assignable": true, "scope": "organization:demo-org",
     "permissions": ["space.create"]}
  ]
}
```

---

## You and people

### `GET /api/v1/me`

Who may call: signed in.

```json
{
  "id": "0f3c9a52-1d2e-4b7a-8c6d-5e4f3a2b1c0d", "display_name": "Alice Example",
  "email": "alice@example.org", "issuer": "https://auth.example.org/realms/conservices",
  "subject": "6f1d2a7e-…",
  "memberships": [{"organization_id": "a1b2…", "role": "space_creator"}],
  "permissions": ["space.create"]
}
```

### `GET /api/v1/me/preferences`, `PUT /api/v1/me/preferences`

Who may call: signed in. Theme shared across modules through Den:
`{"theme": "system" | "light" | "dark"}`; anything else is `422`.

### `GET /api/v1/users?q=&limit=`

Who may call: signed in. People picker, sorted by name, default 50 (max
200). `q` filters by name. **Emails are only included for callers who hold
`space.manage` in the organization**; everyone else gets names only.

### `GET /api/v1/me/notifications`, `PUT /api/v1/me/notifications`

Who may call: signed in. Which [Inbox](#inbox-notifications) notifications
also come **by email**. Defaults: email on, for `assigned`, `mention` and
`due_soon`.

| Field | Rules |
| --- | --- |
| `email` | `true` or `false`: email at all. |
| `email_kinds` | Any of `assigned`, `mention`, `comment`, `status`, `due_soon`, `automation`. |
| `has_address` | Response only: `false` when the sign-in token carried no email address (then nothing is emailed). |

```sh
curl -s -X PUT $TASKS/api/v1/me/notifications -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"email":true,"email_kinds":["assigned","mention","due_soon","comment"]}'
```

```json
{"email":true,"email_kinds":["assigned","mention","due_soon","comment"],"has_address":true}
```

Errors: `422 details.email_kinds = "unknown kind …"`.

How email works: a notification waits **two minutes**, so a burst of
changes arrives as one email (up to 20 notifications each) and anything you
read in the app meanwhile is not emailed. Notifications older than a day
are never emailed. Failed sends are retried twice. Email needs an SMTP
server, from Den or from Tasks' `SMTP_*` settings (see
[Configuration](configuration.md#email)).

```json
{"users":[{"id":"0f3c9a52-…","display_name":"Alice Example"}]}
```

### `GET /api/v1/my-work`

Who may call: signed in. Your open tasks plus the ones you finished in the
last 7 days, soonest due first, as `{"tasks": [Task…]}`. Paged (see
[Paging](#paging)).

```sh
curl -s $TASKS/api/v1/my-work -H "Authorization: Bearer $TOKEN"
```

### `GET /api/v1/search?q=&limit=`

Who may call: signed in. Searches task titles (substring) and keys
(prefix) across everything you can see. An **exact key match is pinned to
the top**, then open tasks before done ones, newest first. Default 20
results, max 50.

```sh
curl -s "$TASKS/api/v1/search?q=crew-4" -H "Authorization: Bearer $TOKEN"
```

```json
{"results":[{"id":"f04d6e2a-…","key":"CREW-43","title":"Print badges","list_name":"General","space_name":"Crew","status":"To do","done":false}]}
```

### `GET /api/v1/calendar?from=&to=&mine=1`

Who may call: signed in. Every task you can see (same rules as search;
archived spaces left out) whose start-to-due span overlaps `from`–`to`
(both `YYYY-MM-DD`, required, at most 120 days apart). A task with only
one of the two dates counts on that day. `mine=1` keeps only tasks
assigned to you. At most 2,000 tasks, soonest first; `"truncated": true`
when there were more.

```sh
curl -s "$TASKS/api/v1/calendar?from=2026-11-01&to=2026-11-30" -H "Authorization: Bearer $TOKEN"
```

```json
{"tasks":[{"id":"f04d6e2a-…","key":"CREW-43","title":"Print badges","start_at":null,"due_at":"2026-11-20","…":"all Task fields"}],"truncated":false}
```

Errors: `422 details.from`/`details.to` (missing, not a date, `to` before
`from`, or more than 120 days).

### Live updates: `GET /api/v1/stream`

Who may call: signed in. A [Server-Sent Events](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events)
stream that says **what changed** — never the content — so the client can
refetch it through the normal API. You only hear about lists and spaces you
can see.

```sh
curl -sN $TASKS/api/v1/stream -H "Authorization: Bearer $TOKEN"
```

```text
retry: 5000
event: ready
data: {}

event: change
data: {"type":"list","list_id":"8e2f0c1d-…","space_id":"3c1b2a90-…"}

: ping

event: change
data: {"type":"inbox"}
```

| `type` | Means | Refetch |
| --- | --- | --- |
| `list` | A task in that list, or something on it (comment, checklist, assignee, tag, field value, dependency, time, attachment), changed. | The list's tasks, open task pages, My Work, the sidebar counts. |
| `space` | The space, its lists, statuses, folders, tags, fields, automations or sharing changed. Also sent when you just lost access. | The sidebar and the space. |
| `inbox` | Your notifications changed. | The Inbox and its badge. |
| `resync` | Changes may have been missed (the server fell behind or lost its database connection). | Everything. |

A `: ping` comment arrives every 25 seconds. The server ends the stream
after 30 minutes; reconnect (with a fresh token). `EventSource` cannot send
an `Authorization` header, so browsers read the stream with `fetch`.
`GET /api/v1/stream/status` answers `{"enabled": true}` when live updates
are available.

| Status | When |
| --- | --- |
| `429` | You already have 5 streams open (`Retry-After: 30`). |
| `503` | Live updates are not available on this server. |

### Favourites

Pin spaces or lists to the sidebar. Personal: nobody else sees them.

| Method and path | Body | Response |
| --- | --- | --- |
| `GET /api/v1/favorites` | none | `{"favorites":[{"space_id"} or {"list_id"}…]}` |
| `PUT /api/v1/favorites` | `{"space_id": "…"}` **or** `{"list_id": "…"}` | `204` |
| `POST /api/v1/favorites/remove` | same | `204` |

Adding needs `view` on the target (otherwise `404`, so favourites cannot
probe for hidden spaces). Removing never checks access, so you can always
unpin something you lost access to. Sending neither or both ids is `422
"pick a space or a list"`.

---

## Inbox (notifications)

Watchers and assignees get a notification when a task's status changes or
someone comments; mentioned people get one for the mention; a newly
assigned person gets one. You are never notified about your own actions.
Notifications are written in the same transaction as the change.

### `GET /api/v1/inbox?unread=1&limit=`

Who may call: signed in. Newest first; `unread=1` for unread only; default
200, max 500.

```json
{"notifications":[{
  "id":"n1…","task_id":"f04d6e2a-…","task_key":"CREW-43","task_title":"Print badges",
  "actor_name":"Bob Builder","kind":"mention","message":"mentioned you: can you check the printer?",
  "read_at":null,"created_at":"2026-11-06T12:40:00Z"
}]}
```

`kind` is `status`, `assigned`, `comment`, `mention`, `automation` (from a
rule's `notify` action) or `due_soon` (an open task of yours is due within
`reminders.due_soon_days`, see [Settings](#settings); `actor_name` is
`"Someone"`). Due-soon reminders go out once per task, person and due
date; moving the due date reminds again.

### `GET /api/v1/inbox/unread-count`

Who may call: signed in. `{"count": 3}`, for the badge.

### `POST /api/v1/inbox/read`

Who may call: signed in. Body `{"ids": ["n1…", "n2…"]}` marks those read;
`{"ids": []}` (or no ids) marks **all** your notifications read. Answers
`204`.

```sh
curl -s -X POST $TASKS/api/v1/inbox/read -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"ids":[]}'
```

---

## Spaces

### `GET /api/v1/spaces`

Who may call: signed in. Every space you can enter (with the lists you may
see), plus spaces that only show up because a list in them is shared with
you (`shared_only: true`), as `{"spaces": [Space…], "truncated": false}`.
Archived spaces are left out unless you add `?archived=1`. At most 1,000
spaces; `truncated` is `true` when there are more.

```sh
curl -s "$TASKS/api/v1/spaces?archived=1" -H "Authorization: Bearer $TOKEN"
```

### `POST /api/v1/spaces`

Who may call: `space.create` or `space.manage`. Creates a space with the
default statuses (To do, In progress, Review, Done) and one list,
"General". You get `manage`.

| Field | Required | Rules |
| --- | --- | --- |
| `name` | yes | Non-empty. |
| `key` | yes | 2–6 letters or digits, starting with a letter; unique. Stored upper-case. |
| `color` | no | `#1a2b3c`. |
| `description` | no | |
| `everyone_level` | no | `view`, `edit`, `manage`, or `null` for a closed space (default). |

```sh
curl -s -X POST $TASKS/api/v1/spaces -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"Registration","key":"REG","color":"#22c55e","everyone_level":"view"}'
```

Response `201`: the Space, with `"my_level": "manage"`.

| Status | When |
| --- | --- |
| `403` | Missing `space.create`. |
| `409` | `"another space already uses this key"`. |
| `422` | `details.name`, `details.key`, `details.color`, `details.everyone_level`. |

### `GET /api/v1/spaces/{space}`

Who may call: `view`, or a direct grant on one of its lists (then
`shared_only: true` with only those lists). Returns the Space.

### `PATCH /api/v1/spaces/{space}`

Who may call: `manage`. Same fields as create, all optional. Changing `key`
renumbers nothing: existing tasks get the new prefix and old keys keep
resolving. `"everyone_level": null` closes the space. `"archived": true`
hides the space from the sidebar and search (tasks stay, My Work still
shows them), `false` restores it; for a department space HR's next save
sets it back to the department's state. Response `200`.
Errors: `409` duplicate key, `422`.

```sh
curl -s -X PATCH $TASKS/api/v1/spaces/3c1b2a90-… -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"archived":true}'
```

### `DELETE /api/v1/spaces/{space}`

Who may call: `manage`. Deletes the space with all its lists, tasks,
comments and attachments metadata. Recorded in the audit log. Answers `204`.

### `PUT /api/v1/spaces/{space}/statuses`

Who may call: `manage`. **Replaces** the space's statuses with exactly the
list you send, in that order (the order is the board's column order).

| Field per status | Meaning |
| --- | --- |
| `id` | Keep and update an existing status; omit to create a new one. |
| `name` | Required. |
| `color` | Required, `#1a2b3c`. |
| `category` | `not_started`, `active` or `done`. |

Rules: at least one status, at least one open (`not_started` or `active`)
and one `done`. Tasks on a status you leave out move to the first remaining
status of the same category (or the first status); each move is logged on
the task. Changing a category completes or reopens tasks accordingly.

```sh
curl -s -X PUT $TASKS/api/v1/spaces/3c1b2a90-…/statuses -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"statuses":[
    {"id":"a1…","name":"To do","color":"#9ca3af","category":"not_started"},
    {"id":"a2…","name":"Doing","color":"#3b82f6","category":"active"},
    {"name":"Blocked","color":"#ef4444","category":"active"},
    {"id":"a4…","name":"Done","color":"#22c55e","category":"done"}]}'
```

Response `200`: `{"statuses": [...]}`. Errors: `422` with messages such as
`"keep at least one open and one done status"`, `"unknown status id …"`.

### Sharing: grants

A **grant** gives a person or a Keycloak group a level on a space or on a
single list. The same endpoints exist for both scopes:

| Method and path | Who | Body | Response |
| --- | --- | --- | --- |
| `GET /api/v1/spaces/{space}/grants` | `manage` on the space | none | `{"grants":[Grant…]}` |
| `PUT /api/v1/spaces/{space}/grants` | `manage` on the space | `subject_type`, `subject`, `level` | `200` Grant (created or level replaced) |
| `DELETE /api/v1/spaces/{space}/grants/{grant}` | `manage` on the space | none | `204` |
| `GET /api/v1/lists/{list}/grants` | `manage` on the list | none | `{"grants":[Grant…]}` |
| `PUT /api/v1/lists/{list}/grants` | `manage` on the list | same | `200` Grant |
| `DELETE /api/v1/lists/{list}/grants/{grant}` | `manage` on the list | none | `204` |

| Field | Rules |
| --- | --- |
| `subject_type` | `user` or `group`. |
| `subject` | A user id (must exist) or a Keycloak group name. |
| `level` | `view`, `edit` or `manage`. |

```sh
curl -s -X PUT $TASKS/api/v1/spaces/3c1b2a90-…/grants -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"subject_type":"group","subject":"dept-crew","level":"edit"}'
```

```json
{"id":"g1…","space_id":"3c1b2a90-…","subject_type":"group","subject":"dept-crew","subject_key":"dept-crew","display_name":"dept-crew","level":"edit"}
```

**How group names match.** A group grant matches a person whose token
lists the same group after both names are **normalised**: spaces trimmed,
one leading `/` removed (Keycloak's full-path form), lower-cased. The whole
path must match: a grant to `/Departments/Ops` matches the token group
`departments/ops`, but not `ops` and not `departments/ops/stage`.
`subject` is the name as you typed it (shown in the UI); `subject_key` is
the normalised form that matching uses. Granting the same group again in
another spelling updates the one existing grant.

For a user grant, `display_name` is the person's name (`"Former user"` if
they were deleted) and `subject_key` equals `subject`. Giving and removing
grants is written to the [audit log](#audit-log). Errors: `404 "grant not
found"` when deleting a grant that does not belong to that space or list;
`422` for bad fields (a group name that is empty after normalising, such
as `/`, is `details.subject = "required"`).

---

## Folders, lists, tags

### Folders

| Method and path | Who | Body | Response |
| --- | --- | --- | --- |
| `POST /api/v1/spaces/{space}/folders` | `manage` | `name` (required), `position` | `201` Folder |
| `PATCH /api/v1/folders/{folder}` | `manage` on its space | `name`, `position` | `200` Folder |
| `DELETE /api/v1/folders/{folder}` | `manage` on its space | none | `204`; its lists move to the space root |

### Lists

#### `POST /api/v1/spaces/{space}/lists`

Who may call: `manage` on the space. Adds a list at the end.

| Field | Rules |
| --- | --- |
| `name` | Required. |
| `description` | Optional. |
| `private` | `true` hides it from people whose access comes only from the space. |

```sh
curl -s -X POST $TASKS/api/v1/spaces/3c1b2a90-…/lists -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"name":"Load-in Friday","private":false}'
```

Response `201`: the List.

#### `GET /api/v1/lists/{list}`

Who may call: `view` on the list. The List plus its space (for the board's
columns) and your level on the list:

```json
{"id":"8e2f0c1d-…","space_id":"3c1b2a90-…","folder_id":null,"name":"General","description":"","position":1,
 "private":false,"archived":false,"open_tasks":4,"done_tasks":9,
 "space":{"id":"3c1b2a90-…","name":"Crew","key":"CREW","statuses":[…],"my_level":"edit","can_edit":true,"can_manage":false,"…":"…"},
 "my_level":"edit","can_edit":true}
```

#### `PATCH /api/v1/lists/{list}`

Who may call: `manage` on the list. All fields optional:

| Field | Meaning |
| --- | --- |
| `name`, `description`, `position`, `private` | As named. |
| `folder_id` | A folder id in the **same** space, or `null` to move the list back to the space root. |
| `archived` | `true` archives (hidden from the sidebar, restorable), `false` restores. |

Response `200`: the List. Errors: `422 "the folder is in another space"`.

#### `DELETE /api/v1/lists/{list}`

Who may call: `manage` on the list. Deletes the list and its tasks;
recorded in the audit log. A space must keep at least one non-archived
list: deleting the last one is `409 "a space needs at least one list"`.
Answers `204`.

#### `GET /api/v1/lists/{list}/tasks`

Who may call: `view` on the list. Top-level tasks and subtasks of the list
in board order, as `{"tasks": [Task…]}`. Paged (see [Paging](#paging)).

#### `GET /api/v1/spaces/{space}/archived-lists`

Who may call: `manage`. `{"lists": [List…]}` for the archived lists, so they
can be restored with `PATCH … {"archived": false}`.

#### `GET /api/v1/lists/{list}/time-report?from=&to=`

Who may call: `view` on the list. Time logged on the list's tasks
(subtasks included) per person between `from` and `to` (both optional,
`YYYY-MM-DD`, inclusive).

```sh
curl -s "$TASKS/api/v1/lists/8e2f0c1d-…/time-report?from=2026-11-01&to=2026-11-30" -H "Authorization: Bearer $TOKEN"
```

```json
{"people":[{"user_id":"0f3c…","user_name":"Alice Example","minutes":240},{"user_id":"5b1e…","user_name":"Bob Builder","minutes":90}],"total_minutes":330}
```

Errors: `422 details.from`/`details.to = "must be YYYY-MM-DD"`.

#### `POST /api/v1/lists/{list}/import`

Who may call: `edit` on the list. Creates tasks in the list from a file you
send as text.

| Field | Rules |
| --- | --- |
| `format` | `csv`, `clickup` (ClickUp's CSV export) or `vikunja` (the `data.json` of a Vikunja export). |
| `content` | The file's contents, at most 5 MB and 2,000 tasks. |
| `dry_run` | `true`: check and preview, write nothing. |

**CSV columns** (header row, case-insensitive; only a title column is
required): `Title`/`Name`/`Task Name`, `Description`/`Task Content`/`Notes`,
`Status`, `Priority` (`urgent`, `high`, `normal`/`medium`, `low`, or 1–4),
`Due Date`, `Start Date` (`YYYY-MM-DD`, `DD/MM/YYYY`, `D.M.YYYY`, ISO time,
Unix milliseconds or ClickUp's `Tuesday, March 5th 2024`),
`Assignees` (emails or names, separated by `,` `;` or `|`, brackets
allowed), `Tags`, `Done` (`yes`/`true`/`1`/`x`).

**How values are matched:**

- **Status:** by name in this space; otherwise names like *done*,
  *closed*, *complete* (and Vikunja's `done: true`) go to the first `done`
  status, everything else to the first `not_started` one.
- **People:** by email or display name among people who have signed in to
  Tasks; anyone else is left unassigned with a warning.
- **Tags:** by name in this space; missing ones are created if you
  `manage` the space, otherwise left off with a warning.
- **Vikunja:** HTML descriptions become plain text; priorities 1–5 map to
  low, normal, high, urgent, urgent; the zero date means "no date".

```sh
jq -Rs '{format:"csv", dry_run:true, content:.}' tasks.csv \
  | curl -s -X POST $TASKS/api/v1/lists/8e2f0c1d-…/import -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" -d @-
```

```json
{"dry_run":true,"created":3,"skipped":1,"new_tags":["transport"],
 "warnings":["line 4: no title, skipped","line 5: \"nobody@example.org\" has never signed in to Tasks, not assigned"],
 "preview":[{"line":2,"title":"Book bus","status":"In progress","priority":"high","start_at":null,"due_at":"2026-12-01","assignees":["bob@example.org"],"tags":["transport"]}]}
```

Without `dry_run` the same body creates everything in **one transaction**
and answers `201` with the same shape (`preview` holds the first 50
tasks). Each import is in the [audit log](#audit-log) (`list` / `imported`).

| Status | When |
| --- | --- |
| `409` | The list is archived. |
| `422` | Unknown `format`; not valid CSV or JSON; no title column; more than 2,000 tasks; over 5 MB. |

### Tags

| Method and path | Who | Body | Response |
| --- | --- | --- | --- |
| `GET /api/v1/spaces/{space}/tags` | `view` | none | `{"tags":[{"id","name","color"}]}` |
| `POST /api/v1/spaces/{space}/tags` | `manage` | `name` (1–50, required), `color` (`#1a2b3c`) | `201` Tag |
| `PATCH /api/v1/spaces/{space}/tags/{tag}` | `manage` | `name`, `color` | `200` Tag |
| `DELETE /api/v1/spaces/{space}/tags/{tag}` | `manage` | none | `204`; removed from every task |

```sh
curl -s -X POST $TASKS/api/v1/spaces/3c1b2a90-…/tags -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"name":"printing","color":"#f59e0b"}'
```

Tag names are unique per space: `409 "this space already has a tag with
that name"`. Put tags on a task with `PATCH /api/v1/tasks/{task}`
`{"tag_ids": [...]}`.

### Custom fields

A **custom field** is an extra field every task in a space can fill in:
cost, vendor, stage, a link to a quote. A space defines its fields; values
are set per task with `PATCH /api/v1/tasks/{task}` and returned in every
Task's `fields`.

| Method and path | Who | Body | Response |
| --- | --- | --- | --- |
| `GET /api/v1/spaces/{space}/fields` | `view` | none | `{"fields":[Field…]}` in order |
| `POST /api/v1/spaces/{space}/fields` | `manage` | `name` (1–100), `type`, `options` (select only) | `201` Field |
| `PATCH /api/v1/fields/{field}` | `manage` on its space | `name`, `options`, `position` | `200` Field |
| `DELETE /api/v1/fields/{field}` | `manage` on its space | none | `204`; deletes every value; audit-logged |

| `type` | A value is | Example |
| --- | --- | --- |
| `text` | a string, up to 5,000 characters | `"Hall B, door 3"` |
| `number` | a number | `1250.5` |
| `date` | `YYYY-MM-DD` | `"2026-11-20"` |
| `select` | the `id` of one of the field's options | `"o1…"` |
| `checkbox` | `true` or `false` | `true` |
| `url` | an `http://` or `https://` address | `"https://example.org/quote.pdf"` |

```sh
curl -s -X POST $TASKS/api/v1/spaces/3c1b2a90-…/fields -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"Stage","type":"select","options":[{"name":"Ordered","color":"#22c55e"},{"name":"Delivered"}]}'
```

```json
{"id":"c7d2…","space_id":"3c1b2a90-…","name":"Stage","type":"select",
 "options":[{"id":"o1…","name":"Ordered","color":"#22c55e"},{"id":"o2…","name":"Delivered","color":"#9ca3af"}],"position":2}
```

A field's type cannot change (`422`; create a new field). Sending
`options` replaces them: keep an option's `id` to keep it; an option you
leave out is removed **from every task that had it**. Field names are unique
per space (`409`). Moving a task to another space drops its values, like
tags.

Errors: `409 "this space already has a field with that name"`, `422` with
`details.name`, `details.type` (`"must be text, number, date, select,
checkbox, url"`), `details.options` (`"a select field needs at least one
option"`, `"only select fields have options"`), `"a space can have at most
50 fields"`.

---

## Tasks

### `POST /api/v1/tasks`

Who may call: `edit` on the list (or on the parent task, for a subtask).
Only `title` and a place are required.

| Field | Rules |
| --- | --- |
| `list_id` | Required for a top-level task. |
| `parent_id` | A task id to create a **subtask** (same list). Subtasks cannot have subtasks. |
| `title` | Required, at most 500 characters. |
| `description` | Markdown text, at most 100,000 characters. |
| `status_id` | A status of the task's space; default: the first status. |
| `priority` | `urgent`, `high`, `normal`, `low`. |
| `start_at`, `due_at` | `YYYY-MM-DD`. |
| `assignee_ids` | User ids; each must exist. |

```sh
curl -s -X POST $TASKS/api/v1/tasks -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"list_id":"8e2f0c1d-…","title":"Print badges","priority":"high","due_at":"2026-11-20","assignee_ids":["0f3c9a52-…"]}'
```

Response `201`: the [Task](#common-objects). Assignees get an Inbox
notification and `task_created` automations run.

| Status | When |
| --- | --- |
| `403` / `404` | Below `edit` on the list, or the list is not visible. |
| `422` | `details.title`, `details.list_id` (`"required"`), `details.priority`, `details.start_at`/`due_at` (`"must be YYYY-MM-DD"`), `details.assignee_ids` (`"contains a user that does not exist"`), `"status does not belong to this space"`, `"subtasks cannot have their own subtasks"`. |

### `GET /api/v1/tasks/{task}`

Who may call: `view` on the task (assignment and watching count). The Task
plus everything the detail panel needs:

```json
{
  "id": "f04d6e2a-…", "key": "CREW-43", "title": "Print badges", "…": "all Task fields",
  "subtasks": [],
  "comments": [{"id":"c1…","author_id":"5b1e…","author_name":"Bob Builder","body":"@Alice Example can you check the printer?","created_at":"2026-11-06T12:40:00Z","edited_at":null}],
  "events": [{"id":"e1…","actor_name":"Alice Example","kind":"status","data":{"from":"To do","to":"In progress"},"created_at":"2026-11-06T12:45:00Z"}],
  "statuses": [ "…the space's statuses…" ],
  "checklist": [{"id":"k1…","task_id":"f04d6e2a-…","body":"Order lanyards","done":false,"position":1}],
  "watchers": [{"id":"0f3c…","display_name":"Alice Example"}],
  "attachments": [{"id":"at1…","task_id":"f04d6e2a-…","filename":"badge-template.pdf","content_type":"application/pdf","size_bytes":84211,"uploaded_by":"0f3c…","created_at":"2026-11-06T12:50:00Z"}],
  "comments_total": 1, "events_total": 1,
  "blocked_by": [{"id":"d1…","key":"CREW-40","title":"Order paper","status":{"id":"a2…","name":"In progress","color":"#3b82f6","category":"active"},"done":false,"list_id":"8e2f0c1d-…","space_id":"3c1b2a90-…"}],
  "blocking": [],
  "hidden_dependencies": 0,
  "time_entries": [{"id":"te1…","task_id":"f04d6e2a-…","user_id":"0f3c…","user_name":"Alice Example","minutes":45,"spent_on":"2026-11-06","note":"template","created_at":"2026-11-06T13:10:00Z"}]
}
```

`comments` holds the newest 100 comments and `events` the newest 200
activity entries, oldest first; `comments_total` and `events_total` count
all of them. `blocked_by` and `blocking` leave out tasks you cannot see and
count them in `hidden_dependencies`. `time_entries` holds the latest 500.

```sh
curl -s $TASKS/api/v1/tasks/CREW-43 -H "Authorization: Bearer $TOKEN"
```

### `GET /api/v1/tasks/{task}/comments`, `GET /api/v1/tasks/{task}/events`

Who may call: `view` on the task. All comments (`{"comments": [...]}`) or
all activity entries (`{"events": [...]}`), oldest first, paged with
`limit` and `X-Next-Cursor` (see [Paging](#paging)). Use them when the
detail's `comments_total` or `events_total` is larger than what it
embedded.

```sh
curl -s -D - "$TASKS/api/v1/tasks/CREW-43/comments?limit=100" -H "Authorization: Bearer $TOKEN"
```

Errors: `400 "invalid cursor"`, `404` as for the task.

### `PATCH /api/v1/tasks/{task}`

Who may call: `edit` on the task (being assigned is enough). Moving to
another list (also in another space) needs `edit` on the target list too.

Send only the fields to change, **plus the `version` you last read**
(required). This is the lost-update guard: if anyone saved the task since
you read it, the answer is `409` and nothing changes; reload and reapply.

| Field | Notes |
| --- | --- |
| `version` | Required. |
| `title`, `description` | As on create. |
| `status_id` | Fires `status_changed` automations; notifies followers. |
| `list_id` | Move. A move to another space (subtasks come along) gives the task a new key there; the old key keeps resolving. Statuses are remapped by category, and tags stay behind because tags belong to a space. |
| `position` | Float; to drop between two tasks send the midpoint. |
| `priority`, `start_at`, `due_at` | `null` clears. |
| `assignee_ids` | The full new set; newly added people are notified. |
| `tag_ids` | The full new set; tags must belong to the task's space. |
| `fields` | `{"<field id>": value}` for the [custom fields](#custom-fields) to change; `null` clears one. Fields not named stay as they are. |
| `recurrence` | `{"freq": "daily"|"weekly"|"monthly"|"yearly", "interval": 1–365}` (interval defaults to 1), or `null` to stop repeating. Top-level tasks only. See [Recurring tasks](#recurring-tasks). |
| `estimate_minutes` | Planned effort in minutes (0–1,000,000), or `null`. |

```sh
curl -s -X PATCH $TASKS/api/v1/tasks/CREW-43 -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"status_id":"a2…","due_at":null,"version":1}'
```

```sh
curl -s -X PATCH $TASKS/api/v1/tasks/CREW-43 -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"version":2,"fields":{"c7d1…":1250.5,"c7d2…":"o1…"},"recurrence":{"freq":"weekly","interval":2},"estimate_minutes":120}'
```

Response `200`: the Task with `version` increased. With a stale version:

```json
{"error":{"code":"conflict","message":"someone else changed this task — reload and try again"}}
```

Errors: `409` stale version; `422 details.version = "required"` and the
field rules from create; `422 details["fields.<id>"]` for a value that
does not fit its field (`"Cost must be a number"`, `"Stage must be one of
its options"`, `"not a field of this space"`); `422
details["recurrence.freq"]`/`details["recurrence.interval"]`, `422
details.recurrence = "subtasks cannot repeat"`; `422
details.estimate_minutes`.

### Dependencies

A task can **wait for** other tasks ("blocked by"). The web app shows a
lock on tasks with unfinished blockers; nothing stops you from finishing a
blocked task.

| Method and path | Who | Body | Response |
| --- | --- | --- | --- |
| `POST /api/v1/tasks/{task}/dependencies` | `edit` on the task, `view` on the other | `{"depends_on": "<uuid or KEY-N>"}` | `201` the other task (DepRef) |
| `DELETE /api/v1/tasks/{task}/dependencies/{other}` | `edit` on the task | none | `204` |

```sh
curl -s -X POST $TASKS/api/v1/tasks/CREW-43/dependencies -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"depends_on":"CREW-40"}'
```

```json
{"id":"d1…","key":"CREW-40","title":"Order paper","status":{"id":"a2…","name":"In progress","color":"#3b82f6","category":"active"},"done":false,"list_id":"8e2f0c1d-…","space_id":"3c1b2a90-…"}
```

Tasks in different spaces can depend on each other. Adding an existing
dependency changes nothing. Both tasks get an activity entry.

| Status | When |
| --- | --- |
| `404` | Either task does not exist or you cannot see it; removing a dependency that does not exist. |
| `422` | `"a task cannot depend on itself"`, `"that would make the tasks wait for each other in a circle"`, `"a task can wait for at most 50 others"`. |

### Recurring tasks

Set `recurrence` on a top-level task with `PATCH /api/v1/tasks/{task}`.
When the task moves into a `done` status — by hand, on a board or through
an [automation](#automations) — Tasks creates the **next occurrence**:

- in the same list, in the space's first `not_started` status, with a new key;
- start and due dates moved on by `interval` days, weeks, months or years
  (31 January + 1 month is 28 February);
- with the same title, description, priority, assignees, watchers, tags,
  custom field values, estimate and checklist (unticked);
- without subtasks, comments, attachments or time entries.

The rule moves to the new task (the finished one has `recurrence: null`),
so reopening and finishing the old task again does not create another
copy. The old task's activity says `recurred` with the new key.

### Time tracking

| Method and path | Who | Body | Response |
| --- | --- | --- | --- |
| `GET /api/v1/tasks/{task}/time` | `view` | none | `{"entries":[TimeEntry…],"total_minutes":…,"estimate_minutes":…}` |
| `POST /api/v1/tasks/{task}/time` | `edit` | `minutes` (1–1,440, required), `spent_on` (`YYYY-MM-DD`, default today), `note` (up to 1,000) | `201` TimeEntry |
| `DELETE /api/v1/time/{entry}` | the person who logged it (with `edit`), or `manage` on the space | none | `204` |

```sh
curl -s -X POST $TASKS/api/v1/tasks/CREW-43/time -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"minutes":45,"spent_on":"2026-11-06","note":"template"}'
```

```json
{"id":"te1…","task_id":"f04d6e2a-…","user_id":"0f3c…","user_name":"Alice Example","minutes":45,"spent_on":"2026-11-06","note":"template","created_at":"2026-11-06T13:10:00Z"}
```

Totals per person for a list: [`GET /api/v1/lists/{list}/time-report`](#get-apiv1listslisttime-reportfromto).
Errors: `422 details.minutes = "1 to 1440 (one day)"`, `details.spent_on`,
`details.note`; `403 "only the person who logged the time or a space
manager can remove it"`.

### `DELETE /api/v1/tasks/{task}`

Who may call: the task's **creator**, or `manage` on its space. Moves the
task (and its subtasks) to the space's **trash**; recorded in the audit
log. Answers `204`. Anyone else gets `403 "only the task's creator or a
space manager can delete it"`.

### Trash

| Method and path | Who | Response |
| --- | --- | --- |
| `GET /api/v1/spaces/{space}/trash` | `manage` | `{"tasks":[{"id","key","title","list_name","deleted_at","deleted_by"}]}` |
| `POST /api/v1/tasks/{task}/restore` | `manage` on its space | `200` Task, back in its list |
| `DELETE /api/v1/tasks/{task}/purge` | `manage` on its space | `204`; gone for good with its attachment files (audit-logged) |

Trashed tasks answer `404` on every normal task endpoint. Tasks that stay
in the trash longer than `retention.trash_days` (default 30) are purged
automatically; see [Settings](#settings).

### Comments

| Method and path | Who | Body | Response |
| --- | --- | --- | --- |
| `POST /api/v1/tasks/{task}/comments` | `edit` on the task | `body` (1–20,000 characters), `mentions` (user ids) | `201` Comment |
| `PATCH /api/v1/comments/{comment}` | the author | `body` | `200` Comment with `edited_at` |
| `DELETE /api/v1/comments/{comment}` | the author, or `manage` on the space | none | `204`; audit-logged |

```sh
curl -s -X POST $TASKS/api/v1/tasks/CREW-43/comments -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"body":"@Alice Example can you check the printer?","mentions":["0f3c9a52-…"]}'
```

```json
{"id":"c1…","author_id":"5b1e…","author_name":"Bob Builder","body":"@Alice Example can you check the printer?","created_at":"2026-11-06T12:40:00Z","edited_at":null}
```

`mentions` decides who gets a "mention" notification (the web app fills it
from the `@Full Name` picker); other followers get a "comment"
notification. Errors: `422 "comment is empty"`/`"comment is too long"`,
`403 "you can only edit your own comments"`.

### Checklist

| Method and path | Who | Body | Response |
| --- | --- | --- | --- |
| `POST /api/v1/tasks/{task}/checklist` | `edit` | `{"body": "Order lanyards"}` | `201` item |
| `PATCH /api/v1/checklist/{item}` | `edit` on its task | `body`, `done`, `position` | `200` item |
| `DELETE /api/v1/checklist/{item}` | `edit` on its task | none | `204` |

Ticking the last open item fires `checklist_completed` automations.
Errors: `422 "checklist item is empty"` / `"too long"`.

### Watching

| Method and path | Who | Response |
| --- | --- | --- |
| `POST /api/v1/tasks/{task}/watch` | `view` | `204`; you get Inbox notifications for the task |
| `DELETE /api/v1/tasks/{task}/watch` | anyone | `204`; no access check, so you can always unsubscribe |

### Attachments

Files on a task, stored in the module's bucket and always served through
the backend after the task's access check (never via presigned links).
Optional: without `S3_ENDPOINT`, upload and download answer `503` and the
rest of Tasks works normally.

#### `POST /api/v1/tasks/{task}/attachments`

Who may call: `edit` on the task. Multipart, one part named `file`, at most
**25 MB**.

```sh
curl -s -X POST $TASKS/api/v1/tasks/CREW-43/attachments -H "Authorization: Bearer $TOKEN" \
  -F "file=@badge-template.pdf;type=application/pdf"
```

Response `201`:

```json
{"id":"at1…","task_id":"f04d6e2a-…","filename":"badge-template.pdf","content_type":"application/pdf","size_bytes":84211,"uploaded_by":"0f3c…","created_at":"2026-11-06T12:50:00Z"}
```

Errors: `400` (not multipart, no `file` part), `413`/`422` (over 25 MB),
`503` (no object storage).

#### `GET /api/v1/attachments/{attachment}`

Who may call: `view` on the task. Streams the file; images `inline`,
everything else as an `attachment` download, with
`X-Content-Type-Options: nosniff`.

#### `DELETE /api/v1/attachments/{attachment}`

Who may call: the uploader (with `edit`), or `manage` on the space. Answers
`204`. Anyone else: `403 "only the uploader or a space manager can remove
an attachment"`.

---

## Automations

An **automation** is a rule "when X happens (and these conditions hold), do
Y". Rules belong to a space and optionally to one list. They run inside the
same database transaction as the change that triggered them, so if the
change fails, nothing the rule did survives. Each rule runs under its own
savepoint: a broken rule fails alone, without breaking the person's edit,
and the failure appears in its run history. Chains (rule A sets a status
that triggers rule B) run each rule at most once per original change and
stop at depth 5.

### Who may manage rules

`manage` on the space manages every rule; `manage` on one list manages the
rules scoped to that list. `GET` for a list manager returns only their
list's rules.

| Method and path | Body | Response |
| --- | --- | --- |
| `GET /api/v1/spaces/{space}/automations` | none | `{"automations":[Automation…]}` |
| `POST /api/v1/spaces/{space}/automations` | see below | `201` Automation |
| `PATCH /api/v1/automations/{automation}` | any subset | `200` Automation |
| `DELETE /api/v1/automations/{automation}` | none | `204` |
| `GET /api/v1/automations/{automation}/runs` | none | `{"runs":[…]}`, last 50 |

### Rule body

| Field | Required on create | Meaning |
| --- | --- | --- |
| `name` | yes | At most 200 characters. |
| `enabled` | no | Default `true`. |
| `list_id` | no | Scope to one list; `null` = the whole space. |
| `trigger` | yes | One trigger object. |
| `conditions` | no | Up to 10; all must hold. |
| `actions` | yes | 1–10, run in order. |

**Triggers** (`trigger.type`):

| Type | Extra fields | Fires when |
| --- | --- | --- |
| `task_created` | | A task is created. |
| `status_changed` | `status_id` **or** `category` (optional) | A task's status changes (to that status or category, if given). |
| `assignee_added` | | Someone is assigned. |
| `comment_added` | | Someone comments. |
| `checklist_completed` | | The last open checklist item is ticked. |
| `due_approaching` | `days_before` (0–365, required) | A task is that many days from its due date. A background sweep checks this periodically and fires each rule at most once per task. |

**Conditions**: `{"field": "list" | "status" | "priority" | "tag" | "assignee", "value": "<id or priority name>"}`.

**Actions** (`actions[].type`):

| Type | Field | Does |
| --- | --- | --- |
| `set_status` | `status_id` | Change the status. |
| `assign` | `user_id` | Add an assignee. |
| `set_priority` | `priority` | `urgent`, `high`, `normal`, `low`. |
| `set_due` | `days` (0–3650) | Due date = today + days. |
| `add_tag` | `tag_id` | Add a tag. |
| `move_list` | `list_id` | Move to another (non-archived) list in the same space. |
| `create_subtask` | `title` | Add a subtask. |
| `add_checklist_item` | `body` | Add a checklist item. |
| `add_comment` | `body` | Post a comment. |
| `notify` | `message` | Inbox notification to the task's followers. |

Every status, tag and list a rule references must belong to the same
space, so a rule can never touch things outside it.

```sh
curl -s -X POST $TASKS/api/v1/spaces/3c1b2a90-…/automations -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{
    "name": "Done tasks go to the archive list",
    "list_id": null,
    "trigger": {"type": "status_changed", "category": "done"},
    "conditions": [{"field": "priority", "value": "low"}],
    "actions": [{"type": "move_list", "list_id": "9d8c…"},
                {"type": "notify", "message": "Archived automatically"}]
  }'
```

Response `201`:

```json
{"id":"au1…","space_id":"3c1b2a90-…","list_id":null,"name":"Done tasks go to the archive list","enabled":true,
 "trigger":{"type":"status_changed","category":"done"},
 "conditions":[{"field":"priority","value":"low"}],
 "actions":[{"type":"move_list","list_id":"9d8c…"},{"type":"notify","message":"Archived automatically"}],
 "created_by":"0f3c…","created_at":"2026-11-06T13:00:00Z","updated_at":"2026-11-06T13:00:00Z"}
```

Run history entry: `{"id","task_id","task_key","status","detail","created_at"}`,
where `status` is `ok` (with a summary of what the rule did in `detail`)
or `error` (the reason, for example `"status no longer exists in this
space"`; the rule's changes were rolled back, the person's edit was not).

Errors: `422 "invalid automation"` with `details.trigger`,
`details.conditions` or `details.actions` explaining the problem (for
example `"set_status needs status_id"`, `"tag is not in this space"`).

---

## Department hook (HR)

### `POST /api/internal/departments`

Who may call: **HR, server to server**. HR sends this request to every
entry of its `DEPARTMENT_HOOKS` setting when a department is **created**,
**saved** (renamed, default roles changed) or **archived** (see HR's
[department hooks](../hr/api.md#department-hooks-outbound)). Authenticated
with `Authorization: Bearer <TASKS_SERVICE_TOKEN>` (constant-time
compare), not a user token. The route answers a plain `404` while
`TASKS_SERVICE_TOKEN` is empty, so it is off by default. The token is a
secret; see [Secrets](../../operations/secrets.md).

**The contract.** This is the body HR's `DepartmentService` sends; Tasks
accepts exactly that and **ignores fields it does not know**, so HR can
add fields before Tasks uses them.

| Field | Required | Meaning |
| --- | --- | --- |
| `id` | yes | HR's department id (UUID); the link between the department and its space. |
| `slug` | yes | For example `front-of-house`; used to pick a free space key. Never changes in HR. |
| `name` | yes | For example `Front of House`. |
| `group` | yes | The department's Keycloak group, for example `dept-front-of-house`. Used only when the space is created. |
| `archived` | no | `true` when the department is archived; absent or `false` means active. |

The **first** call for a department creates a **closed** space with the
default statuses, the lists "To do", "Handoffs" and "Done archive", and an
`edit` grant for the department's group (normalised like every
[group grant](#sharing-grants)), then answers `201`. **Later** calls keep
the space name and archived state in sync with HR and answer `200`;
lists, statuses and extra grants stay in the department's hands. Safe to
repeat, and two first calls at the same time still create one space.
Creating the group grant and archiving or restoring the space are written
to the [audit log](#audit-log) with the actor *System*.

| HR event | HR sends | Tasks does |
| --- | --- | --- |
| Department created | `{id, slug, name, group}` | Creates the space (`201`). |
| Department saved | `{id, slug, name, group}` | Renames the space if needed; restores it if it was archived (`200`). |
| Department archived | `{id, slug, name, group, "archived": true}` | Archives the space: hidden from the sidebar and search, nothing deleted (`200`). |

```sh
curl -s --cacert /etc/conservices-internal-ca/ca.crt -X POST https://tasks-backend.conservices-tasks.svc.cluster.local:8080/api/internal/departments \
  -H "Authorization: Bearer change-me" -H "Content-Type: application/json" \
  -d '{"id":"7a0c1e2f-3b4d-4c5e-8f6a-7b8c9d0e1f2a","slug":"front-of-house","name":"Front of House","group":"dept-front-of-house"}'
```

Response: the Space (without capability flags).

| Status | When |
| --- | --- |
| `201` | Space created. |
| `200` | Space already existed; name and archived state synced. |
| `400` | Malformed JSON. |
| `401` | `"invalid service token"`. |
| `404` | `TASKS_SERVICE_TOKEN` empty: endpoint off. |
| `409` | No free space key could be derived from the slug. |
| `422` | `details.id`/`slug`/`name`/`group` = `"required"`. |

A NetworkPolicy only lets HR's pods reach this path; see
[Network policies](../../operations/network-policies.md).

---

## Admin

Who may call: `settings.manage` (`tasks-admin`). Anyone else gets `403`.

### Audit log

#### `GET /api/v1/audit`

The audit log, **newest first**: deleted and purged tasks, lists, spaces,
comments, attachments and custom fields; grants given and removed;
archived and restored spaces; imports; settings changes. Each entry keeps a
snapshot (key, title, name, counts), so it still makes sense after the
thing is gone.

| Query | Meaning |
| --- | --- |
| `entity` | `task`, `list`, `space`, `comment`, `attachment`, `grant`, `settings` or `field`. |
| `action` | For example `deleted`, `purged`, `granted`, `revoked`, `archived`, `restored`, `imported`, `updated`. |
| `actor` | A user id. |
| `entity_id` | The id of the task, list, space… |
| `since`, `until` | RFC 3339 or `YYYY-MM-DD`; `since` inclusive, `until` exclusive. |
| `limit`, `cursor` | [Paging](#paging), towards older entries. |

```sh
curl -s "$TASKS/api/v1/audit?entity=task&action=deleted&since=2026-11-01" -H "Authorization: Bearer $TOKEN"
```

```json
{"entries":[{"id":"al1…","created_at":"2026-11-06T14:02:11Z","actor_id":"0f3c…","actor_name":"Alice Example",
  "entity":"task","entity_id":"f04d6e2a-…","action":"deleted","data":{"key":"CREW-43","title":"Print badges","subtasks":0}}]}
```

`actor_id` is `null` and `actor_name` is `"System"` for entries made by
the retention job or HR's department hook. Errors: `422 details.entity`
(`"unknown entity"`), `details.actor`/`details.entity_id` (`"must be a
uuid"`), `details.since`/`details.until`, `400 "invalid cursor"`.

The web app shows the same at *Settings → Audit log*.

### Settings

#### `GET /api/v1/settings`

Retention and reminder settings with where each value comes from, and
whether email is configured (never the password).

```sh
curl -s $TASKS/api/v1/settings -H "Authorization: Bearer $TOKEN"
```

```json
{
  "settings": {
    "retention": {"trash_days": 30, "notification_days": 90, "audit_days": 730, "automation_run_days": 90},
    "reminders": {"due_soon_days": 1}
  },
  "sources": {"retention.trash_days": "tasks", "retention.audit_days": "den", "…": "default"},
  "definitions": [{"key": "retention.trash_days", "default": 30, "min": 0, "max": 3650,
                   "description": "Days a deleted task stays in the trash before it is purged for good. 0 = never purge."}],
  "email": {"configured": true, "source": "den", "host": "smtp.example.org", "port": 587, "from": "tasks@example.org", "security": "starttls"}
}
```

| Setting | Default | Meaning (`0` = keep forever / off) |
| --- | --- | --- |
| `retention.trash_days` | 30 | Deleted tasks are purged from the trash after this many days, with their attachment files. |
| `retention.notification_days` | 90 | Read Inbox notifications are deleted after this many days. Unread ones stay. |
| `retention.audit_days` | 730 | Audit log entries are deleted after this many days. |
| `retention.automation_run_days` | 90 | Automation run history is deleted after this many days. |
| `reminders.due_soon_days` | 1 | Assignees get a due-soon reminder this many days before the due date and on the day. |

!!! warning "Retention defaults are pending legal review"
    The defaults are placeholders. Set the values your organisation's
    data-protection rules require, in Den's module settings (when paired)
    or here.

`sources` says `default`, `tasks` (set here) or `den` (sent by Den in its
module settings; see [Configuration](configuration.md#settings-from-den)).
`email.source` is `den`, `tasks` (the `SMTP_*` environment) or `none`.

#### `PUT /api/v1/settings`

Changes Tasks' own values. Send only what changes; `null` resets a setting
to its default. Recorded in the audit log (`settings` / `updated`).

```sh
curl -s -X PUT $TASKS/api/v1/settings -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"retention":{"trash_days":14},"reminders":{"due_soon_days":null}}'
```

Response `200`: the same shape as `GET`. Errors: `422` with
`details["retention.trash_days"]` = `"out of range"`, `"unknown setting"`,
or `"managed by Den; change it in Den's module settings"`.

#### `POST /api/v1/settings/email/test`

Sends a test email to **your own** address with the current SMTP settings.

```sh
curl -s -X POST $TASKS/api/v1/settings/email/test -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{}'
```

```json
{"sent_to":"alice@example.org"}
```

| Status | When |
| --- | --- |
| `409` | Email is not configured, or your account has no email address. |
| `503` | The mail server refused or could not be reached; the message says why (for example `smtp auth: 535 …`). |

---

## Den connection

Who may call: `settings.manage` (`tasks-admin`). The same pairing API as
every module; see [Pairing](../../concepts/pairing.md).

| Method and path | Result |
| --- | --- |
| `GET /api/v1/den` | `{"paired": true, "den_base_url", "module_id", "paired_at", "synced_at"}`, or `{"paired": false}`. |
| `POST /api/v1/den/pair` | Body `{"pairing_url": "<from Den>"}`; `422 pairing_failed` with the reason. |
| `POST /api/v1/den/sync` | Fetch Den's brand and settings now; `409` when not paired, `502` when Den fails. |
| `DELETE /api/v1/den/pair` | Unpair, `204`. |

---

## All endpoints at a glance

| Method | Path | Who |
| --- | --- | --- |
| GET | `/livez`, `/readyz`, `/api/health` | anyone |
| GET | `/api/role-catalog` | anyone |
| GET | `/api/v1/brand`, `/api/v1/brand/{role}` | anyone |
| POST | `/api/internal/departments` | `TASKS_SERVICE_TOKEN` |
| GET | `/api/v1/me` | signed in |
| GET, PUT | `/api/v1/me/preferences`, `/api/v1/me/notifications` | signed in |
| GET | `/api/v1/users`, `/api/v1/my-work`, `/api/v1/search`, `/api/v1/calendar` | signed in |
| GET | `/api/v1/stream`, `/api/v1/stream/status` | signed in |
| GET | `/api/v1/audit` | `settings.manage` |
| GET, PUT | `/api/v1/settings` | `settings.manage` |
| POST | `/api/v1/settings/email/test` | `settings.manage` |
| GET | `/api/v1/spaces/{space}/fields` | `view` |
| POST | `/api/v1/spaces/{space}/fields` | `manage` |
| PATCH, DELETE | `/api/v1/fields/{field}` | `manage` |
| GET | `/api/v1/lists/{list}/time-report` | `view` |
| POST | `/api/v1/lists/{list}/import` | `edit` |
| GET | `/api/v1/tasks/{task}/comments`, `/events`, `/time` | `view` |
| POST | `/api/v1/tasks/{task}/time` | `edit` |
| DELETE | `/api/v1/time/{entry}` | who logged it, or `manage` |
| POST | `/api/v1/tasks/{task}/dependencies` | `edit` (and `view` on the other task) |
| DELETE | `/api/v1/tasks/{task}/dependencies/{other}` | `edit` |
| GET | `/api/v1/inbox`, `/api/v1/inbox/unread-count` | signed in |
| POST | `/api/v1/inbox/read` | signed in |
| GET, PUT | `/api/v1/favorites` | signed in (`view` on the target to add) |
| POST | `/api/v1/favorites/remove` | signed in |
| GET | `/api/v1/spaces` | signed in |
| POST | `/api/v1/spaces` | `space.create` |
| GET | `/api/v1/spaces/{space}` | `view` (or a shared list) |
| PATCH, DELETE | `/api/v1/spaces/{space}` | `manage` |
| PUT | `/api/v1/spaces/{space}/statuses` | `manage` |
| POST | `/api/v1/spaces/{space}/lists`, `/folders` | `manage` |
| GET, PUT | `/api/v1/spaces/{space}/grants` | `manage` |
| DELETE | `/api/v1/spaces/{space}/grants/{grant}` | `manage` |
| GET | `/api/v1/spaces/{space}/tags` | `view` |
| POST | `/api/v1/spaces/{space}/tags` | `manage` |
| PATCH, DELETE | `/api/v1/spaces/{space}/tags/{tag}` | `manage` |
| GET | `/api/v1/spaces/{space}/archived-lists`, `/trash` | `manage` |
| GET, POST | `/api/v1/spaces/{space}/automations` | `manage` (space, or list for list rules) |
| PATCH, DELETE | `/api/v1/folders/{folder}` | `manage` |
| GET | `/api/v1/lists/{list}`, `/api/v1/lists/{list}/tasks` | `view` |
| PATCH, DELETE | `/api/v1/lists/{list}` | `manage` |
| GET, PUT | `/api/v1/lists/{list}/grants` | `manage` |
| DELETE | `/api/v1/lists/{list}/grants/{grant}` | `manage` |
| POST | `/api/v1/tasks` | `edit` on the list |
| GET | `/api/v1/tasks/{task}` | `view` (assignees and watchers too) |
| PATCH | `/api/v1/tasks/{task}` | `edit` (assignees too) |
| DELETE | `/api/v1/tasks/{task}` | creator, or `manage` |
| POST | `/api/v1/tasks/{task}/restore` | `manage` |
| DELETE | `/api/v1/tasks/{task}/purge` | `manage` |
| POST | `/api/v1/tasks/{task}/comments` | `edit` |
| PATCH | `/api/v1/comments/{comment}` | author |
| DELETE | `/api/v1/comments/{comment}` | author, or `manage` |
| POST | `/api/v1/tasks/{task}/checklist` | `edit` |
| PATCH, DELETE | `/api/v1/checklist/{item}` | `edit` |
| POST | `/api/v1/tasks/{task}/watch` | `view` |
| DELETE | `/api/v1/tasks/{task}/watch` | anyone signed in |
| POST | `/api/v1/tasks/{task}/attachments` | `edit` |
| GET | `/api/v1/attachments/{attachment}` | `view` |
| DELETE | `/api/v1/attachments/{attachment}` | uploader with `edit`, or `manage` |
| PATCH, DELETE | `/api/v1/automations/{automation}` | `manage` |
| GET | `/api/v1/automations/{automation}/runs` | `manage` |
| GET | `/api/v1/den` | `settings.manage` |
| POST | `/api/v1/den/pair`, `/api/v1/den/sync` | `settings.manage` |
| DELETE | `/api/v1/den/pair` | `settings.manage` |

The authorization tests in
[`backend/internal/http/authz_test.go`](https://github.com/AGlElectronics/tasks/blob/main/backend/internal/http/authz_test.go)
are the executable reference for edge cases.

## Troubleshooting

**`409 someone else changed this task` on every update.** You are sending
an old `version`. Read the task (`GET /api/v1/tasks/{task}`), apply your
change, and send the `version` from that read. In scripts, retry once after
re-reading.

**`422 details.version = "required"`.** `PATCH /tasks/{task}` always needs
`version`, even for a one-field change.

**`404` for a task I can see in the browser.** Check the token is for the
same person (`GET /api/v1/me`). A trashed task is also `404`; look in
`GET /api/v1/spaces/{space}/trash` (needs `manage`).

**`429 too_many_requests` in a bulk import.** Stay under about 20 requests
a second per person, and honour `Retry-After`.

**`503` on attachments.** `S3_ENDPOINT` is not set; attachments are
optional and everything else works. See [Configuration](configuration.md).

**`POST /api/internal/departments` answers `404`.** `TASKS_SERVICE_TOKEN`
is empty on Tasks. Set the same value in Tasks and HR
([Secrets](../../operations/secrets.md)).

**A department's space did not appear.** HR only logs failed hooks (its
save still succeeds). Check HR's log for `department hook failed`
(network: HR needs egress to `conservices-tasks`) or `department hook
refused the update` with the status (`401`: tokens differ; `503
den_pairing_required`: pair Tasks with Den first). Saving the department
again in HR retries.

**The stream disconnects every minute or two.** A proxy cuts long
requests. The Helm chart routes `/api/v1/stream` without a timeout
(`frontend.websocketPathRegex`); for your own proxy, allow idle reads of at
least 30 seconds and turn buffering off for that path. The web app falls
back to 15-second polling meanwhile.

**Events arrive in bursts minutes late.** A proxy buffers the stream. The
backend sends `X-Accel-Buffering: no` (nginx honours it); other proxies need
buffering switched off for `text/event-stream`.

**`422 "managed by Den"` on `PUT /api/v1/settings`.** Den's module
settings set that value; change it in Den, or remove it there to manage it
in Tasks.

**Nobody gets emails.** `GET /api/v1/settings` shows `"email":
{"configured": false}`: set `SMTP_HOST` and `SMTP_FROM` (or let Den send
SMTP settings). Configured but still nothing: send a test email (`POST
/api/v1/settings/email/test`) to see the server's answer, and check that
people have `email` on in `GET /api/v1/me/notifications` and an address
(`has_address`).

**An import skipped people or tags.** People are only matched if they have
signed in to Tasks at least once; tags are only created for space
managers. The `warnings` of a dry run list every row affected.
