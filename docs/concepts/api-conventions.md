# API conventions

Every Con Services module is a web app with a **JSON-over-HTTP API** behind
it. The web app uses that API, other modules use parts of it, and you can
script against it with `curl` or any HTTP client. This page describes the
rules all of those APIs share: addresses, authentication, errors, health
checks and versioning. Each module's API reference (for example the
[Den API reference](../modules/den/api.md)) lists its own endpoints and
links back here for everything common.

If you are new to the suite, read [Architecture](architecture.md) and
[Authentication](authentication.md) first. Words such as *ID token*,
*realm* or *pairing* are explained in the [Glossary](glossary.md).

## At a glance

| Topic | Convention |
| --- | --- |
| Format | JSON in, JSON out, UTF-8. `Content-Type: application/json`. |
| People | `Authorization: Bearer <ID token>` issued by Keycloak (OIDC). |
| Machines | `Authorization: Bearer <secret>`: a module credential, a service token or a public API key, depending on the endpoint. |
| Errors | `{"error":{"code":"…","message":"…","details":…}}` with a matching HTTP status. |
| Health | `/livez` and `/readyz` on the backend for Kubernetes, `/api/health` for people. |
| Tracing | Every response has an `X-Request-ID` header that matches the backend's log line. |
| Times and IDs | RFC 3339 times (`2026-11-06T10:15:00Z`); UUIDs for IDs. |
| Between modules | HTTP only, on the paths the network policies allow. Never another module's database. |

## Where the API lives

Every module has one web address, for example `https://den.conservices.test`
or `https://wiki.conservices.test` in the
[local example installation](../getting-started/den-quickstart.md). The
module's frontend (nginx) forwards everything under `/api/` to its backend,
so the browser, `curl` and other tools all use that same address. Inside the
cluster, services call the backend directly at
`http://<module>-backend.conservices-<module>.svc.cluster.local:8080`.

### URL prefixes

The path tells you who the endpoint is for:

| Prefix | Who calls it | Authentication |
| --- | --- | --- |
| `/api/v1/...` | The module's own web app and your scripts, on behalf of a **person**. | ID token (or `X-Dev-User` in dev mode). |
| `/api/public/v1/...` | **Anyone on the internet**: attendees, calendar apps, people with a share link. | None, an attendee token or a public API key, depending on the endpoint. |
| `/api/internal/...` | **Another Con Services module**, server to server. Never the browser. | A shared service token. |
| `/api/v1/integrations/...` (Den only) | **Paired modules** calling Den. | A module credential from [pairing](pairing.md). |
| `/api/role-catalog` | HR, to build its access picker. | None (public, read-only). |
| `/api/qualification-catalog` (Learn only) | HR, to pick training requirements for roles. | None (public, read-only). |
| `/api/health` | People and monitoring checking on a module. | None. |

!!! note "Not every module is on `/api/v1` yet"
    Den, Rally, Wiki, Learn, Desk and Tasks serve their staff API under
    `/api/v1`. **HR, Stash and Finance** are older and serve the same kind
    of endpoints directly under `/api/` (for example `GET /api/people` in HR,
    `GET /api/items` in Stash). Public endpoints are also not uniform yet:
    Den uses `/api/v1/public/...`, Stash `/api/public/lostfound` and Learn
    `/api/public/verify/{code}`. The module's API page always shows the
    real paths; new endpoints follow the table above.

Here is where each module's endpoints are today:

| Module | Staff API | Public | Internal (for other modules) |
| --- | --- | --- | --- |
| [Den](../modules/den/api.md) | `/api/v1` | `/api/v1/public/brand`, pairing redeem, backup download links | `/api/v1/integrations/*` for paired modules |
| [HR](../modules/hr/api.md) | `/api` | none | none (HR *calls* Learn, Wiki and Tasks) |
| [Rally](../modules/rally/api.md) | `/api/v1` | `/api/public/v1` (calls for papers, schedules, attendee submissions) | none |
| [Stash](../modules/stash/api.md) | `/api` | `/api/public/lostfound` (when switched on) | none |
| [Finance](../modules/finance/api.md) | `/api` | none | none |
| [Learn](../modules/learn/api.md) | `/api/v1` | `/api/public/verify/{code}` | `/api/internal/holdings` |
| [Wiki](../modules/wiki/api.md) | `/api/v1` | `/api/public/v1/shares/{token}` (when switched on) | `/api/internal/offboarded` |
| [Desk](../modules/desk/api.md) | `/api/v1` | none | none |
| [Tasks](../modules/tasks/api.md) | `/api/v1` | none | `/api/internal/departments` |

### Endpoints every module has

Besides its own features, each module offers the same small set of
endpoints, so the suite can treat them alike. Paths are shown with the
`/api/v1` prefix; HR, Stash and Finance drop the `v1`.

| Endpoint | Auth | What it does |
| --- | --- | --- |
| `GET /api/v1/me` | person | Who you are, as this module sees you: name, groups, role or permissions. |
| `GET` / `PUT /api/v1/me/preferences` | person | Your theme (`system`, `light` or `dark`). When the module is paired, this is stored in Den and shared by every app. |
| `GET /api/v1/brand` | none | The brand the login screen needs before anyone signs in: name, colours, logo. Den's brand when paired, the module's own otherwise. |
| `GET /api/v1/brand/{role}` | none | The current brand image for a role, such as `logo` or `login-background`. |
| `GET /api/role-catalog` | none | The roles this module understands and the Keycloak group of each. See [The role catalog](authentication.md#the-role-catalog). |
| `/api/v1/den` (`GET`, `POST /pair`, `POST /sync`, `DELETE /pair`) | admin | The module's *Den connection*: pair, sync now, unpair. See [Pairing](pairing.md#the-den-connection-api-in-each-module). |

Den itself is the exception: it is the hub, so it has no `/den` connection
endpoints, and its brand lives at `/api/v1/public/brand`.

## Requests and responses

**Bodies are JSON.** Send `Content-Type: application/json` with every
`POST`, `PUT` and `PATCH` that has a body. The only exceptions are file
uploads, which say so on the module's API page (Wiki, for example, takes
`multipart/form-data`).

**Unknown fields are rejected.** The backends decode bodies strictly. A
misspelt field name is not silently ignored; you get:

```json
{"error":{"code":"bad_request","message":"invalid JSON: json: unknown field \"titel\""}}
```

**An empty body** where one is required gives `400` with
`"request body is empty"`.

**`PUT` replaces, `PATCH` changes.** `PUT` sends the whole document (for
example Den's organisation settings). `PATCH` sends only the fields you want
to change; fields you leave out keep their value.

**Successful responses** use these statuses:

| Status | When |
| --- | --- |
| `200 OK` | A read, or an update that returns the changed object. |
| `201 Created` | Something new was made. The body is the new object. |
| `204 No Content` | It worked and there is nothing to return (deletes, unpairing, internal hooks). |

**Lists** are not shaped the same way everywhere yet. Some endpoints return
a bare JSON array (Den's `GET /api/v1/modules`), others an object with the
array inside, usually under `items` (Rally's public API keys):

```json
{"items": [{"id": "1b0e…", "name": "Signage screen"}]}
```

The module's API page shows the shape of each list. New list endpoints wrap
the array in an object, so fields such as a total can be added later
without breaking clients.

**Times** are RFC 3339 strings in UTC, for example `2026-11-06T10:15:00Z`.
**IDs** are UUIDs such as `c8c43a98-e96c-4dc4-a501-138f13d10ad3`; a
malformed ID in the path gives `400` with a message like `invalid module id`.

**Request IDs.** Every response carries an `X-Request-ID` header with a
fresh ID for that request. The same value appears in the backend's log
lines as `request_id`, so quoting it in a bug report lets an operator find
exactly your request.

**Timeouts.** Requests are cut off after 60 seconds. Endpoints that
legitimately take longer (backup downloads and module removal in Den, live
editing websockets in Wiki) are exempt.

## Authentication

There are five kinds of caller. Which one an endpoint accepts follows from
its prefix (see [URL prefixes](#url-prefixes)).

| Caller | Sends | Used on | Explained in |
| --- | --- | --- | --- |
| **A person** (staff, volunteer) | `Authorization: Bearer <ID token>` from the `conservices` realm | `/api/v1/...` | [Authentication](authentication.md) |
| **An attendee** (Rally's public submission site) | `Authorization: Bearer <ID token>` from the separate `attendees` realm | Rally's signed-in `/api/public/v1/...` endpoints | [Rally API](../modules/rally/api.md) |
| **A paired module** | `Authorization: Bearer <module credential>` | Den's `/api/v1/integrations/...` | [Pairing](pairing.md) |
| **Another module, server to server** | `Authorization: Bearer <service token>`, such as `WIKI_SERVICE_TOKEN` | `/api/internal/...` | [Machine-to-machine authentication](authentication.md#machine-to-machine-authentication) |
| **An outside system** (a website, a signage screen) | `Authorization: Bearer <public API key>`, or `?key=` for calendar feeds | Rally's public schedule | [Rally API](../modules/rally/api.md) |

Tokens and keys always travel in the `Authorization` header with the
`Bearer` scheme. The one exception is calendar subscriptions, which cannot
send headers, so Rally's `calendar.ics` also accepts `?key=`.

### People: the ID token

Each module checks that the token is signed by Keycloak, comes from the
configured issuer (`OIDC_ISSUER_URL`), is meant for this module (its `aud`
is the module's client, `OIDC_AUDIENCE` or `OIDC_CLIENT_ID`), and has not
expired. Send the **ID token**, not the access token: the ID token's
audience is always the app's own client, the access token's often is not.
Tokens in the local realm live 5 minutes.

A token for one module does not work on another. `den-spa`'s ID token is
refused by Wiki, because its audience is `den-spa`, not `wiki-spa`. Get a
token for the client of the module you are calling.

### 401, 403 or 404?

The status tells you what to fix:

| Status | Meaning | What to do |
| --- | --- | --- |
| `401 Unauthorized` | **We do not know who you are.** The token, credential or key is missing, malformed, expired, for another module, or revoked. | Get a fresh token for the right client, or check the secret. |
| `403 Forbidden` | **We know who you are, and you may not do this.** Your groups do not give you the role or permission the endpoint needs. | Ask an admin to add you to the right Keycloak group (often through HR), then get a new token. |
| `404 Not Found` | **There is nothing here for you.** Either it does not exist, or you are not allowed to know it exists. | Check the ID; check that you have at least view access. |

Two rules make `404` the answer more often than you might expect:

- **Hidden things look missing.** When you may not even *see* something (a
  restricted Wiki page, a private Tasks list, a Rally submission that is not
  yours), the answer is `404`, exactly as if it did not exist. A `403` would
  confirm that it exists. You only get `403` for things you can see but not
  change.
- **Switched-off features do not exist.** Endpoints that an operator must
  turn on answer `404` while they are off: Wiki's public share links, Stash's
  public lost and found, Rally's public schedule, and every
  `/api/internal/...` endpoint whose service token is not configured. Only
  once a feature is on do you get `401` for a missing or wrong secret.

Typical messages:

| Status | `message` | Cause |
| --- | --- | --- |
| 401 | `missing bearer token` | No `Authorization: Bearer` header. |
| 401 | `invalid token` | Expired, wrong issuer, or wrong audience. |
| 401 | `invalid or revoked credential` | Den does not know this module credential. |
| 401 | `authentication required` / `invalid service token` | A wrong service token on an internal endpoint. |
| 401 | `a public API key is required (…)` | Rally's public schedule without a valid key. |
| 403 | `insufficient role`, `permission denied`, `you don't have access to HR` | Signed in, but your groups do not allow this. |

### Get a token for `curl`

!!! danger "Development and local trials only"
    This uses Keycloak's **password grant** with the public test accounts of
    the local realm (`admin` / `adminadmin`, `alice` / `alicealice`,
    `bob` / `bobbob`). The local realm enables the password grant on every
    `*-spa` client so that these examples work. In production the password
    grant must be **off** on every app client and the test accounts must not
    exist; see [Production and security](../operations/production.md#keycloak).
    Never paste a real person's password into a command line.

Pick the client of the module you want to call (`den-spa`, `hr-spa`,
`events-spa` for Rally, `stash-spa`, `finance-spa`, `learn-spa`, `wiki-spa`,
`desk-spa`, `tasks-spa`):

=== "macOS / Linux"

    ```sh
    KC=https://auth.conservices.test/realms/conservices/protocol/openid-connect/token
    TOKEN=$(curl -s "$KC" \
      -d grant_type=password -d client_id=wiki-spa \
      -d username=admin -d password=adminadmin -d scope=openid \
      | jq -r .id_token)
    ```

=== "Windows (PowerShell)"

    ```powershell
    $KC = "https://auth.conservices.test/realms/conservices/protocol/openid-connect/token"
    $TOKEN = (Invoke-RestMethod -Method Post -Uri $KC -Body @{
      grant_type = 'password'; client_id = 'wiki-spa'
      username = 'admin'; password = 'adminadmin'; scope = 'openid'
    }).id_token
    ```

`scope=openid` is what makes Keycloak return an `id_token` at all. Then call
the module:

```sh
curl -s https://wiki.conservices.test/api/v1/me \
  -H "Authorization: Bearer $TOKEN"
```

You should see your user, for example:

```json
{
  "id": "0d6f4c1e-7a51-4c1b-9a43-5c2f8e9b1a20",
  "display_name": "Dev Admin",
  "email": "admin@conservices.local",
  "issuer": "https://auth.conservices.test/realms/conservices",
  "subject": "3b7e2f0a-9c4d-4e1a-8f6b-2d5c7a9e1b34",
  "memberships": [{ "organization_id": "00000000-0000-0000-0000-000000000001", "role": "admin" }],
  "permissions": ["settings.manage", "space.create"]
}
```

(The exact fields of `/me` differ per module; its API page shows them.)
After 5 minutes the token expires and you get
`401 {"error":{"code":"unauthorized","message":"invalid token"}}`; run the
token command again.

!!! tip "Dev mode"
    A backend running with `AUTH_MODE=dev` (local development only) skips
    tokens and trusts an `X-Dev-User: <name>` header instead, for example
    `curl -H "X-Dev-User: alice" http://localhost:8090/api/v1/me`. See
    [Dev mode](authentication.md#dev-mode-no-keycloak). Never run a
    reachable deployment in dev mode.

## Errors

Every module answers errors with the same JSON **envelope**:

```json
{
  "error": {
    "code": "validation_failed",
    "message": "validation failed",
    "details": { "name": "required" }
  }
}
```

| Field | Always there | Meaning |
| --- | --- | --- |
| `code` | yes | A stable, machine-readable string. **Branch on this**, not on the message. |
| `message` | yes | A short, human-readable explanation. It may be reworded between releases. |
| `details` | no | Extra structure, mostly per-field problems for `validation_failed`. Its shape is described on the module's API page. |

The `Content-Type` of an error is `application/json; charset=utf-8`, the
same as a success.

### Error codes

These codes are shared by every module:

| `code` | HTTP status | Meaning |
| --- | --- | --- |
| `bad_request` | 400 | The request is malformed: invalid JSON, an empty body, an unknown field, an invalid ID. |
| `unauthorized` | 401 | No valid token, credential or key. See [401, 403 or 404?](#401-403-or-404). |
| `forbidden` | 403 | Signed in, but not allowed. |
| `not_found` | 404 | It does not exist, or you may not see it. The message names the thing: `page not found`. |
| `conflict` | 409 | Not possible in the current state: a duplicate name, a module that is not paired, something already in use. |
| `validation_failed` | 422 | The JSON is fine but the values are not. `details` says which. |
| `internal` | 500 | Something broke inside the module. The message is always `internal server error`; the real cause is in the backend's log under the response's `X-Request-ID`. |

Some modules add codes for their own situations:

| `code` | HTTP status | Module | Meaning |
| --- | --- | --- | --- |
| `unavailable` | 502 | Den | A service Den depends on (its operator) failed; the message says why. |
| `unavailable` | 503 | Wiki | A feature is not available right now, for example `uploads need object storage (S3_ENDPOINT)`. |
| `service_unavailable` | 503 | Rally | A feature is not configured on this deployment. |
| `upstream_failed` | 502 | HR | An outside system (Keycloak, the workspace provider) refused; the message says what to fix. |
| `too_many_requests` | 429 | Wiki | Public share links: too many requests from your address. Wait for `Retry-After` seconds. |
| `rate_limited` | 429 | Learn | Public certificate check: the same, with a different code. |
| `pairing_failed` | 422 | every paired module | Redeeming a pairing URL in the module's Den connection failed. |
| `sync_failed` | 409 or 502 | every paired module | "Sync now" failed: `409` when not paired, `502` when Den did not answer. |

Examples:

```json
{"error":{"code":"unauthorized","message":"missing bearer token"}}
```

```json
{"error":{"code":"not_found","message":"module not found"}}
```

```json
{"error":{"code":"conflict","message":"a private space cannot be deleted"}}
```

```json
{"error":{"code":"internal","message":"internal server error"}}
```

!!! note "Two known exceptions"
    Tasks answers its switched-off `/api/internal/departments` endpoint with
    a plain-text `404 page not found` rather than the JSON envelope. Routes
    that do not exist at all (a typo in the path) also get the router's
    plain-text `404` in every module. Treat any `404` as "not here",
    whatever the body.

## Health endpoints

Backends offer up to three health endpoints. None needs authentication.

| Endpoint | For | Answers |
| --- | --- | --- |
| `GET /livez` | Kubernetes' **liveness** probe: is the process alive? Never touches the database, so a database outage does not make Kubernetes restart every pod. | `200` while the process runs. |
| `GET /readyz` | Kubernetes' **readiness** probe: can this pod take traffic? Checks the database (and other critical dependencies). | `200`, or `503` with the same body when something is down. |
| `GET /api/health` | People and monitoring: a readable status through the public address. | `200`, or `503` when degraded. |

`/livez` and `/readyz` are at the root, not under `/api/`, so the frontend's
nginx does not forward them: they are reachable only on the backend itself
(the probes call the pod directly). `/api/health` goes through the normal
address:

```sh
curl -s https://den.conservices.test/api/health
```

```json
{"status":"ok","database":"ok","version":"1.0.0","uptime_sec":5123}
```

When the database is down:

```json
{"status":"degraded","database":"down","version":"1.0.0","uptime_sec":5180}
```

To call `/readyz` from your computer, forward the backend's port first:

```sh
kubectl -n conservices-den port-forward svc/den-backend 8080:8080
curl -sk https://localhost:8080/readyz
```

The backend serves HTTPS with a certificate for its service name, not for
`localhost`, so `-k` skips the name check for this local test only.

Which module has which endpoint today: Den, Rally, Wiki, Learn, Desk and
Tasks have all three; HR and Finance have `/livez` and `/readyz`; Stash has
`/api/health` only.

## CORS

A browser only lets a page call an API on another address if that API says
so; this is **CORS** (Cross-Origin Resource Sharing). Normally you do not
need it: each web app calls the API on its own address, through its own
nginx.

If you build a browser app on a different address, add that address to the
module's `CORS_ALLOWED_ORIGINS` (a comma-separated list, for example
`https://dashboard.example.org`). The backends then allow:

- methods `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `OPTIONS`;
- headers `Accept`, `Authorization`, `Content-Type`, `X-Request-ID` (and
  the dev-mode headers);
- reading the `X-Request-ID` response header;
- credentials, with a 5-minute preflight cache.

Never put `*` in `CORS_ALLOWED_ORIGINS`. Scripts and servers (`curl`,
another backend) are not browsers and are not affected by CORS at all.

## Versioning

There are two kinds of version, and they move independently.

**The release version** is the image tag, `MAJOR.MINOR.PATCH-BUILD`, for
example `1.4.2-3` (see [Versions and upgrades](../operations/versioning.md)).
Any API change that can break a client (a removed or renamed endpoint or
field, a new required field, a changed meaning) gets a **BREAKING:** entry
in the app's changelog that says what to change. In Den, a breaking change
to something modules use bumps **MAJOR**; a module bumps **MINOR**, because
its MAJOR always equals Den's.
Adding endpoints, adding optional request fields and adding response fields
are not breaking, and come in **MINOR** releases. So: **ignore response
fields you do not know**, and do not depend on the order of fields.

**The path version** (`v1` in `/api/v1`) changes only for a deliberate,
large redesign of an API. If that ever happens, the old and new versions are
served side by side for at least one MAJOR release, and the changelog says
when the old one goes away. There is no `v2` of any module today.

Error `code` values are part of the API: they are not renamed in a MINOR
release. Error `message` texts may be.

## Calls between modules

Modules talk to each other **only over HTTP**, through the endpoints above.
A module never connects to another module's database, never reads another
module's bucket and never shares database or storage credentials. This is
decided in Den's ADR
[0005: No shared Postgres](https://github.com/AGlElectronics/den/blob/main/docs/adr/0005-no-shared-postgres.md)
and
[0004: One bucket per module](https://github.com/AGlElectronics/den/blob/main/docs/adr/0004-one-bucket-per-module.md),
and enforced by separate database logins and by network policies.

The calls that exist today:

| From | To | Endpoint | Authenticated by |
| --- | --- | --- | --- |
| every paired module | Den | `/api/v1/integrations/*` (bundle every minute, brand images, preferences) | module credential |
| HR | every module | `GET /api/role-catalog` | none |
| Den | paired modules | `GET /api/role-catalog` (who sees the module on the portal, cached 5 minutes) | none |
| Den | paired modules | `GET /api/portal/todos` ([below](#portal-to-dos)) | the module's own pairing credential, plus the person's issuer and subject |
| HR | Learn | `GET /api/qualification-catalog` | none (public, read-only) |
| HR | Learn | `GET /api/internal/holdings?subjects=…` | `LEARN_SERVICE_TOKEN` |
| HR | Wiki | `POST /api/internal/offboarded` | `WIKI_SERVICE_TOKEN` |
| HR | Tasks | `POST /api/internal/departments` | `TASKS_SERVICE_TOKEN` |

### Portal to-dos

Den's portal shows each person a list of things to do across the modules
(**to-dos**). Den's **backend** collects them, server to server; the browser
only talks to Den, and no user token leaves Den. A module takes part by
serving one endpoint. This is the contract a module implements:

**Request** (from `den-backend`, at the module's `internal_url`, else its
`base_url`, over HTTPS, 5-second timeout):

```http
GET /api/portal/todos HTTP/1.1
Authorization: Bearer <the module's own Den credential>
X-Den-User-Issuer: https://auth.conservices.test/realms/conservices
X-Den-User-Subject: 0b6e2c4d-8f1a-4b3c-9d7e-5a6b7c8d9e0f
Accept: application/json
```

**What the module must check:**

1. The bearer is exactly the credential the module received when it was
   paired (compare in constant time). Anything else: `401`. The module
   already stores this credential for its calls to Den; no new secret is
   needed. A module that is not paired answers `404`.
2. The person is the user with that issuer and subject in the module. An
   unknown person gets `{"items": []}`, not an error.
3. Only that person's to-dos are returned, filtered by what they may see in
   the module.

**Response** `200`, JSON:

```json
{
  "items": [
    {
      "id": "shift-42",
      "title": "Confirm your Saturday shift",
      "detail": "Info desk, 10:00–14:00",
      "due_at": "2026-11-14T10:00:00Z",
      "url": "https://hr.conservices.test/shifts/42",
      "severity": "warning"
    }
  ]
}
```

| Field | Required | Rules |
| --- | --- | --- |
| `id` | yes | Stable within the module. |
| `title` | yes | Short, shown as the link text. |
| `detail` | no | One line under the title. |
| `due_at` | no | RFC 3339 or `null`; sorted first when soonest. |
| `url` | yes | An `https` (or `http`) link into the module. Den drops items with any other scheme. |
| `severity` | no | `info`, `warning` or `danger`; anything else counts as `info`. |

Den takes at most 50 items per module. A module that does not implement the
endpoint answers `404` and is listed as `unsupported`; timeouts and other
errors are skipped. Den only asks modules the person may use (by the
module's role catalog or its portal visibility) and only when Den has
`DEN_CREDENTIAL_KEY` set. Network policies must allow `den-backend` to reach
the module backend on 8080
([Network policies](../operations/network-policies.md#calls-between-modules)).

Den's own endpoint, which the portal calls, is
[`GET /api/v1/portal/todos`](../modules/den/api.md#get-apiv1portaltodos).
Modules that accepted Den's ID token for `/api/portal/todos` before (Learn's
`OIDC_EXTRA_AUDIENCES`) should switch to the credential check above.

A service token is the same random value on both sides: the module that
offers the endpoint checks it, the caller sends it. Both live in Kubernetes
Secrets fed by your secret manager; see [Secrets](../operations/secrets.md)
for where each one lives and how to rotate it. Each of these paths is also
an explicit allow rule on both namespaces; without it the call times out.
Not all of these rules are in the Kubernetes manifests yet;
[Network policies → Calls between modules](../operations/network-policies.md#calls-between-modules)
shows the status of each one.

This is the internal call HR makes after deleting someone's account. Only
HR's pods may reach this address, so the example shows what HR sends rather
than something to run from your computer; the token is a placeholder:

```sh
curl -s --cacert /etc/conservices-internal-ca/ca.crt -X POST https://wiki-backend.conservices-wiki.svc.cluster.local:8080/api/internal/offboarded \
  -H "Authorization: Bearer change-me-wiki-service-token" \
  -H "Content-Type: application/json" \
  -d '{"subject":"6f1c2d7e-0b7a-4e57-9a7e-2b1d3c4e5f60","username":"bob"}'
```

The answer is `204 No Content`. Internal endpoints are idempotent: calling
one twice with the same input does no harm, so callers may safely retry.

## Writing a new endpoint

If you are adding to a module, follow these rules so the suite stays
consistent:

1. Put it under the right prefix: `/api/v1` for people, `/api/public/v1`
   for anonymous or outside callers, `/api/internal` for other modules.
2. Return errors only through the module's `httperror` package, so the
   envelope and status codes match this page. Add a new `code` only when no
   existing one fits; clients branch on them.
3. Answer `404` for things the caller may not see, and for features that are
   switched off.
4. Accept secrets only in the `Authorization: Bearer` header, compare them
   in constant time, and store only hashes of anything you issue.
5. Document it on the module's API page (method and path, who may call it,
   request, response, errors, a `curl` example) and add a changelog entry,
   as described in [Contributing](../contributing/index.md).

## Troubleshooting

**`401 invalid token` straight after getting a token.** The token is for
another client: `client_id` must be the module you are calling
(`wiki-spa` for Wiki). Or you sent the access token; use `.id_token`.

**`401 invalid token` after a few minutes.** Tokens in the local realm last
5 minutes. Get a new one.

**`jq: error … null` or an empty `$TOKEN`.** Keycloak refused the password
grant. Run the token command without `| jq …` to see why:
`invalid_grant` means a wrong user name or password, `unauthorized_client`
means the password grant is off for that client (as it should be in
production).

**`403` although you are an admin.** Your group membership changed but your
token is older. Get a new token. Check the `groups` in it by pasting it into
a JWT decoder you trust, or with
`echo $TOKEN | cut -d. -f2 | base64 -d 2>/dev/null | jq .groups`.

**`404` on an endpoint the docs list.** Check the prefix: HR, Stash and
Finance have no `v1`. Check whether the feature must be switched on (public
links, public schedule, internal endpoints). Check you may see the object.

**`400 invalid JSON: json: unknown field`.** A field name is misspelt or
belongs to another endpoint. The message names it.

**A call between two modules hangs and then fails.** A network policy is
missing on one side. See
[Network policies → Troubleshooting](../operations/network-policies.md#troubleshooting).

**`/livez` or `/readyz` gives `404` through the public address.** That is
expected: they are only on the backend. Use `/api/health`, or
`kubectl port-forward` as shown in [Health endpoints](#health-endpoints).
