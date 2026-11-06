# Tasks API reference

Tasks' backend serves a JSON API over HTTP. The web app is built on it,
and you can use it from scripts too: to create the task list for a new
convention day, import tasks from a spreadsheet, move everything that is
overdue into a "Handoffs" list, or show "my open tasks" on a kiosk. This
page documents **every endpoint** with who may call it, what to send, what
comes back and which errors to expect.

The route list is taken from the backend's router,
[`backend/internal/http/router.go`](https://github.com/AGlElectronics/tasks/blob/main/backend/internal/http/router.go),
and the handlers next to it (`tasks.go`, `features.go`, `internal_api.go`).
Conventions shared by every module (error shape, request ids, time formats)
are described once in [API conventions](../../concepts/api-conventions.md);
this page only repeats what is specific to Tasks.

## Basics

### Base address

| Where you call from | Base URL |
| --- | --- |
| A browser or script outside the cluster | `https://tasks.example.org` (the web app's nginx forwards `/api/` to the backend) |
| Another pod inside the cluster | `http://tasks-backend.conservices-tasks.svc.cluster.local:8080` |

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
| Request body | 1 MB; attachment uploads 25 MB plus 1 MB of form overhead. |
| Request time | 60 seconds. |
| Task title / description / comment | 500 / 100,000 / 20,000 characters. |
| Tag name | 50 characters. |

### Paging

`GET /api/v1/lists/{list}/tasks` and `GET /api/v1/my-work` return at most
`limit` tasks (default 200, max 500). When there are more, the response has
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
| 409 | `conflict` | Stale `version`, a duplicate space key or tag name, deleting a space's last list. |
| 413 | | Body over the size limit. |
| 422 | `validation_failed` | Field problems; `details` maps field to reason. |
| 429 | `too_many_requests` | Rate limit. |
| 503 | `unavailable` | Attachments without object storage (`S3_ENDPOINT` unset). |
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
and only see lists shared with you directly.

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
  "checklist_total": 0, "checklist_done": 0
}
```

| Field | Notes |
| --- | --- |
| `priority` | `urgent`, `high`, `normal`, `low`, or `null`. |
| `start_at`, `due_at` | Dates, `YYYY-MM-DD`, or `null`. |
| `version` | Increases on every change. Send it back on `PATCH` (see [version check](#patch-apiv1taskstask)). |
| `completed_at` | Set while the task is in a `done` status. |

---

## Health and discovery

| Method and path | Who | Response |
| --- | --- | --- |
| `GET /livez` | anyone | `{"status":"ok"}` while the process runs. |
| `GET /readyz` | anyone | `200 {"status":"ok","database":"ok"}`, or `503` with `"database":"down"`. |
| `GET /api/health` | anyone | `{"status":"ok","database":"ok","version":"1.1.0-1","uptime_sec":5231}` |
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
`space.manage`**; everyone else gets names only.

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

`kind` is `status`, `assigned`, `comment`, `mention`, or `automation`
(from a rule's `notify` action).

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
you (`shared_only: true`), as `{"spaces": [Space…]}`.

```sh
curl -s $TASKS/api/v1/spaces -H "Authorization: Bearer $TOKEN"
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
resolving. `"everyone_level": null` closes the space. Response `200`.
Errors: `409` duplicate key, `422`.

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
{"id":"g1…","space_id":"3c1b2a90-…","subject_type":"group","subject":"dept-crew","display_name":"dept-crew","level":"edit"}
```

For a user grant, `display_name` is the person's name (`"Former user"` if
they were deleted). Errors: `404 "grant not found"` when deleting a grant
that does not belong to that space or list; `422` for bad fields.

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
  "attachments": [{"id":"at1…","task_id":"f04d6e2a-…","filename":"badge-template.pdf","content_type":"application/pdf","size_bytes":84211,"uploaded_by":"0f3c…","created_at":"2026-11-06T12:50:00Z"}]
}
```

```sh
curl -s $TASKS/api/v1/tasks/CREW-43 -H "Authorization: Bearer $TOKEN"
```

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

```sh
curl -s -X PATCH $TASKS/api/v1/tasks/CREW-43 -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"status_id":"a2…","due_at":null,"version":1}'
```

Response `200`: the Task with `version` increased. With a stale version:

```json
{"error":{"code":"conflict","message":"someone else changed this task — reload and try again"}}
```

Errors: `409` stale version; `422 details.version = "required"` and the
field rules from create.

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
| `DELETE /api/v1/tasks/{task}/purge` | `manage` on its space | `204`; gone for good (audit-logged) |

Trashed tasks answer `404` on every normal task endpoint.

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

Who may call: **HR, server to server**, when a department is created or
renamed. Authenticated with `Authorization: Bearer <TASKS_SERVICE_TOKEN>`
(constant-time compare), not a user token. The route answers a plain `404`
while `TASKS_SERVICE_TOKEN` is empty, so it is off by default. The token is
a secret; see [Secrets](../../operations/secrets.md).

| Field | Required | Meaning |
| --- | --- | --- |
| `id` | yes | HR's department id (UUID); the link between the department and its space. |
| `slug` | yes | For example `front-of-house`; used to pick a free space key. |
| `name` | yes | For example `Front of House`. |
| `group` | yes | The department's Keycloak group, for example `dept-front-of-house`. |

The **first** call for a department creates a **closed** space with the
default statuses, the lists "To do", "Handoffs" and "Done archive", and an
`edit` grant for the department's group, then answers `201`. **Later**
calls only keep the space name in sync and answer `200`; lists, statuses
and extra grants stay in the department's hands. Safe to repeat.

```sh
curl -s -X POST http://tasks-backend.conservices-tasks.svc.cluster.local:8080/api/internal/departments \
  -H "Authorization: Bearer change-me" -H "Content-Type: application/json" \
  -d '{"id":"7a0c1e2f-3b4d-4c5e-8f6a-7b8c9d0e1f2a","slug":"front-of-house","name":"Front of House","group":"dept-front-of-house"}'
```

Response: the Space (without capability flags).

| Status | When |
| --- | --- |
| `201` | Space created. |
| `200` | Space already existed; name synced. |
| `400` | Malformed JSON. |
| `401` | `"invalid service token"`. |
| `404` | `TASKS_SERVICE_TOKEN` empty: endpoint off. |
| `409` | No free space key could be derived from the slug. |
| `422` | `details.id`/`slug`/`name`/`group` = `"required"`. |

A NetworkPolicy only lets HR's pods reach this path; see
[Network policies](../../operations/network-policies.md).

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

71 routes.

| Method | Path | Who |
| --- | --- | --- |
| GET | `/livez`, `/readyz`, `/api/health` | anyone |
| GET | `/api/role-catalog` | anyone |
| GET | `/api/v1/brand`, `/api/v1/brand/{role}` | anyone |
| POST | `/api/internal/departments` | `TASKS_SERVICE_TOKEN` |
| GET | `/api/v1/me` | signed in |
| GET, PUT | `/api/v1/me/preferences` | signed in |
| GET | `/api/v1/users`, `/api/v1/my-work`, `/api/v1/search` | signed in |
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
