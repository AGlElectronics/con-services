# Learn API reference

Learn's web app is built entirely on this HTTP API, so everything it does
(courses, quizzes, in-person sessions, qualifications, learning paths,
reports) can also be scripted. Other modules use a few routes too: **HR**
reads the qualification catalog and asks which qualifications people hold
before granting a role, and **Den's** portal shows Learn to-dos.

This page lists **every route** in
[`backend/internal/http/router.go`](https://github.com/AGlElectronics/learn/blob/main/backend/internal/http/router.go)
and the route files it mounts, with who may call it, request and response
bodies, errors and `curl` examples. The rules shared by every Con Services
module (tokens, error shape, ids, timestamps) are on
[API conventions](../../concepts/api-conventions.md).

## Basics

| What | Value |
| --- | --- |
| Base address (browser, scripts) | The Learn address, for example `https://learn.example.org`. nginx forwards `/api/`, `/livez` and `/readyz` to the backend. |
| Base address (inside the cluster) | `https://learn-backend.conservices-learn.svc.cluster.local:8080` |
| Version prefix | `/api/v1` for the app; `/api/…` without `v1` for the cross-module contracts (catalogs, holdings, portal, public verify, Den state). `GET /api/den/state` is also at `/api/v1/den/state`. |
| Request bodies | JSON, `Content-Type: application/json`. **Unknown fields are rejected** with `400`. The question import is the one `multipart/form-data` route. |
| Ids | UUIDs. A malformed id answers `400` `invalid <name> id: …`. |
| Times | RFC 3339, for example `2026-11-06T12:00:00Z`. |
| Clearing a value | Fields documented as "`null` clears" tell an explicit `null` apart from leaving the field out. |
| Request id | Every response carries `X-Request-ID`; quote it when reporting a problem. |

In the examples ([how to get a token](../../concepts/api-conventions.md#get-a-token-for-curl)):

```sh
export LEARN=https://learn.example.org
export TOKEN=eyJhbGciOi...   # access token from Keycloak for the Learn web app's client
```

### Languages

Learner-facing responses (course pages, quizzes, sessions, certificates,
to-dos) are served in the caller's language, chosen in this order:

1. `?lang=nl` on the request;
2. the language saved with [`PUT /api/v1/me/preferences`](#put-apiv1mepreferences);
3. the `Accept-Language` header.

Each course uses the first of these it offers, otherwise its
`default_lang`; missing translations fall back per field to the default
text. Course **staff** get the default text (the text they edit) unless they
pass `?lang=` explicitly, so a translation is never saved over the original.

## Authentication

| Caller | How | Accepted on |
| --- | --- | --- |
| People (production) | `Authorization: Bearer <token>` from Keycloak, audience `learn-api`, verified against `OIDC_ISSUER_URL`. ID tokens are refused. | `/api/v1/…` (except brand) |
| Den's backend | `Authorization: Bearer <Learn's pairing credential>` plus `X-Den-User-Issuer` and `X-Den-User-Subject` | **only** `/api/portal/todos` |
| HR (server to server) | `Authorization: Bearer <LEARN_SERVICE_TOKEN>` | **only** `/api/internal/holdings` |
| Local development (`AUTH_MODE=dev`) | `X-Dev-User: <name>`, `X-Dev-Groups: learn-trainer,…` | everything a person can call |
| Anyone | nothing | probes, catalogs, `/api/public/verify/{code}`, brand |

The first time someone signs in, Learn creates a local user for them, keyed
by token issuer and subject. On every sign-in the token's `groups` are also
applied to courses and paths linked to Keycloak groups (see
[Groups](#keycloak-groups-and-group-sync)).

!!! danger "Dev mode trusts a header"
    With `AUTH_MODE=dev` anyone who can reach the backend can claim any user
    and group. Local use only; see [Authentication](../../concepts/authentication.md).

### Permissions and who may do what

Keycloak groups map to roles (`infra/access-config.toml`); roles carry
permissions:

| Permission | Allows | Default role (Keycloak group) |
| --- | --- | --- |
| `course.manage` | Edit, publish, archive and enrol on **every** course; reset quizzes; link any group; manage learning paths. | `organization_admin` (`learn-admin`) |
| `course.teach` | Create courses; edit and enrol only on courses you **staff**. | `trainer` (`learn-trainer`) |
| `enrol.manage` | Add and remove **learners** on courses you may edit; the people picker (names only). | `learn-admin`, `learn-trainer` |
| `staff.manage` | Add and remove **trainers** on every course; the course-roles list; the people picker with emails. | `learn-admin`, `training_manager` (`learn-manager`) |
| `qualification.manage` | Qualifications, every certificate, revoking certificates. | `learn-admin`, `coordinator` (`learn-coordinator`) |
| `settings.manage` | Module settings, erasure, the audit log, reminders, the Den pairing. | `learn-admin` |
| `report.view` | Completion and qualification reports for the whole organisation. | `learn-admin`, `coordinator` (`learn-coordinator`) |

There is **no learner role**: an **enrolment** on a published course is what
lets a person read it. The tables below use these short names:

| Name | Means |
| --- | --- |
| **signed in** | Any valid token. |
| **staff** | `course.manage` in the course's organisation, or `course.teach` **and** an enrolment with role `trainer` on that course. |
| **enrolled** | An active enrolment (learner or trainer) on a **published** course, or staff. |
| **enrol staff** | `enrol.manage` and staff. |
| **path admin** | `course.manage` in the path's organisation. |

**Hidden, not forbidden.** Someone who is not staff gets `404` for an
unpublished or archived course and everything in it, exactly as if it did
not exist; on a published course they get `403` (`you are not enrolled in
this course`). Paths, certificates and media you may not see also answer
`404`.

**Archived courses are read-only.** Staff can still read an archived course
(`GET`), but every other request on it or its content answers `409` with
code `archived` until it is unarchived.

## Errors

```json
{"error":{"code":"locked","message":"finish Radio basics: intro first","details":{"needs":["Radio basics: intro"]}}}
```

| Status | `code` | Typical cause in Learn |
| --- | --- | --- |
| 400 | `bad_request` | Malformed JSON, unknown field, bad id, `step` not `preview`/`commit`, completing a quiz or session by hand. |
| 401 | `unauthorized` | Missing or invalid token; wrong `LEARN_SERVICE_TOKEN`. |
| 403 | `forbidden` | Missing permission (`missing permission: course.manage`), not enrolled, self-enrolment off. |
| 403 | `locked` | Prerequisites or an earlier course on a sequential path are not done; `details.needs` lists what is missing. |
| 404 | `not_found` | Not there, or hidden from you (see above). |
| 409 | `conflict` | State conflicts: already enrolled, attempts used up, session full or started, question already answered, renewal not open, removing a course's last trainer, retention while Den decides it, erasing someone twice. |
| 409 | `archived` | The course is archived and read-only. |
| 422 | `validation_failed` | Field problems. Learn's messages are full sentences meant to be shown to people. |
| 429 | `rate_limited` | Too many requests; `Retry-After: 60`. Public verify: 30 a minute per address. Per signed-in person per minute: self-enrolment 20, check-in 20, feedback 10, people search 60. |
| 503 | `unavailable` | An optional integration is off: object storage (media) or the group directory (`GROUP_DIRECTORY`, `KEYCLOAK_*`). |
| 500 | `internal` | Unexpected; see the backend log with the request id. |

The Den routes add `pairing_failed` (422) and `sync_failed` (409/502).

## Endpoint overview

**149 endpoints.** Paths below `/api/v1` are written without that prefix in
the section tables.

| Area | Count | Section |
| --- | --- | --- |
| Probes, catalogs, HR, public, portal, Den state | 10 | [Service and public](#service-and-public-routes) |
| Brand, you, people, Den | 15 | [You](#you), [Den](#den-pairing) |
| Courses, sections, activities, enrolments, course roles, archive, rules, copy | 26 | [Courses](#courses) |
| Quizzes, question bank, attempts, gradebook, stats, import | 25 | [Quizzes](#quizzes) |
| In-person sessions | 10 | [Sessions](#in-person-sessions) |
| Media library and page attachments | 11 | [Media](#media) |
| Keycloak groups | 5 | [Groups](#keycloak-groups-and-group-sync) |
| Qualifications and certificates | 9 | [Qualifications](#qualifications-and-certificates) |
| Learning paths | 17 | [Paths](#learning-paths) |
| Team boards, feedback, translations, reports, reminders, settings, erasure, audit log | 21 | [Engagement and admin](#engagement-reports-and-admin) |

---

## Service and public routes

| Method | Path | Who |
| --- | --- | --- |
| GET | `/livez` | anyone |
| GET | `/readyz` | anyone |
| GET | `/api/health` | anyone |
| GET | `/api/role-catalog` | `HR_SERVICE_TOKEN` or a staff sign-in |
| GET | `/api/qualification-catalog` | anyone |
| GET | `/api/internal/holdings?subjects=` | `LEARN_SERVICE_TOKEN` |
| GET | `/api/public/verify/{code}` | anyone, 30 a minute per address |
| GET | `/api/portal/todos` | Den's backend (pairing credential) |
| GET | `/api/den/state` (also `/api/v1/den/state`) | anyone |

### `GET /livez`, `GET /readyz`, `GET /api/health`

`/livez` answers `{"status":"ok"}` without touching the database.
`/readyz` pings PostgreSQL: `{"status":"ok","database":"ok"}`, or `503`
`{"status":"degraded","database":"down"}`. `/api/health` adds the version:

```sh
curl -s $LEARN/api/health
```

```json
{"status":"ok","database":"ok","version":"1.0.0-1","uptime_sec":5400}
```

### `GET /api/den/state`

Anyone. Also at `/api/v1/den/state`. Whether Learn must be paired with Den,
and whether it is. The web app uses this before sign-in to show *Waiting
for Den* or *Connect this module to Den*. `Cache-Control: no-store`.

| Field | Meaning |
| --- | --- |
| `mode` | `standalone` (works without Den) or `required` (the API answers `503 den_pairing_required` until paired). |
| `paired` | `true` when a Den credential is stored. |
| `revoked` | `true` when Den rejected that credential. Pair again. `paired` can still be `true`. |

```sh
curl -s $LEARN/api/den/state
```

```json
{"mode":"required","paired":true,"revoked":false}
```

### `GET /api/role-catalog`

**Who may call it:** HR's backend with `Authorization: Bearer <HR_SERVICE_TOKEN>`
(the same value as on HR, compared in constant time; it allows nothing but
this read), or a person signed in to Learn. Without a token the answer is
`401` `unauthorized`. The path stays open while Learn waits for Den.

The response includes `revision`, also sent as the `ETag`. Send that value
back as `If-None-Match` to get `304` when the list has not changed. `group`
is the normalised group; `group_display` is the group as written in the
access config. `privileged` is true for roles that change settings, see
other people's results or grant access. `dynamic` is false: Learn's roles
are fixed, not created at run time. A role with no group binding has scope
`course` (assigned per course inside Learn) and is not assignable from HR.

```sh
curl -s --cacert /etc/conservices-internal-ca/ca.crt \
  https://learn-backend.conservices-learn.svc.cluster.local:8080/api/role-catalog \
  -H "Authorization: Bearer $HR_SERVICE_TOKEN"
```

```json
{"module":"learn","display_name":"Learn","description":"Courses, enrolments and training progress.",
 "revision":"a1b2c3d4e5f60718",
 "roles":[{"key":"trainer","label":"Trainer","description":"Creates courses and runs the courses they teach.",
           "group":"learn-trainer","group_display":"learn-trainer","assignable":true,"default":false,
           "scope":"organization","privileged":false,"dynamic":false,
           "permissions":["course.teach","enrol.manage"]}]}
```

```json
{"error":{"code":"unauthorized","message":"missing bearer token"}}
```

### `GET /api/qualification-catalog`

Anyone. Every qualification HR can require for a role.

```sh
curl -s --cacert /etc/conservices-internal-ca/ca.crt https://learn-backend.conservices-learn.svc.cluster.local:8080/api/qualification-catalog
```

```json
{"module":"learn","display_name":"Learn",
 "qualifications":[{"key":"first-aid","name":"First aid","description":"Basic first aid at events.","valid_months":24},
                   {"key":"radio","name":"Radio operator","description":"","valid_months":null}]}
```

`valid_months: null` means the qualification never expires.

### `GET /api/internal/holdings`

**Server to server, for HR role gating.** HR can require a qualification
before it grants a role ("only people with *First aid* get *Medic*"). Before
granting, HR asks Learn which **valid** qualifications the people hold.

- **Auth:** `Authorization: Bearer <LEARN_SERVICE_TOKEN>`, the same value
  configured on HR. Compared in constant time. When `LEARN_SERVICE_TOKEN`
  is empty the route answers `404`, as if it did not exist.
- **Query:** `subjects` — comma-separated Keycloak user ids (the token
  `sub`), at most 500, duplicates ignored. They are matched under Learn's
  token issuer (`OIDC_ISSUER_URL`).
- **Valid** means: not revoked and not expired. If someone holds a key
  through several certificates, the latest expiry is reported (`null` =
  never expires).

```sh
curl -s --cacert /etc/conservices-internal-ca/ca.crt "https://learn-backend.conservices-learn.svc.cluster.local:8080/api/internal/holdings?subjects=6f1d2a40-…,9a2b7c11-…" \
  -H "Authorization: Bearer change-me"
```

```json
{"holdings":{"6f1d2a40-…":[{"key":"first-aid","expires_at":"2028-05-01T00:00:00Z"}],"9a2b7c11-…":[]}}
```

Every requested subject appears, with `[]` when they hold nothing (or have
never signed in to Learn).

| Status | When |
| --- | --- |
| `200` | Answered. |
| `400` | `at most 500 subjects per request`. |
| `401` | Missing or wrong token. |
| `404` | `LEARN_SERVICE_TOKEN` is not set: the endpoint is off. |

The token is a secret; see [Secrets](../../operations/secrets.md).

### `GET /api/public/verify/{code}`

Anyone, no sign-in. Checks a certificate from the code printed on it (and in
its QR code). Shows only the holder's display name, the qualification, dates
and status. `Cache-Control: no-store`. Rate limited to **30 requests a
minute per client address**; more answers `429` `rate_limited` with
`Retry-After: 60`.

```sh
curl -s $LEARN/api/public/verify/K7M2Q4XZ9A3B
```

```json
{"display_name":"Sam Example","qualification":"First aid","issued_at":"2026-05-01T10:00:00Z",
 "expires_at":"2028-05-01T00:00:00Z","status":"valid"}
```

`status` is `valid`, `expired` or `revoked`. Unknown code: `404`.

### `GET /api/portal/todos`

Den's backend calls this. It is the suite-wide to-do contract Den's portal
home reads: one person's open work (due courses, upcoming sessions, expiring
certificates), most urgent first. The person's access token is not accepted.
`Cache-Control: private, no-store`.

**Who may call it:** Den, with Learn's pairing credential. The person is
named in the headers, not in the query string. A person who has never
signed in to Learn gets an empty list; Learn does not create a user for
the call.

**Errors:**

| Status | Code | When |
| --- | --- | --- |
| `401` | `unauthorized` | No credential, the wrong one, Learn is not paired, or Den rejected the credential. |
| `400` | `bad_request` | `X-Den-User-Issuer` or `X-Den-User-Subject` is missing, blank, or longer than 512 bytes. |

```sh
curl -s -H "Authorization: Bearer $MODULE_CREDENTIAL" \
  -H "X-Den-User-Issuer: https://auth.example.org/realms/conservices" \
  -H "X-Den-User-Subject: 8f0c2a1e-1b3d-4e5f-9a6b-7c8d9e0f1a2b" \
  $LEARN/api/portal/todos
```

```json
{"items":[
  {"id":"learn:course:2f6c…","title":"Finish Radio basics","detail":"Overdue","due_at":"2026-11-01T00:00:00Z",
   "url":"https://learn.example.org/courses/2f6c…","severity":"danger"},
  {"id":"learn:session:7a10…","title":"First aid practical","detail":"Hall B","due_at":"2026-11-08T10:00:00Z",
   "url":"https://learn.example.org/courses/9e3d…","severity":"info"}]}
```

`severity` is `danger`, `warning` or `info`. `url` is absolute, built on
`PUBLIC_BASE_URL`.

## You

| Method | Path | Who | Notes |
| --- | --- | --- | --- |
| GET | `/brand` | anyone | Brand, Den's once paired. |
| GET | `/brand/{role}` | anyone | `logo` or `login-background` asset; `404` if none. |
| GET | `/me` | signed in | Identity, memberships, permissions. |
| GET | `/me/preferences` | signed in | `theme` (from Den), `language` (Learn). |
| PUT | `/me/preferences` | signed in | Body `{theme?, language?}`. |
| GET | `/me/channels` | signed in | Notification channels. |
| PUT | `/me/channels` | signed in | Body `{telegram_chat_id}`. |
| GET | `/me/qualifications` | signed in | See [Qualifications](#get-apiv1mequalifications). |
| GET | `/me/paths` | signed in | See [Paths](#get-apiv1mepaths). |
| GET | `/me/teams` | signed in | See [Team boards](#team-boards). |
| GET | `/users?q=` | `enrol.manage` or `staff.manage` | People picker for your organizations, at most 20 (plus directory hits). Rate-limited. |

### `GET /api/v1/me`

```sh
curl -s -H "Authorization: Bearer $TOKEN" $LEARN/api/v1/me
```

```json
{"id":"5b1e…","display_name":"Robin Trainer","email":"robin@example.org",
 "issuer":"https://auth.example.org/realms/conservices","subject":"0a1b…",
 "memberships":[{"organization_id":"0f1a…","role":"trainer"}],
 "permissions":["course.teach","enrol.manage"]}
```

Empty `permissions` is normal for learners: they need enrolments, not roles.

### `GET /api/v1/me/preferences`

```json
{"theme":"dark","updated_at":"2026-11-01T18:20:00Z","synced":true,"language":"nl"}
```

`theme` comes from Den (`synced:false` when Learn is not paired or Den is
down); `language` is stored in Learn, `null` = use the browser's.

### `PUT /api/v1/me/preferences`

Body: `theme` (`system`, `light`, `dark`) and/or `language` (a code such as
`nl`; `""` or `null` clears). Answers `200` with the same shape as `GET`.
`422` `theme must be system, light or dark`,
`language must be a language code such as en or nl`.

```sh
curl -s -X PUT $LEARN/api/v1/me/preferences \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"language":"nl"}'
```

### `GET /api/v1/me/channels`, `PUT /api/v1/me/channels`

Where reminders reach you. `PUT` body: `{"telegram_chat_id":"123456789"}`
(`""` removes it). Answers `200` with:

```json
{"email":"robin@example.org","telegram_chat_id":"123456789","email_enabled":true,"telegram_enabled":false}
```

`*_enabled` says whether the server has that channel configured. `422`
`telegram chat id must be a number (e.g. 123456789)`.

### `GET /api/v1/users`

- **Who:** `enrol.manage` or `staff.manage` in at least one organization.
  Learners can never list people (`403`).
- **Query:** `q` — part of a name (also of an email address for callers who
  may see emails).
- **What it searches:** people Learn knows (signed in once, or synced from
  a group) who belong to one of the organizations where you hold one of
  those permissions; erased people never appear. At most 20. With the group
  directory on (`GROUP_DIRECTORY=keycloak` and `KEYCLOAK_*` set) and at
  least two characters, it also asks Keycloak and adds people Learn has
  never seen, with `"id": null` and a `directory_id`; enrol them with
  `directory_id` (see [Enrolments](#enrolments)).
- **Emails** are included only for callers with `course.manage` or
  `staff.manage` in every searched organization. Trainers get names only.
- **Response:** `200` `{"people": [...], "source": "learn" | "learn+directory"}`.
- **Errors:** `403` `missing permission: enrol.manage`; `429`
  `rate_limited` after 60 searches a minute.

```sh
curl -s -H "Authorization: Bearer $TOKEN" "$LEARN/api/v1/users?q=sam"
```

As a training manager:

```json
{"people":[{"id":"6f1d…","display_name":"Sam Example","email":"sam@example.org"},
           {"id":null,"display_name":"Sam Newcomer","email":"sam.n@example.org","directory_id":"8c2e5b4a-…"}],
 "source":"learn+directory"}
```

As a trainer, the same search answers without `email`:

```json
{"people":[{"id":"6f1d…","display_name":"Sam Example"},
           {"id":null,"display_name":"Sam Newcomer","directory_id":"8c2e5b4a-…"}],
 "source":"learn+directory"}
```

!!! note "People from HR"
    When Learn is paired with Den the picker still searches Learn and the
    Keycloak directory. Searching HR's people needs a people endpoint in HR
    that does not exist yet.

## Courses

A **course** has ordered **sections**; each section has ordered
**activities** of kind `page`, `quiz` or `session`. A course starts
**unpublished** (only staff see it). Learners need an **enrolment**.

| Method | Path | Who | Success |
| --- | --- | --- | --- |
| GET | `/courses/mine` | signed in | `200` `{courses}`: your enrolments. |
| GET | `/courses/catalog` | signed in | `200` `{courses}`: published self-enrol courses. |
| GET | `/courses/teach` | `course.teach` or `course.manage` | `200` `{courses}`: courses you staff (all, for `course.manage`); `?archived=true` lists the archived ones instead. |
| POST | `/courses` | `course.teach` or `course.manage` | `201` course; you become its trainer. |
| GET | `/courses/{course}` | enrolled | `200` course detail. |
| PATCH | `/courses/{course}` | staff | `200` course. |
| POST | `/courses/{course}/publish` | staff | `200` course. |
| POST | `/courses/{course}/unpublish` | staff | `200` course. |
| POST | `/courses/{course}/archive` | staff | `200` course with `archived_at`. |
| POST | `/courses/{course}/unarchive` | staff | `200` course with `archived_at: null`. |
| GET | `/course-staff?q=` | `staff.manage` | `200` `{courses}` with their trainers. |
| POST | `/courses/{course}/copy` | staff | `201` the copy. |
| POST | `/courses/{course}/sections` | staff | `201` section. |
| PATCH | `/sections/{section}` | staff | `200` section. |
| DELETE | `/sections/{section}` | staff | `204`; deletes its activities. |
| POST | `/sections/{section}/activities` | staff | `201` activity. |
| PATCH | `/activities/{activity}` | staff | `200` activity. |
| DELETE | `/activities/{activity}` | staff | `204`. |
| PUT | `/activities/{activity}/completion` | enrolled | `200`. |
| PUT | `/activities/{activity}/prerequisites` | staff | `200`. |
| GET | `/courses/{course}/enrolments` | enrol staff, or `staff.manage` | `200` `{enrolments}`. |
| POST | `/courses/{course}/enrolments` | learner: enrol staff; trainer: `staff.manage` | `201` enrolment. |
| POST | `/courses/{course}/enrol` | signed in | `201` enrolment (self-enrol). Rate-limited. |
| PATCH | `/enrolments/{enrolment}` | enrol staff | `200` enrolment (due date). |
| DELETE | `/enrolments/{enrolment}` | learner: enrol staff; trainer: `staff.manage` | `204`; `409` for the last trainer. |
| PUT | `/courses/{course}/qualification` | staff | See [Qualifications](#put-apiv1coursescoursequalification). |

### Course lists

`GET /courses/mine` returns course summaries: the course plus your
`enrolment_role`, `progress` (`{completed, total}` pages), `due_at`,
`overdue`, and `locked`/`needs` when a sequential learning path still holds
the course closed.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $LEARN/api/v1/courses/mine
```

```json
{"courses":[{"id":"2f6c…","organization_id":"0f1a…","title":"Radio basics","summary":"How we use radios.",
  "published":true,"self_enrol":true,"created_at":"2026-10-01T09:00:00Z","updated_at":"2026-10-02T09:00:00Z",
  "default_lang":"en","languages":["en","nl"],"lang":"nl","enrolment_role":"learner",
  "progress":{"total":4,"completed":1},"due_at":"2026-11-20T00:00:00Z","overdue":false,"locked":false}]}
```

### `POST /api/v1/courses`

Body: `title` (required), `summary`, `self_enrol`. The course is created
unpublished in the organisation where you may teach. Answers `201`.

```sh
curl -s -X POST $LEARN/api/v1/courses \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"title":"Radio basics","summary":"How we use radios at the con.","self_enrol":true}'
```

```json
{"id":"2f6c…","organization_id":"0f1a…","title":"Radio basics","summary":"How we use radios at the con.",
 "published":false,"self_enrol":true,"created_by":"5b1e…","created_at":"2026-11-06T12:00:00Z",
 "updated_at":"2026-11-06T12:00:00Z","default_lang":"en","languages":["en"]}
```

`403` without `course.teach`/`course.manage`; `422` `title is required`.

### `GET /api/v1/courses/{course}`

Enrolled. The full course as you see it: `sections[]` each with
`activities[]` (your `completed` flag, quiz `standing`, `prerequisites`,
`locked`/`needs`), your `progress`, `due_days` (course setting),
`due_at`/`overdue` (yours), `awards_qualification` and your renewal `cycle`.
Locked activities hide their body from learners. `403` `locked` while a
sequential path holds the course closed.

```json
{"id":"2f6c…","title":"Radio basics","published":true,"default_lang":"en","languages":["en","nl"],
 "enrolment_role":"learner","progress":{"total":2,"completed":1},"due_days":14,
 "due_at":"2026-11-20T00:00:00Z","overdue":false,
 "awards_qualification":{"id":"a1b2…","key":"radio","name":"Radio operator","valid_months":null},"cycle":1,
 "sections":[{"id":"s1…","course_id":"2f6c…","title":"Basics","position":0,"activities":[
   {"id":"a01…","section_id":"s1…","kind":"page","title":"Channels","body":"<p>Channel 1 is…</p>","position":0,
    "pass_percent":50,"max_attempts":null,"shuffle_options":true,"completed":true,"prerequisites":[],"locked":false},
   {"id":"a02…","section_id":"s1…","kind":"quiz","title":"Check","body":"Ten questions.","position":1,
    "pass_percent":80,"max_attempts":3,"shuffle_options":true,"completed":false,
    "quiz":{"attempts_used":1,"attempts_left":2,"best_score":6,"best_max_score":10,"best_percent":60,
            "passed":false,"open_attempt_id":null},
    "prerequisites":["a01…"],"locked":false}]}]}
```

### `PATCH /api/v1/courses/{course}`

Staff. Any of:

| Field | Notes |
| --- | --- |
| `title`, `summary`, `self_enrol` | `422` `title must not be empty`. |
| `due_days` | Learners are due N days after enrolling; `null` clears. `422` `due_days must be positive (or null for no due date)`. |
| `languages` | Languages offered, at most 20 codes (`en`, `nl`); always includes `default_lang`. |
| `default_lang` | Language of the base text. |

```sh
curl -s -X PATCH $LEARN/api/v1/courses/2f6c… \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"due_days":14,"languages":["en","nl"]}'
```

### `POST …/publish`, `POST …/unpublish`

Staff, no body. Publishing checks every quiz is ready; otherwise `422`
`quiz "Check" is not ready: …`. Answers `200` with the course. Both are
recorded in the [audit log](#audit-log).

### `POST …/archive`, `POST …/unarchive`

- **Who:** staff of the course (`course.manage`, or a trainer on it).
- **Body:** none.
- **What it does:** archiving hides the course from learners, from
  *My courses*, the catalog and the teach list, and makes it read-only:
  every request on it other than `GET` answers `409 archived`. Learners'
  enrolments, attempts and certificates stay. Unarchiving brings it back as
  it was. There is no way to delete a course. Archiving twice keeps the
  first date. Both are audited.
- **Response:** `200` the course; `archived_at` is set while archived.
- **Errors:** `404` for people who can't see the course; `403` for
  enrolled non-staff.

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" $LEARN/api/v1/courses/2f6c…/archive
```

```json
{"id":"2f6c…","organization_id":"0f1a…","title":"Radio basics 2025","summary":"","published":true,
 "self_enrol":false,"created_at":"2025-10-01T09:00:00Z","updated_at":"2026-11-11T16:00:00Z",
 "default_lang":"en","languages":["en"],"archived_at":"2026-11-11T16:00:00Z"}
```

Then, on the archived course:

```sh
curl -s -X PATCH $LEARN/api/v1/courses/2f6c… -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"title":"x"}'
```

```json
{"error":{"code":"archived","message":"this course is archived and read-only; unarchive it to make changes"}}
```

### `GET /api/v1/course-staff`

- **Who:** `staff.manage` (training managers, admins). Others `403`.
- **Query:** `q` filters by course title (optional).
- **Response:** `200` every course of your organizations (archived ones
  included, flagged) with its active trainers. Emails are included.

```sh
curl -s -H "Authorization: Bearer $TOKEN" "$LEARN/api/v1/course-staff?q=radio"
```

```json
{"courses":[{"id":"2f6c…","title":"Radio basics","published":true,"archived":false,
  "trainers":[{"enrolment_id":"e71…","user_id":"5b1e…","display_name":"Robin Trainer","email":"robin@example.org"}]}]}
```

Add a trainer with `POST /courses/{course}/enrolments` and
`"role":"trainer"`; remove one with `DELETE /enrolments/{enrolment_id}`.

### `POST /api/v1/courses/{course}/copy`

Staff of the source. Copies the course for a new edition: content,
prerequisites, question bank and quiz slots, media (sharing the stored
files), languages and translations, feedback and team board settings.
Session activities are copied without their time slots. The copy is
unpublished and has no learner data (enrolments, attempts, completions,
certificates); you become its trainer. Body:
`title` (the new title), `include_group_links` (also copy the Keycloak group
links). Answers `201` with the new course.

```sh
curl -s -X POST $LEARN/api/v1/courses/2f6c…/copy \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"title":"Radio basics 2027","include_group_links":true}'
```

### Sections and activities

- `POST /courses/{course}/sections` body `{"title":"Basics"}` → `201`
  `{id, course_id, title, position}`; `422` `title is required`.
- `PATCH /sections/{section}` body `{title?, position?}` → `200` section.
- `POST /sections/{section}/activities` body:

  | Field | Notes |
  | --- | --- |
  | `kind` | `page` (default), `quiz` or `session`. |
  | `title` | Required. |
  | `body` | Page HTML, or the quiz/session intro. |
  | `pass_percent` | Quizzes, `0`–`100`, default `50`. |
  | `max_attempts` | Quizzes, positive; leave out for unlimited. |
  | `shuffle_options` | Quizzes, default `true`. |

- `PATCH /activities/{activity}` takes `title`, `body`, `position`,
  `pass_percent`, `max_attempts` (`null` = unlimited again),
  `shuffle_options`.

```sh
curl -s -X POST $LEARN/api/v1/sections/s1…/activities \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"kind":"quiz","title":"Check","body":"Ten questions.","pass_percent":80,"max_attempts":3}'
```

### `PUT /api/v1/activities/{activity}/completion`

Enrolled. Marks a **page** done or not done for you: body
`{"completed":true}`. Answers `200` `{"activity_id":"a01…","completed":true}`.
Quizzes complete by passing an attempt and sessions by attending (`400`
otherwise). `403` `locked` when its prerequisites are not done.

### `PUT /api/v1/activities/{activity}/prerequisites`

Staff. Replaces what must be complete before this activity opens: body
`{"requires":["a01…"]}` (activities of the same course; `[]` clears). Answers
`200` `{"activity_id":"…","prerequisites":["a01…"]}`. `422` for self-reference,
another course, or a loop.

### Enrolments

The enrolment object:

```json
{"id":"e7c1…","course_id":"2f6c…","user_id":"6f1d…","role":"learner","display_name":"Sam Example",
 "email":"sam@example.org","created_at":"2026-11-06T12:00:00Z","progress":{"total":4,"completed":1},
 "source":"manual","status":"active","left_group_at":null,"due_at":"2026-11-20T12:00:00Z","overdue":false}
```

`source` is `manual` or `group` (created by group sync). `status: inactive`
means they left the synced group: no access, progress kept, rejoining
reactivates. `email` is left out for callers without `course.manage` or
`staff.manage` (trainers).

**Who may change what.** Learners are added and removed by **enrol staff**
(`enrol.manage` and staff of the course). The trainer role is added and
removed only with **`staff.manage`** (training managers, admins), who need
no edit rights on the course. A trainer trying it gets `403` `only a
training manager (staff.manage) can make someone a trainer`. The last
active trainer of a course can never be removed. Every change is
[audited](#audit-log). Archived courses answer `409 archived`.

- `POST /courses/{course}/enrolments` body `{"user_id":"6f1d…","role":"learner"}`
  or `{"directory_id":"8c2e5b4a-…","role":"learner"}` for someone the
  [people picker](#get-apiv1users) found only in the directory (Learn
  creates them). `role` is `learner` (default) or `trainer`; enrolling an
  active learner as `trainer` makes them a trainer (same enrolment, `201`).
  Errors: `409` `this person is already enrolled`; `404` `user not found`
  (unknown, or not in the course's organization); `404` `person in the
  directory not found`; `422` `give user_id or directory_id, not both`, or
  `the group directory is off; pick someone who has signed in to Learn`.
- `POST /courses/{course}/enrol`, no body: self-enrol as a learner. `403`
  `this course does not allow self-enrolment` unless published with
  `self_enrol` (and not archived). `429` after 20 a minute.
- `PATCH /enrolments/{enrolment}` body `{"due_at":"2026-12-01T00:00:00Z"}`
  or `{"due_at":null}`: override one learner's due date. `422`
  `nothing to change (give due_at)`.
- `DELETE /enrolments/{enrolment}` → `204`. `409` `this is the course's last
  trainer; add another trainer first`.

```sh
curl -s -X POST $LEARN/api/v1/courses/2f6c…/enrolments \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"user_id":"6f1d…","role":"learner"}'
```

A training manager makes someone a trainer:

```sh
curl -s -X POST $LEARN/api/v1/courses/2f6c…/enrolments \
  -H "Authorization: Bearer $MANAGER_TOKEN" -H "Content-Type: application/json" \
  -d '{"user_id":"6f1d…","role":"trainer"}'
```

```json
{"id":"e7c1…","course_id":"2f6c…","user_id":"6f1d…","role":"trainer","display_name":"Sam Example",
 "email":"sam@example.org","created_at":"2026-11-06T12:00:00Z","progress":{"total":0,"completed":0},
 "source":"manual","status":"active","left_group_at":null,"due_at":null,"overdue":false}
```

Removing the last trainer:

```sh
curl -s -X DELETE -H "Authorization: Bearer $MANAGER_TOKEN" $LEARN/api/v1/enrolments/e71…
```

```json
{"error":{"code":"conflict","message":"this is the course's last trainer; add another trainer first"}}
```

## Quizzes

A quiz activity draws questions from the course's **question bank**
(questions grouped into **categories**). Its **slots** say which questions it
asks: one fixed question, or N random questions from a category. Question
kinds: `single` (one correct option), `multiple` (one or more), `hotspot`
(tap the right places on a picture).

| Method | Path | Who | Success |
| --- | --- | --- | --- |
| GET | `/courses/{course}/question-categories` | staff | `200` `{categories}` |
| POST | `/courses/{course}/question-categories` | staff | `201` category (`{name}`) |
| PATCH | `/question-categories/{category}` | staff | `200` (`{name?, position?}`) |
| DELETE | `/question-categories/{category}` | staff | `204`; `409` if its questions appear in attempts |
| GET | `/question-categories/{category}/questions` | staff | `200` `{questions}` |
| POST | `/question-categories/{category}/questions` | staff | `201` question |
| PATCH | `/questions/{question}` | staff | `200` question |
| DELETE | `/questions/{question}` | staff | `204`; `409` if it appears in attempts |
| PUT | `/questions/{question}/regions` | staff | `200` question (hotspot regions) |
| POST | `/questions/{question}/options` | staff | `201` the whole question |
| PATCH | `/options/{option}` | staff | `200` the whole question |
| DELETE | `/options/{option}` | staff | `200` the whole question |
| GET | `/activities/{activity}/slots` | staff | `200` `{slots, problems}` |
| POST | `/activities/{activity}/slots` | staff | `201` slot |
| PATCH | `/slots/{slot}` | staff | `200` slot (`{position?, draw_count?}`) |
| DELETE | `/slots/{slot}` | staff | `204` |
| GET | `/activities/{activity}/quiz` | enrolled | `200` quiz info and your standing |
| POST | `/activities/{activity}/attempts` | enrolled | `201` new attempt, `200` your open one |
| POST | `/activities/{activity}/reset` | `course.manage` | `200` `{"attempts":N,"completions":N}`: reset the current cycle (see [Resetting a quiz](#resetting-a-quiz)) |
| GET | `/attempts/{attempt}` | its owner, or staff | `200` attempt |
| POST | `/attempts/{attempt}/submit` | its owner | `200` graded attempt |
| GET | `/courses/{course}/gradebook` | staff | `200` gradebook |
| GET | `/courses/{course}/question-stats` | staff | `200` `{questions}` |
| POST | `/courses/{course}/question-import?step=preview\|commit` | staff | `200` preview or result |
| GET | `/question-import/csv-template` | signed in | `200` CSV file |

### `POST /api/v1/question-categories/{category}/questions`

| Field | Notes |
| --- | --- |
| `kind` | `single`, `multiple` or `hotspot`. |
| `prompt` | Required. |
| `feedback` | Shown after submitting. |
| `points` | Positive, default `1`. |
| `options` | `single`/`multiple`: at least two, each `{label, correct, media_id?}`; single needs exactly one correct. |
| `media_id`, `feedback_media_id` | Pictures from the course [media library](#media) (images need alt text). A hotspot question needs `media_id`. |
| `hotspot_clicks` | Hotspot: how many taps a learner gets (at least one per correct region). |
| `regions` | Hotspot: `[{shape, coords, correct}]`, coordinates `0`–`1` of the image from the top left: `rect` `{x,y,w,h}`, `circle` `{cx,cy,r}` or `{cx,cy,rx,ry}`. |

```sh
curl -s -X POST $LEARN/api/v1/question-categories/c9a0…/questions \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"kind":"single","prompt":"Which channel is for emergencies?","points":1,
       "options":[{"label":"Channel 1","correct":true},{"label":"Channel 5","correct":false}]}'
```

```json
{"id":"q11…","category_id":"c9a0…","kind":"single","prompt":"Which channel is for emergencies?","feedback":"",
 "points":1,"position":0,"created_at":"2026-11-06T12:00:00Z","updated_at":"2026-11-06T12:00:00Z","locked":false,
 "options":[{"id":"o1…","question_id":"q11…","label":"Channel 1","correct":true,"position":0,"media_id":null},
            {"id":"o2…","question_id":"q11…","label":"Channel 5","correct":false,"position":1,"media_id":null}],
 "media_id":null,"feedback_media_id":null,"hotspot_clicks":null,"regions":[]}
```

`locked: true` means the question was answered in a submitted attempt: its
kind, image, taps and options can no longer change (`409`) until staff
reset the quiz. `PATCH /questions/{question}` takes `kind`, `prompt`,
`feedback`, `points`, `position`, and `media_id`, `feedback_media_id`,
`hotspot_clicks` (each `null` clears).

### Slots

`POST /activities/{activity}/slots` body: either `{"question_id":"q11…"}`
or `{"category_id":"c9a0…","draw_count":5}`. `GET …/slots` also returns
`problems`, the reasons the quiz cannot be taken yet (`[]` when ready):

```json
{"slots":[{"id":"sl1…","activity_id":"a02…","position":0,"question_id":null,"category_id":"c9a0…",
           "draw_count":5,"category_name":"Radio"}],
 "problems":[]}
```

### Taking a quiz

1. `GET /activities/{activity}/quiz` — title, intro, `pass_percent`,
   `max_attempts`, `question_count`, your `standing` and past `attempts`.
2. `POST /activities/{activity}/attempts` — starts an attempt (`201`), or
   returns your open one (`200`). `409`
   `you have used all your attempts on this quiz`, `this quiz has no questions yet`;
   `403` `locked`.
3. `POST /attempts/{attempt}/submit` with your answers; the graded attempt
   comes back.

```sh
curl -s -X POST $LEARN/api/v1/attempts/at5…/submit \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"answers":{"q11…":["o1…"]},"taps":{"q12…":[{"x":0.42,"y":0.31}]}}'
```

```json
{"id":"at5…","activity_id":"a02…","user_id":"6f1d…","started_at":"2026-11-06T12:00:00Z",
 "submitted_at":"2026-11-06T12:04:00Z","score":2,"max_score":2,"percent":100,"passed":true,"pass_percent":80,
 "questions":[{"question_id":"q11…","position":0,"kind":"single","prompt":"Which channel is for emergencies?",
   "points":1,"options":[{"id":"o2…","label":"Channel 5"},{"id":"o1…","label":"Channel 1"}],
   "chosen_option_ids":["o1…"],"correct":true,"points_awarded":1,"correct_option_ids":["o1…"],"feedback":""}]}
```

Before submitting, `correct`, `points_awarded`, `correct_option_ids`,
`feedback` and hotspot `regions` are left out. `409`
`this attempt has already been submitted`; `422` when an answer refers to a
question or option not in the attempt.

### Resetting a quiz

`POST /api/v1/activities/{activity}/reset`

- **Who:** `course.manage` in the course's organization. Trainers get
  `403` `only course managers (course.manage) can reset a quiz`.
- **Body:** `{"confirm": "<the quiz's title>"}`, typed exactly (spaces at
  the ends don't matter). Anything else answers `422` with
  `details.expected` = the title.
- **What it does:** deletes, for every learner, the attempts of their
  **current cycle** plus any open attempt, and their completion of the quiz
  in that cycle. Earlier cycles and every certificate already issued stay,
  so questions used by earlier attempts stay locked for editing. The reset
  is recorded in the [audit log](#audit-log) (`quiz.reset`, with the
  counts). Archived courses answer `409 archived`.
- **Response:** `200` `{"attempts": N, "completions": N}`.

```sh
curl -s -X POST $LEARN/api/v1/activities/a02…/reset \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"confirm":"Check"}'
```

```json
{"attempts":12,"completions":7}
```

### Gradebook and statistics

`GET /courses/{course}/gradebook` — one row per learner with each quiz's
attempts, best percent and pass state, plus due date and progress:

```json
{"quizzes":[{"activity_id":"a02…","title":"Check","pass_percent":80,"max_attempts":3}],
 "rows":[{"user_id":"6f1d…","display_name":"Sam Example","email":"sam@example.org",
          "cells":[{"activity_id":"a02…","attempts":2,"best_percent":100,"passed":true,"in_progress":false}],
          "due_at":"2026-11-20T12:00:00Z","overdue":false,"progress":{"total":2,"completed":2}}]}
```

`GET /courses/{course}/question-stats` — per question: `attempts`,
`correct`, `percent_correct`, option `picks`, and for hotspots region `hits`,
`hit_rate`, `taps`, `miss_taps`.

### Question import

`POST /courses/{course}/question-import?step=preview` then `?step=commit`,
as `multipart/form-data`:

| Field | Notes |
| --- | --- |
| `file` | Required, at most 32 MB. |
| `format` | `moodle_xml`, `gift`, `aiken` or `csv`; detected when left out. |
| `category_id` | Commit only: the category to import into (same course). |

The preview saves nothing; send the same file again to commit. Embedded
Moodle images are stored in the media library when object storage is on,
otherwise skipped with a warning.

```sh
curl -s -X POST "$LEARN/api/v1/courses/2f6c…/question-import?step=preview" \
  -H "Authorization: Bearer $TOKEN" -F "file=@questions.gift"
```

```json
{"format":"gift","questions":[{"index":0,"kind":"single","prompt":"Which channel is for emergencies?",
  "feedback":"","points":1,"options":[{"label":"Channel 1","correct":true},{"label":"Channel 5","correct":false}],
  "images":[]}],"warnings":[]}
```

Commit (`-F "category_id=c9a0…"`) answers
`{"format":"gift","imported":12,"skipped":1,"images":0,"warnings":[{"index":7,"message":"…"}]}`.
`GET /question-import/csv-template` downloads the CSV layout.

## In-person sessions

A **session** activity has dated **slots** with a capacity. Learners book a
slot (or join its waitlist), then **check in** at the venue by scanning a
rotating QR code; attending completes the activity.

| Method | Path | Who | Success |
| --- | --- | --- | --- |
| GET | `/activities/{activity}/session` | enrolled | `200` slots and your booking |
| POST | `/activities/{activity}/session-slots` | staff | `201` slot |
| PATCH | `/session-slots/{slot}` | staff | `200` slot |
| DELETE | `/session-slots/{slot}` | staff | `204` |
| POST | `/slots/{slot}/booking` | enrolled | `201` booked or waitlisted, `200` already yours |
| DELETE | `/slots/{slot}/booking` | enrolled | `204` |
| GET | `/slots/{slot}/checkin-code` | staff | `200` current QR code |
| POST | `/slots/{slot}/checkin` | enrolled | `200` check-in result |
| GET | `/slots/{slot}/roster` | staff | `200` roster |
| PUT | `/signups/{signup}` | staff | `200` signup (`{status}`) |

Session slots are **edited** under `/session-slots/{slot}` (because
`/slots/{slot}` is the quiz-slot route) but **booked** under
`/slots/{slot}/…`.

```sh
curl -s -X POST $LEARN/api/v1/activities/a03…/session-slots \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"starts_at":"2026-11-08T10:00:00Z","ends_at":"2026-11-08T12:00:00Z","location":"Hall B","capacity":12}'
```

```json
{"id":"7a10…","activity_id":"a03…","starts_at":"2026-11-08T10:00:00Z","ends_at":"2026-11-08T12:00:00Z",
 "location":"Hall B","capacity":12,"booked":0,"waitlist":0,"seats_left":12}
```

`422` `starts_at and ends_at are required`,
`the session must end after it starts`, `capacity must be at least 1`.

**Booking** answers a signup `{id, slot_id, activity_id, user_id, status,
walk_in, created_at, waitlist_position?}` with `status` `booked` or
`waitlist`. `409` when you hold another time of the same session, the
session already started, or you already attended. Cancelling after the start
or after attendance was recorded: `409`.

**Check-in.** Staff show `GET /slots/{slot}/checkin-code`:

```json
{"code":"K3M7QX2A","expires_at":"2026-11-08T09:58:30Z","url":"https://learn.example.org/checkin/7a10…?code=K3M7QX2A","window_seconds":30}
```

The code rotates every 30 seconds (the previous one stays valid for one more
step). Learners scan the QR code, which opens `url`; the web app then posts
the code: `POST /slots/{slot}/checkin` `{"code":"K3M7QX2A"}`.
Check-in opens 30 minutes before the start and closes at the end. People
without a booking are checked in as **walk-ins** while seats are left.

```json
{"signup":{"id":"sg1…","slot_id":"7a10…","activity_id":"a03…","user_id":"6f1d…","status":"attended",
           "walk_in":false,"created_at":"2026-11-01T09:00:00Z"},
 "slot":{"id":"7a10…","activity_id":"a03…","starts_at":"2026-11-08T10:00:00Z","ends_at":"2026-11-08T12:00:00Z",
         "location":"Hall B","capacity":12,"booked":9,"waitlist":0,"seats_left":3},
 "course_id":"9e3d…","activity_title":"First aid practical","already_attended":false}
```

`400` `this check-in code is not valid any more; scan the QR code again`;
`409` outside the window or when full; `429` `rate_limited` after 20
check-ins a minute by one person.

**Roster and attendance.** `GET /slots/{slot}/roster` lists signups with
names; `PUT /signups/{signup}` `{"status":"attended"|"no_show"|"booked"}`
corrects attendance by hand. Every change is recorded in the
[audit log](#audit-log) (`session.signup_status`).

## Media

The **media library** holds a course's pictures, audio and video in an
S3-compatible bucket. The browser uploads **directly to storage** with a
presigned form; the backend never sees the bytes. Without `S3_ENDPOINT`
these routes answer `503` `unavailable`.

| Method | Path | Who | Success |
| --- | --- | --- | --- |
| GET | `/courses/{course}/media?filter=unused` | staff | `200` `{media}` |
| POST | `/courses/{course}/media/uploads` | staff | `201` upload ticket |
| POST | `/media/{media}/complete` | staff | `200` media |
| GET | `/media/{media}` | staff, or enrolled learners who can see it | `302` to a 5-minute link |
| GET | `/media/{media}/url` | same | `200` `{url, expires_at}` |
| PATCH | `/media/{media}` | staff | `200` media (`{alt_text?, name?}`) |
| DELETE | `/media/{media}` | staff | `204`; `409` while in use |
| GET | `/activities/{activity}/media` | enrolled | `200` `{attachments}` |
| POST | `/activities/{activity}/media` | staff | `201` attachment |
| PATCH | `/activity-media/{attachment}` | staff | `200` (`{caption?, position?}`) |
| DELETE | `/activity-media/{attachment}` | staff | `204` |

Accepted types and limits: images `png`, `jpeg`, `webp`, `gif` up to 10 MB;
audio `mpeg`/`mp3`, `mp4`/`m4a`, `ogg` up to 20 MB; video `mp4`, `webm` up to
200 MB. Images need **alt text** before they can be used.

**Upload in three steps:**

```sh
# 1. Ask for an upload ticket
curl -s -X POST $LEARN/api/v1/courses/2f6c…/media/uploads \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"filename":"radio.jpg","content_type":"image/jpeg","size_bytes":183422,"alt_text":"A handheld radio"}'
```

```json
{"media":{"id":"m1…","course_id":"2f6c…","kind":"image","content_type":"image/jpeg","size_bytes":183422,
          "status":"pending","alt_text":"A handheld radio","name":"radio.jpg","created_at":"…","updated_at":"…",
          "usage_count":0,"unused":true,"upload_unfinished":false},
 "url":"https://s3.example.org/learn-data","fields":{"key":"…","policy":"…","x-amz-signature":"…"},
 "expires_at":"2026-11-06T12:15:00Z"}
```

```sh
# 2. Upload the file to storage with the returned fields (valid 15 minutes)
curl -s -X POST "https://s3.example.org/learn-data" -F key=… -F policy=… -F x-amz-signature=… -F file=@radio.jpg
# 3. Tell Learn it arrived
curl -s -X POST -H "Authorization: Bearer $TOKEN" $LEARN/api/v1/media/m1…/complete
```

Step 3 reads the first bytes of the stored file and checks they really are
the announced type (a PNG starts with the PNG signature, and so on). It
answers the media with `"status":"ready"`; `409` `the file hasn't arrived in
storage yet`. When the stored size, type or contents don't match it answers
`422` and **deletes the upload** (object and library entry), so the file has
to be uploaded again:

```json
{"error":{"code":"validation_failed","message":"the file's contents are not a image/jpeg file; the upload was removed, upload the file again"}}
```

Uploads that are never completed are deleted automatically 24 hours after
the ticket was issued.

**Page attachments.** `POST /activities/{activity}/media` (pages only) body
`{"media_id":"m1…","caption":"…"}` or
`{"external_url":"https://www.youtube.com/watch?v=…","caption":"…"}`; only
YouTube and Vimeo links can be embedded. The attachment comes back with
`embed_url` and `provider` for external videos.

## Keycloak groups and group sync

A course or path can be **linked to a Keycloak group**, named by its **full
path** (for example `/learn/cohort-a`): every member is enrolled
automatically. Learn keeps links up to date in two ways:

- **At sign-in**, from the `groups` claim in the person's token (always on).
  The claim must carry full paths: in Keycloak, the client's groups mapper
  needs **Full group path** on. A top-level group matches either way
  (`/staff` and `staff` are the same), a nested one only by full path.
- **Every 5 minutes** and on "Sync now", by reading group members from the
  Keycloak admin API with the read-only client `learn-provisioner`. This
  needs `GROUP_DIRECTORY=keycloak` (the default) and all four `KEYCLOAK_*`
  settings ([Configuration](configuration.md)); otherwise the routes marked
  503 below answer `the group directory is off or not configured
  (GROUP_DIRECTORY, KEYCLOAK_*)` and `directory` says which.

Group paths compare ignoring case and the leading `/`. Each link has a
`group_name` (that comparison form, `learn/cohort-a`; use it to unlink) and a
`group_path` (as the directory spells it, `/learn/Cohort-A`). A link made by
plain name before Learn used paths has `path_resolved: false` until the
start-up lookup found its path; when the name is missing or used by several
groups, `last_sync_error` says so and the link should be made again by full
path.

**Which groups trainers may link.** `LEARN_LINKABLE_GROUPS` (default
`/learn/*`) lists the groups trainers may see and link; holders of
`course.manage` may link any group. Path links need `course.manage` anyway.

Members who leave every linked group become `inactive` (never deleted;
progress is kept). Linking and unlinking are [audited](#audit-log).

| Method | Path | Who | Success |
| --- | --- | --- | --- |
| GET | `/groups` | `course.manage` or `course.teach` | `200` `{groups:[{id,name,path}], limited, linkable}`; 503 without a directory |
| GET | `/courses/{course}/group-links` | enrol staff | `200` `{links, sync_available, directory}` |
| POST | `/courses/{course}/group-links` | enrol staff | `201` `{link, sync, sync_error?}` |
| DELETE | `/courses/{course}/group-links?group=PATH` | enrol staff | `200` `{deactivated}` |
| POST | `/courses/{course}/group-links/sync` | enrol staff | `200` sync result; 503 without a directory |

Path links use the same shapes under `/paths/{path}/group-links` (path
admin), listed with [Paths](#learning-paths).

### `GET /api/v1/groups`

A trainer only gets the groups `LEARN_LINKABLE_GROUPS` allows (`limited:
true`, `linkable` lists the patterns); `course.manage` gets every group
(`limited: false`).

```sh
curl -s -H "Authorization: Bearer $TOKEN" $LEARN/api/v1/groups
```

```json
{"groups":[{"id":"1c9e…","name":"cohort-a","path":"/learn/cohort-a"},
           {"id":"77d0…","name":"radio","path":"/learn/radio"}],
 "limited":true,"linkable":["/learn/*"]}
```

### `POST /api/v1/courses/{course}/group-links`

Body: `{"group_path": "/learn/cohort-a"}` (the older field name
`group_name` is read as a path too).

```sh
curl -s -X POST $LEARN/api/v1/courses/2f6c…/group-links \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"group_path":"/learn/cohort-a"}'
```

```json
{"link":{"course_id":"2f6c…","group_name":"learn/cohort-a","group_path":"/learn/cohort-a","path_resolved":true,
         "created_at":"2026-11-06T12:00:00Z","last_synced_at":"2026-11-06T12:00:01Z","last_sync_error":"",
         "members":14,"active":14},
 "sync":{"courses":1,"groups":1,"members":14,"users_created":3,"enrolled":14,"reactivated":0,"deactivated":0,"errors":[]}}
```

Errors:

| Status | Message | When |
| --- | --- | --- |
| `403` | `trainers may only link the groups set in LEARN_LINKABLE_GROUPS (/learn/*)` | A trainer picked a group outside the patterns. |
| `422` | `group_path is required (the group's full path, e.g. /learn/cohort-a)` | Empty body. |
| `422` | `there is no group at /learn/nope in the directory; give the full path, e.g. /learn/cohort-a` | With a directory, the path does not exist. |
| `409` | `this group is already linked to the course` | Linked before. |

Without a directory the link is made as given and members are enrolled as
they sign in. If the first sync fails, the link is still made and
`sync_error` says to try **Sync now**.

```sh
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" \
  "$LEARN/api/v1/courses/2f6c…/group-links?group=/learn/cohort-a"
```

```json
{"deactivated":3}
```

## Qualifications and certificates

A **qualification** (for example *First aid*) is earned by finishing a
course or path that awards it. Each award issues a **certificate** with a
public verify code; it can expire (`valid_months`) and be renewed, or be
revoked.

| Method | Path | Who | Success |
| --- | --- | --- | --- |
| GET | `/qualifications` | `qualification.manage`, `course.manage` or `course.teach` | `200` `{qualifications}` |
| POST | `/qualifications` | `qualification.manage` | `201` qualification |
| PATCH | `/qualifications/{qualification}` | `qualification.manage` | `200` |
| DELETE | `/qualifications/{qualification}` | `qualification.manage` | `204`; `409` once certificates exist |
| GET | `/qualifications/{qualification}/certificates` | `qualification.manage` | `200` `{qualification, certificates}` |
| PUT | `/courses/{course}/qualification` | staff | `200` |
| POST | `/courses/{course}/renew` | learner on the published course | `200` `{course_id, cycle, due_at}` |
| GET | `/me/qualifications` | signed in | `200` `{qualifications}` |
| GET | `/certificates/{certificate}` | holder, `qualification.manage`/`course.manage`, awarding course staff | `200`; others `404` |
| POST | `/certificates/{certificate}/revoke` | `qualification.manage` | `200` certificate |

### `POST /api/v1/qualifications`

| Field | Notes |
| --- | --- |
| `key` | Required, unique: lowercase letters, digits, `-`, `_`, `.` (`first-aid`). HR stores role requirements by this key. |
| `name` | Required. |
| `description` | |
| `valid_months` | `1`–`1200`; `null` = never expires. |

```sh
curl -s -X POST $LEARN/api/v1/qualifications \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"key":"first-aid","name":"First aid","valid_months":24}'
```

```json
{"id":"a1b2…","organization_id":"0f1a…","key":"first-aid","name":"First aid","description":"",
 "valid_months":24,"created_at":"2026-11-06T12:00:00Z","updated_at":"2026-11-06T12:00:00Z","courses":0,"certificates":0}
```

`409` `a qualification with this key already exists`.

### `PUT /api/v1/courses/{course}/qualification`

Staff. Body `{"qualification_id":"a1b2…"}` or `{"qualification_id":null}`.
Answers `{"course_id":"2f6c…","awards_qualification":{"id":"a1b2…","key":"first-aid","name":"First aid","valid_months":24}}`.

### `GET /api/v1/me/qualifications`

Your latest certificate per qualification, with renewal state:

```json
{"qualifications":[{"id":"ce1…","user_id":"6f1d…","display_name":"Sam Example","organization_id":"0f1a…",
  "qualification_id":"a1b2…","qualification_key":"first-aid","qualification_name":"First aid",
  "qualification_description":"","course_id":"9e3d…","course_title":"First aid","cycle":1,
  "issued_at":"2026-05-01T10:00:00Z","expires_at":"2028-05-01T00:00:00Z","verify_code":"K7M2Q4XZ9A3B",
  "revoked_at":null,"revoked_reason":"","status":"valid","expiring_soon":false,
  "verify_url":"https://learn.example.org/verify/K7M2Q4XZ9A3B",
  "renewable_from":"2028-03-02T00:00:00Z","renewable":false,"renewal_in_progress":false}]}
```

Renewal opens 60 days before expiry; `expiring_soon` is true in the last 30
days. `POST /courses/{course}/renew` starts a new cycle on the course; `409`
`renewal opens on 2 Mar 2028`, `this qualification does not expire`, or
`there is nothing to renew yet: finish the course first`.

### `POST /api/v1/certificates/{certificate}/revoke`

`qualification.manage`. Body `{"reason":"Issued in error"}` (required). The
certificate's status becomes `revoked`; the public verify page and HR
holdings stop counting it. `409` `this certificate is already revoked`.

## Learning paths

A **learning path** is an ordered bundle of courses; **sequential** paths
unlock each course only after the previous one is done. Finishing every
course can award a qualification.

| Method | Path | Who | Success |
| --- | --- | --- | --- |
| GET | `/me/paths` | signed in | `200` `{paths, available}` |
| GET | `/paths` | `course.manage` | `200` `{paths}` |
| POST | `/paths` | `course.manage` | `201` path |
| GET | `/paths/{path}` | path admin | `200` path |
| PATCH | `/paths/{path}` | path admin | `200` path |
| DELETE | `/paths/{path}` | path admin | `204` |
| PUT | `/paths/{path}/courses` | path admin | `200` path (`{course_ids:[…]}` replaces the order) |
| POST | `/paths/{path}/courses` | path admin | `201` path (`{course_id}` appends); `409` if already on it |
| DELETE | `/paths/{path}/courses/{course}` | path admin | `200` path |
| GET | `/paths/{path}/enrolments` | path admin | `200` `{enrolments}` |
| POST | `/paths/{path}/enrolments` | path admin | `201` (`{user_id}`) |
| POST | `/paths/{path}/enrol` | signed in | `201` (self-enrol) |
| DELETE | `/path-enrolments/{enrolment}` | path admin | `204` |
| GET | `/paths/{path}/group-links` | path admin | `200` `{links, sync_available}` |
| POST | `/paths/{path}/group-links` | path admin | `201` `{link, sync, sync_error?}` |
| DELETE | `/paths/{path}/group-links?group=NAME` | path admin | `200` `{deactivated}` |
| POST | `/paths/{path}/group-links/sync` | path admin | `200`; 503 without sync |

Body for create and update: `name` (required on create), `description`,
`sequential`, `self_enrol`, `awards_qualification_id` (`null` clears).

```sh
curl -s -X POST $LEARN/api/v1/paths \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"Medic onboarding","sequential":true,"awards_qualification_id":"a1b2…"}'
curl -s -X PUT $LEARN/api/v1/paths/p1…/courses \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"course_ids":["9e3d…","2f6c…"]}'
```

```json
{"id":"p1…","organization_id":"0f1a…","name":"Medic onboarding","description":"","sequential":true,"self_enrol":false,
 "awards_qualification_id":"a1b2…","awards_qualification":{"id":"a1b2…","key":"first-aid","name":"First aid","valid_months":24},
 "created_at":"…","updated_at":"…","active_enrolments":0,
 "courses":[{"course_id":"9e3d…","title":"First aid","published":true,"position":0},
            {"course_id":"2f6c…","title":"Radio basics","published":true,"position":1}]}
```

Enrolling someone on a path enrols them on all its courses. Path enrolments
carry `source`, `status`, `cycle`, `courses_done`, `courses_total`,
`complete`. `403` `this path does not allow self-enrolment` on
`POST /paths/{path}/enrol` unless `self_enrol` is on; `409`
`this person is already on the path`.

### `GET /api/v1/me/paths`

Signed in. Your paths, each course with your `progress`, `complete`, and
`locked`/`needs` on sequential paths, plus `available`: self-enrol paths you
can still join.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $LEARN/api/v1/me/paths
```

```json
{"paths":[{"id":"p1…","name":"Medic onboarding","description":"","sequential":true,"source":"manual",
  "awards_qualification":{"id":"a1b2…","key":"first-aid","name":"First aid","valid_months":24},
  "courses":[{"course_id":"9e3d…","title":"First aid","published":true,"position":0,
              "progress":{"total":3,"completed":3},"complete":true,"locked":false},
             {"course_id":"2f6c…","title":"Radio basics","published":true,"position":1,
              "progress":{"total":4,"completed":0},"complete":false,"locked":false}],
  "courses_done":1,"courses_total":2,"complete":false,"certificate_id":null}],
 "available":[]}
```

## Engagement, reports and admin

### Team boards

Team boards show **per-group completion counts, never names**. Groups with
fewer than 3 members show `"hidden_reason":"too_small"` instead of numbers.

| Method | Path | Who |
| --- | --- | --- |
| GET | `/courses/{course}/team-board` | staff; enrolled people when enabled (else `404`) |
| GET | `/courses/{course}/team-board/settings` | staff |
| PUT | `/courses/{course}/team-board/settings` | staff, body `{enabled?, groups?}` (at most 50 groups) |
| GET | `/qualifications/{qualification}/team-board` | `settings.manage`/`course.manage`; holders and people on awarding courses when enabled |
| GET | `/qualifications/{qualification}/team-board/settings` | `settings.manage` |
| PUT | `/qualifications/{qualification}/team-board/settings` | `settings.manage` |
| GET | `/me/teams` | signed in: your groups on enabled boards, `{teams:[…]}` |

```json
{"target_type":"course","target_id":"2f6c…","title":"Radio basics","enabled":true,
 "groups":[{"group_name":"volunteers-radio","members_count":14,"complete_count":9,"percent":64},
           {"group_name":"stage-crew","members_count":null,"complete_count":null,"percent":null,"hidden_reason":"too_small"}]}
```

### Feedback

| Method | Path | Who | Notes |
| --- | --- | --- | --- |
| GET | `/courses/{course}/feedback` | staff | Settings plus averages and comments for the course and each session. |
| PUT | `/courses/{course}/feedback-settings` | staff | `{enabled?, anonymous?}` → `{enabled, anonymous}`. |
| GET | `/courses/{course}/feedback/mine` | enrolled | What you may rate: `{course, sessions}` each with `eligible`, `submitted`. |
| POST | `/courses/{course}/feedback` | enrolled | `{activity_id?, rating, comment}` → `201` `{"ok":true}`. |

`rating` is `1`–`5`; leave `activity_id` out to rate the course (after
finishing it) or give a session's id (after attending it). `403` when
feedback is off or you are not eligible yet; `409`
`you have already given feedback on this`. With `anonymous` on, comments
carry no `display_name`.

```sh
curl -s -X POST $LEARN/api/v1/courses/2f6c…/feedback \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"rating":5,"comment":"Clear and short."}'
```

### Translations

The staff translation editor. `GET` returns every translatable field of the
course (sections, activities, questions, options, captions), qualification
or path with its default text, the translation and a `missing` flag; `PUT`
upserts in bulk (`text: ""` removes one).

| Method | Path | Who |
| --- | --- | --- |
| GET, PUT | `/courses/{course}/translations?lang=nl` | staff |
| GET, PUT | `/qualifications/{qualification}/translations?lang=nl` | `qualification.manage` |
| GET, PUT | `/paths/{path}/translations?lang=nl` | path admin |

```sh
curl -s -X PUT "$LEARN/api/v1/courses/2f6c…/translations?lang=nl" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"translations":[{"entity_type":"course","entity_id":"2f6c…","field":"title","text":"Radio basis"}]}'
```

```json
{"lang":"nl","default_lang":"en","languages":["en","nl"],"missing_count":11,
 "fields":[{"entity_type":"course","entity_id":"2f6c…","field":"title","context":"",
            "default":"Radio basics","text":"Radio basis","missing":false}]}
```

`context` is a hint for translators about where the field sits (it may be
empty). `entity_type` is one of `course`, `section`, `activity`, `question`,
`option`, `media`, `activity_media`, `path`, `qualification`. `422`
`add nl to the course languages first`,
`the default language is edited in the course itself, not as a translation`.

### Reports

| Method | Path | Who |
| --- | --- | --- |
| GET | `/reports/scope` | signed in: what you may report on, `{all, qualifications, courses}` |
| GET | `/reports/completion?course=&group=&status=&format=csv` | `report.view`, `course.manage`, or `course.teach` (own courses only) |
| GET | `/reports/qualifications?qualification=&group=&status=&format=csv` | `report.view` |

Completion `status` filter: `done`, `in_progress`, `not_started`, `overdue`.
Qualification `status`: `valid`, `expiring`, `expired`, `missing` (`missing`
= member of a linked group without the qualification). `&format=csv`
downloads a CSV; text cells starting with `=`, `+`, `-` or `@` get a leading
`'` so spreadsheets do not run them as formulas.

```sh
curl -s -H "Authorization: Bearer $TOKEN" "$LEARN/api/v1/reports/completion?course=2f6c…&status=overdue"
```

```json
{"rows":[{"course_id":"2f6c…","course_title":"Radio basics","user_id":"6f1d…","display_name":"Sam Example",
  "email":"sam@example.org","source":"group","enrolled_at":"2026-10-01T09:00:00Z","due_at":"2026-10-15T09:00:00Z",
  "completed":1,"total":4,"last_activity_at":"2026-10-03T18:00:00Z","status":"overdue"}]}
```

`403` `you can only report on courses you teach` for a trainer asking about
another course.

### `POST /api/v1/reminders/run`

`settings.manage`. Sends due reminders now instead of waiting for the hourly
run (due dates, upcoming sessions, expiring certificates; each at most once
per person and subject).

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" $LEARN/api/v1/reminders/run
```

```json
{"ran":true,"channels":["email"],"sent":{"email":3},"already_sent":12,"failed":0}
```

`ran:false` means another replica was running reminders; `channels: []`
means no notification channel is configured.

### Module settings

`GET /api/v1/settings`, `PUT /api/v1/settings`

- **Who:** `settings.manage`. Others `403`.
- **What:** the Telegram switch, the retention periods and the group
  directory status. Retention comes from Den while Learn is paired and Den
  sets it (`source: "den"`, `editable: false`); then a `PUT` with
  `retention` answers `409` `retention is set in Den (Admin → Modules →
  Learn) while Learn is paired`. The built-in defaults are marked
  `pending_legal_review: true`.
- **PUT body:** any of `telegram_enabled` (bool) and `retention`
  (`{"inactive_user_months": N, "audit_log_months": N}`, each `0`–`1200`,
  `0` = never). `422` for an empty body or values out of range. The change
  is audited (`settings.updated`).
- **Response:** `200` the settings, as below.

```sh
curl -s -X PUT $LEARN/api/v1/settings \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"telegram_enabled":true,"retention":{"inactive_user_months":24,"audit_log_months":12}}'
```

```json
{"telegram":{"configured":true,"enabled":true},
 "retention":{"inactive_user_months":24,"audit_log_months":12,"source":"learn","editable":true,"pending_legal_review":false},
 "group_directory":{"mode":"keycloak","available":true,"linkable":["/learn/*"]}}
```

`telegram.configured` says whether `TELEGRAM_BOT_TOKEN` is set;
`group_directory.available` whether Learn can reach a directory (mode
`keycloak` and `KEYCLOAK_*` set).

**Retention job.** Every six hours (on one replica) Learn anonymises
people who have neither signed in nor been in a synced group for
`inactive_user_months`, exactly like [erasure](#erasing-a-person), and
deletes audit entries older than `audit_log_months`. Each run that changed
something is audited (`users.anonymised`).

### Erasing a person

`POST /api/v1/users/{user}/erase`

- **Who:** `settings.manage` in one of the person's organizations. Others
  (and unknown or already erased people) get `404`.
- **Body:** `{"confirm": "ERASE"}`; anything else `422`.
- **What it does** (GDPR erasure): the person's name becomes
  `Former learner`; their email, IdP subject and ids, language, cached
  groups, notification channels and organization memberships are removed,
  and their feedback loses its author. Enrolments, attempts, attendance and
  certificates stay; certificates keep verifying (`GET
  /api/public/verify/{code}` shows `Former learner`). Their audit entries
  keep the action with the actor name `Erased user`. Signing in again with
  the same account creates a new, empty person. It can't be undone.
- **Response:** `200` `{"user_id", "erased_at"}`.

```sh
curl -s -X POST $LEARN/api/v1/users/6f1d…/erase \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"confirm":"ERASE"}'
```

```json
{"user_id":"6f1d…","erased_at":"2026-11-11T16:20:00Z"}
```

### Audit log

`GET /api/v1/audit`

- **Who:** `settings.manage`; entries of the organizations where you hold
  it, plus entries without an organization (Den pairing, settings,
  retention).
- **Query:** `action`, `target_type`, `target_id`, `course` (id), `actor`
  (user id), `limit` (1–200, default 50) and `before` (the `next_before`
  of the previous page). Newest first.
- **Response:** `200` `{"entries": [...], "next_before": N | null}`.
  `details` holds ids and values, never names or emails. `actor_user_id`
  is `null` for the system (retention, workers).
- **Errors:** `400` for a bad id, `before` or `limit`; `403` without
  `settings.manage`.

| `action` | Recorded when |
| --- | --- |
| `enrolment.added`, `enrolment.removed`, `enrolment.self`, `enrolment.updated` | Someone is enrolled, removed, enrols themselves, or gets a due date. `details.role` says learner or trainer. |
| `path_enrolment.added`, `path_enrolment.removed` | Learning path enrolments. |
| `course.published`, `course.unpublished`, `course.archived`, `course.unarchived` | Course state changes. |
| `quiz.graded` | An attempt is submitted (score, max score, passed). |
| `quiz.reset` | A quiz is reset (counts). |
| `certificate.revoked` | A certificate is revoked (reason). |
| `qualification.saved`, `qualification.deleted` | Qualification changes. |
| `group_link.added`, `group_link.removed` | Course or path group links. |
| `session.signup_status` | Staff change attendance. |
| `den.paired`, `den.synced`, `den.unpaired` | Den pairing by an admin. |
| `settings.updated` | Module settings. |
| `user.erased`, `users.anonymised` | Erasure by an admin, or by the retention job. |

```sh
curl -s -H "Authorization: Bearer $TOKEN" "$LEARN/api/v1/audit?course=2f6c…&limit=2"
```

```json
{"entries":[
  {"id":812,"at":"2026-11-11T16:05:00Z","actor_user_id":"9a0c…","actor_name":"Tina Manager",
   "action":"enrolment.added","target_type":"enrolment","target_id":"e7c1…",
   "organization_id":"0f1a…","course_id":"2f6c…","details":{"role":"trainer","user_id":"6f1d…"}},
  {"id":807,"at":"2026-11-11T15:58:12Z","actor_user_id":"5b1e…","actor_name":"Robin Trainer",
   "action":"course.published","target_type":"course","target_id":"2f6c…",
   "organization_id":"0f1a…","course_id":"2f6c…","details":{}}],
 "next_before":807}
```

## Den pairing

`settings.manage`. Same contract as every module ([Pairing](../../concepts/pairing.md)):

| Method | Path | Body | Success | Errors |
| --- | --- | --- | --- | --- |
| GET | `/den` | | `200` `{paired, den_base_url?, module_id?, paired_at?, synced_at?, last_error?}` | |
| POST | `/den/pair` | `{"pairing_url":"…"}` | `200` status | `422` `pairing_failed` |
| POST | `/den/sync` | | `200` status | `409`/`502` `sync_failed` |
| DELETE | `/den/pair` | | `204` | |

```sh
curl -s -X POST $LEARN/api/v1/den/pair \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"pairing_url":"https://den.example.org/pair/abc123…"}'
```

## Troubleshooting

| Symptom | Likely cause and fix |
| --- | --- |
| `404` on a course you just created, for someone else | Unpublished courses are invisible to non-staff. Publish it, or ask a training manager to make them a trainer. |
| `403` `only a training manager (staff.manage) can make someone a trainer` | Trainers can't grant the trainer role. A member of `learn-manager` (or an admin) does it on **Course roles**. |
| `409` `this is the course's last trainer` | Add another trainer first, then remove this one. |
| `409` `archived` | The course is archived; unarchive it (`POST …/unarchive`) to change it. |
| `403` `only course managers (course.manage) can reset a quiz` | Ask a `learn-admin` to reset it. |
| A linked group enrols nobody at sign-in | The token carries plain group names: turn **Full group path** on in Keycloak's groups mapper. Nested groups only match by full path. |
| `403` `trainers may only link the groups set in LEARN_LINKABLE_GROUPS` | Pick a group under the configured parent, ask a course manager, or widen `LEARN_LINKABLE_GROUPS`. |
| A link shows "its path was not found" | An old name-only link matched no group, or several. Unlink it and link the group again by full path. |
| Someone is missing from the people picker | They belong to another organization, have never signed in and the directory is off, or were erased. Trainers can't search by email. |
| `422` `the file's contents are not a … file` | The file's bytes don't match its type (renamed file). Upload a real file of that type. |
| `403` `you are not enrolled in this course` | Enrol the person, turn on `self_enrol`, or link a Keycloak group they are in. |
| `403` `locked` | `details.needs` lists the activities or courses to finish first. |
| HR says "Learn unreachable" or holdings `401` | `LEARN_SERVICE_TOKEN` differs between HR and Learn, or is empty on Learn (`404`). See [Secrets](../../operations/secrets.md). |
| Holdings `[]` for someone who has the certificate | They are matched by token subject under `OIDC_ISSUER_URL`; check HR sends the Keycloak user id, and that the certificate is not expired or revoked. |
| `503` `the group directory is off or not configured` | Set `GROUP_DIRECTORY=keycloak` and all four `KEYCLOAK_*` variables. Links still work from sign-in groups without them. |
| `503` on media | `S3_ENDPOINT` is empty. |
| Media upload works but images do not show in the browser | Presigned links point at an in-cluster address; set `S3_PUBLIC_BASE_URL`. |
| Den's portal gets `401` on `/api/portal/todos` | Den must call with Learn's pairing credential, not a person's token. Pair again if the Den connection page says the credential was rejected. On Kubernetes, `den-backend` must be allowed in to the backend port (`networkPolicy.den`). |
| `429` `rate_limited` | Verify: more than 30 checks a minute from one address. Signed in: too many self-enrolments, check-ins, feedback or searches in a minute. Wait a minute. |
| `400` `invalid JSON: json: unknown field` | Learn rejects unknown fields; check the spelling. |
