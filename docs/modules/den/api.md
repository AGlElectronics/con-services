# Den API reference

Den's backend is the JSON-over-HTTP API behind the suite's portal and admin
console. It serves three audiences: **Den's own web app** (the portal home,
the module registry, branding, organisation settings, backups), **paired
modules** (HR, Rally, Stash and the rest), which fetch the brand,
organisation settings and each person's theme from it server to server,
and **your automation**, for example a script that registers modules,
pushes a new brand revision before an event, or starts a backup. Every
other module is configured relative to Den, so this is the API to read
first.

This page lists all **48 endpoints**, taken from
[`backend/internal/http/router.go`](https://github.com/AGlElectronics/den/blob/main/backend/internal/http/router.go)
and its handlers. What all modules share (error shape, request IDs, probes,
how tokens are checked) is on
[API conventions](../../concepts/api-conventions.md); how sign-in works is
on [Authentication](../../concepts/authentication.md).

## Basics

**Base address and routing.** The API is served under Den's own web
address: the Gateway sends the request to `den-frontend`, whose nginx
passes everything under `/api/` on to `den-backend`. All examples use the
address of the [local example installation](../../getting-started/den-quickstart.md);
`$DEN` stands for it:

```sh
DEN=https://den.conservices.test
```

| From | Address |
| --- | --- |
| Your computer, scripts, the web app | `https://den.conservices.test` (your own domain in a real installation) |
| Paired modules, inside the cluster | `https://den-backend.conservices-den.svc.cluster.local:8080`, only paths the [network policies](../../operations/network-policies.md) allow |
| Docker Compose development stack | `http://localhost:8090` |

Paths are grouped by caller: `/api/v1/…` for people, `/api/v1/integrations/…`
for paired modules, `/api/v1/public/…` and `/api/v1/backup-downloads/…`
for anyone, plus `/api/health`, `/api/role-catalog` and the root probes.

**Rate limits.** The endpoints that need no sign-in are limited per client
address: `POST /api/v1/integrations/pairing/redeem` 10 a minute,
`/api/v1/public/*` 120 a minute, `GET /api/v1/backup-downloads/{token}` 10 a
minute. IPv6 clients count per `/64` network, so one machine cannot dodge
the limit by rotating addresses. Everything for signed-in people is limited
to 600 requests a minute **per person** (issuer and subject of the token),
with short bursts allowed. Over the limit Den answers `429 rate_limited`
with a `Retry-After` header (seconds). The client address is worked out as
described under
[Client IP addresses](../../operations/production.md#client-ip-addresses).
With several backend replicas each counts on its own.

```text
HTTP/1.1 429 Too Many Requests
Retry-After: 42

{"error":{"code":"rate_limited","message":"too many requests, try again later"}}
```

**Request bodies** are JSON (`Content-Type: application/json`), except the
asset upload. Unknown fields are rejected with `400 bad_request`. A JSON
body may be at most 1 MiB; a larger one gets `413 request_too_large`.

```text
HTTP/1.1 413 Request Entity Too Large

{"error":{"code":"request_too_large","message":"request body is larger than 1048576 bytes"}}
```

**Security headers.** Every API response carries
`Content-Security-Policy: default-src 'none'; frame-ancestors 'none'`,
`X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY` and
`Referrer-Policy: no-referrer`.

**Times** are RFC 3339 strings, for example `2026-11-06T10:15:00Z`.
**IDs** are UUIDs.

**Request IDs.** Every response carries an `X-Request-ID` header (send your
own to correlate logs). It appears in Den's log lines as `request_id`.

**Timeouts.** Requests are cut off after 60 seconds, except backup downloads
and module removal, which may take longer.

### Errors

Every error has the same shape:

```json
{
  "error": {
    "code": "validation_failed",
    "message": "validation failed",
    "details": { "theme": "must be system, light or dark" }
  }
}
```

`details` is only present for some validation errors.

| `code` | HTTP status | Meaning |
| --- | --- | --- |
| `bad_request` | 400 | The request is malformed: invalid JSON, an empty body, an invalid ID. |
| `unauthorized` | 401 | No valid token or credential. |
| `forbidden` | 403 | Signed in, but your role is not allowed to do this. |
| `not_found` | 404 | The thing does not exist. The message names it, for example `module not found`. |
| `conflict` | 409 | Not possible in the current state, for example the operator is not set up. |
| `request_too_large` | 413 | The JSON body is larger than 1 MiB. |
| `validation_failed` | 422 | The values are not acceptable. |
| `rate_limited` | 429 | Too many requests from your address or account; wait `Retry-After` seconds. |
| `internal` | 500 | Something broke inside Den; the details are in Den's log. |
| `unavailable` | 502 | A service Den depends on (the operator) failed; the message says why. |

The health endpoints `/readyz` and `/api/health` answer `503` with their
normal body when the database is down.

### Authentication

There are three kinds of caller (explained in
[Authentication](../../concepts/authentication.md)):

| Kind | How it authenticates | Used for |
| --- | --- | --- |
| **People** | `Authorization: Bearer <access token>` from Keycloak with the audience `den-api` (OIDC mode), or `X-Dev-User: <name>` (dev mode). | Everything under `/api/v1` except the integration and public endpoints. |
| **Paired modules** | `Authorization: Bearer <module credential>`. | `/api/v1/integrations/*`. |
| **Anyone** | Nothing. | Health, role catalog, public brand, pairing redeem, backup download links. |

Endpoints for people additionally need a **role** in the default
organisation:

- **signed in**: any authenticated person;
- **member**: `member`, `admin` or `owner`;
- **admin**: `admin` or `owner`;
- **ops**: the `ops` role (`DEN_OPS_GROUPS`, default `den-ops`). It is
  separate from admin: an admin without it cannot run, schedule or download
  backups or delete a module's database. In dev mode every user has it.

A disabled account (`users.is_disabled`) gets `403 this account is disabled`
on every endpoint.

Authentication errors:

| Status | Message | When |
| --- | --- | --- |
| 401 | `missing bearer token` | No `Authorization: Bearer` header. |
| 401 | `invalid token` | The token is expired, not from the configured issuer, lacks the audience `den-api` (`OIDC_AUDIENCE`), or is not an access token (an ID token, `typ` other than `Bearer`). Den's log says which. |
| 401 | `invalid or revoked credential` | A module credential Den does not know. |
| 403 | `insufficient role` | Your role is too low for this endpoint. |
| 403 | `this account is disabled` | The account is disabled in Den. |

#### Getting a token for testing

!!! danger "Local development only"
    This uses Keycloak's password grant and the local realm's dev account
    `admin` / `adminadmin`. Real deployments should not allow password grants
    for app clients, and the dev accounts must not exist there.

=== "macOS / Linux"

    ```sh
    TOKEN=$(curl -s https://auth.conservices.test/realms/conservices/protocol/openid-connect/token \
      -d grant_type=password -d client_id=den-spa \
      -d username=admin -d password=adminadmin -d scope=openid \
      | jq -r .access_token)
    ```

=== "Windows (PowerShell)"

    ```powershell
    $TOKEN = (Invoke-RestMethod -Method Post `
      -Uri https://auth.conservices.test/realms/conservices/protocol/openid-connect/token `
      -Body @{ grant_type='password'; client_id='den-spa'; username='admin'; password='adminadmin'; scope='openid' }).access_token
    ```

Den expects the **access token** as the bearer; it must carry the audience
`den-api`, which the realm's audience mapper on `den-spa` adds. ID tokens
are refused (since Den 1.0). The `curl` examples below use bash syntax and
`$TOKEN`. Tokens last 5 minutes in the local realm.

In dev mode (`AUTH_MODE=dev`) skip the token and send a header instead:
`-H "X-Dev-User: dev-admin"`.

#### Which credential to use

| You are | Use | Get it from |
| --- | --- | --- |
| A person or a script acting as one | Keycloak **access token** from `den-spa` (audience `den-api`), with the `admin` role for anything under `/modules`, `/brand`, `/org-settings`, `/module-settings`, `/keycloak-sync`, `/audit-events`, and the `ops` role for `/operations` (except `/operations/status`) | The token endpoint above (dev), or your web app sign-in. Roles come from `DEN_ADMIN_GROUPS` (default `den-admin`), `DEN_MEMBER_GROUPS` and `DEN_OPS_GROUPS` (default `den-ops`). |
| A module's backend | **Module credential** | [Pairing](#pairing-end-to-end): an admin creates a pairing URL, the module redeems it once. |
| A website or sign-in page | Nothing | `/api/v1/public/brand`. |

---

## Endpoint summary

| Method | Path | Access | Section |
| --- | --- | --- | --- |
| GET | `/livez`, `/readyz`, `/api/health` | anyone | [Health](#health) |
| GET | `/api/role-catalog` | anyone | [Health](#get-apirole-catalog) |
| GET | `/api/v1/me` | signed in | [You](#you) |
| GET, PUT | `/api/v1/me/preferences` | signed in | [You](#you) |
| GET | `/api/v1/dashboard` | member | [You](#get-apiv1dashboard) |
| GET | `/api/v1/portal/todos` | member | [You](#get-apiv1portaltodos) |
| GET, POST | `/api/v1/modules` | admin | [Modules](#modules) |
| GET, PATCH, DELETE | `/api/v1/modules/{id}` | admin (`?database=drop`: also ops) | [Modules](#modules) |
| POST | `/api/v1/modules/{id}/pairing-tokens` | admin | [Modules](#post-apiv1modulesidpairing-tokens) |
| GET, DELETE | `/api/v1/modules/{id}/credentials` | admin | [Modules](#get-apiv1modulesidcredentials) |
| DELETE | `/api/v1/modules/{id}/credentials/{credentialID}` | admin | [Modules](#delete-apiv1modulesidcredentialscredentialid) |
| GET, PUT | `/api/v1/brand/profile` | admin | [Branding](#branding) |
| GET, POST | `/api/v1/brand/assets` | admin | [Branding](#branding) |
| GET, DELETE | `/api/v1/brand/assets/{id}` | admin | [Branding](#branding) |
| GET | `/api/v1/public/brand`, `/api/v1/public/brand/assets/{role}` | anyone (rate-limited) | [Branding](#get-apiv1publicbrand) |
| GET, PUT | `/api/v1/org-settings` | admin | [Organisation settings](#organisation-settings) |
| GET, PUT | `/api/v1/module-settings` | admin | [Module settings](#module-settings) |
| GET | `/api/v1/modules/{id}/settings` | admin | [Module settings](#get-apiv1modulesidsettings) |
| GET, POST | `/api/v1/keycloak-sync` | admin | [Keycloak sync](#keycloak-sync) |
| GET | `/api/v1/audit-events` | admin | [Audit log](#audit-log) |
| GET | `/api/v1/operations/status` | admin or ops | [Operations](#operations-backups-and-databases) |
| PUT | `/api/v1/operations/settings` | ops | [Operations](#operations-backups-and-databases) |
| GET, POST | `/api/v1/operations/backups` | ops | [Operations](#operations-backups-and-databases) |
| POST | `/api/v1/operations/backups/download-link` | ops | [Operations](#operations-backups-and-databases) |
| GET | `/api/v1/backup-downloads/{token}` | anyone with the link (rate-limited) | [Operations](#get-apiv1backup-downloadstoken) |
| POST | `/api/v1/integrations/pairing/redeem` | pairing token (rate-limited) | [Integration](#integration-api-for-paired-modules) |
| GET | `/api/v1/integrations/bundle`, `/settings`, `/module-settings` | module credential | [Integration](#integration-api-for-paired-modules) |
| GET | `/api/v1/integrations/module-settings/secrets` | module credential | [Integration](#get-apiv1integrationsmodule-settingssecrets) |
| GET | `/api/v1/integrations/branding/profile`, `/assets`, `/assets/{id}` | module credential | [Integration](#integration-api-for-paired-modules) |
| GET, PUT | `/api/v1/integrations/user-preferences` | module credential | [Integration](#integration-api-for-paired-modules) |

---

## Health

`/livez` and `/readyz` are for Kubernetes' probes and are not under `/api/`,
so they are only reachable on the backend itself, not through Den's web
address. To try them from your computer, forward the port first:

```sh
kubectl port-forward -n conservices-den deploy/den-backend 8090:8080
curl -sk https://localhost:8090/livez
```

The backend serves HTTPS with a certificate for its service name, not for
`localhost`, so `-k` skips the name check for this local test only.

`/api/health` works through the web address.

### `GET /livez`

Is the process running? Never touches the database. **Auth:** none.
Used by the liveness probe.

```sh
curl -sk https://localhost:8090/livez
```

The backend serves HTTPS with a certificate for its service name, not for
`localhost`, so `-k` skips the name check for this local test only.

```json
{ "status": "ok", "version": "dev", "uptime_sec": 5321 }
```

### `GET /readyz`

Can Den serve traffic? Pings the database (2-second limit). **Auth:** none.
Used by the readiness probe.

```sh
curl -sk https://localhost:8090/readyz
```

```json
{ "status": "ok", "database": "ok", "version": "dev" }
```

When the database does not answer: status `503` with
`{"status":"degraded","database":"down","version":"dev"}`.

### `GET /api/health`

The same check as `/readyz` plus `uptime_sec`. **Auth:** none.

```sh
curl $DEN/api/health
```

```json
{ "status": "ok", "database": "ok", "version": "dev", "uptime_sec": 5321 }
```

### `GET /api/role-catalog`

Den's roles and the identity-provider groups that grant them, so tools such
as HR can offer them when creating accounts. **Auth:** none.

```sh
curl $DEN/api/role-catalog
```

```json
{
  "module": "den",
  "display_name": "Den",
  "description": "Convention portal: home, modules, branding.",
  "roles": [
    {
      "key": "admin",
      "label": "Convention admin",
      "description": "Manage modules, pairing, branding, settings and the audit log.",
      "group": "den-admin",
      "assignable": true,
      "scope": "organization",
      "permissions": ["modules.manage", "branding.manage", "settings.manage", "audit.view"]
    },
    {
      "key": "ops",
      "label": "Operations",
      "description": "Runs and downloads backups, changes the backup schedule and deletes module databases.",
      "group": "den-ops",
      "assignable": true,
      "scope": "organization",
      "permissions": ["backups.manage", "databases.drop"]
    },
    {
      "key": "member",
      "label": "Member",
      "description": "Sees the portal home and the services they have a role in.",
      "group": "den-member",
      "assignable": true,
      "default": true,
      "scope": "organization",
      "permissions": ["portal.view"]
    }
  ]
}
```

`group` is the first group in `DEN_ADMIN_GROUPS` / `DEN_OPS_GROUPS` /
`DEN_MEMBER_GROUPS`. With no member group, the member role has
`"group": ""`, `"assignable": false` and a `note` saying it is automatic for
every signed-in user; with no ops group the ops role is not assignable and
its `note` says nobody can run backups.

---

## You

### `GET /api/v1/me`

Who am I? **Auth:** signed in.

```sh
curl -H "Authorization: Bearer $TOKEN" $DEN/api/v1/me
```

```json
{
  "id": "6f1c2b9e-3a7d-4f0e-9b8a-1d2c3e4f5a6b",
  "display_name": "Dev Admin",
  "email": "admin@conservices.local",
  "issuer": "https://auth.conservices.test/realms/conservices",
  "subject": "0b6e2c4d-8f1a-4b3c-9d7e-5a6b7c8d9e0f",
  "memberships": [
    { "organization_id": "00000000-0000-0000-0000-00000000d001", "role": "admin" }
  ],
  "roles": ["admin", "ops"]
}
```

`memberships` is empty for someone who signed in but has no role. `roles`
lists every role: the membership role plus roles granted from groups for
this request only (`ops`).

### `GET /api/v1/me/preferences`

Your saved preferences. **Auth:** signed in.

```sh
curl -H "Authorization: Bearer $TOKEN" $DEN/api/v1/me/preferences
```

```json
{ "theme": "dark", "updated_at": "2026-11-06T09:12:44Z" }
```

Nothing saved yet: `{"theme":"system","updated_at":null}`.

### `PUT /api/v1/me/preferences`

Save your theme. **Auth:** signed in.

| Field | Type | Required | Values |
| --- | --- | --- | --- |
| `theme` | string | yes | `system`, `light` or `dark` |

```sh
curl -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"theme":"dark"}' $DEN/api/v1/me/preferences
```

Returns the saved preferences, as `GET`. Errors: `422` with
`details.theme = "must be system, light or dark"`.

### `GET /api/v1/dashboard`

Everything the portal home needs. **Auth:** member.

```sh
curl -H "Authorization: Bearer $TOKEN" $DEN/api/v1/dashboard
```

```json
{
  "organization": {
    "id": "00000000-0000-0000-0000-00000000d001",
    "slug": "default",
    "display_name": "Con Services"
  },
  "copy": {
    "convention_name": "Con Services",
    "tagline": "Your home for inventory, events, and crew tools.",
    "welcome": "Welcome back"
  },
  "brand": { "theme": { "primary": "#5048e5" }, "typography": {}, "copy": { "convention_name": "Con Services" } },
  "usable_modules": [
    {
      "id": "3d2c1b0a-9f8e-4d7c-b6a5-0f1e2d3c4b5a",
      "slug": "hr",
      "display_name": "HR",
      "base_url": "https://hr.conservices.test",
      "environment": "production",
      "status": "paired",
      "enabled": true
    }
  ],
  "identity_links": {
    "account_console_url": "https://auth.conservices.test/realms/conservices/account",
    "sso_name": "Con Services account",
    "idp_admin_console_url": "https://auth.conservices.test/admin/master/console/#/conservices"
  },
  "users": 2,
  "modules": 3,
  "paired_modules": 1,
  "unpaired_modules": 2
}
```

- `usable_modules` lists modules that are enabled, paired and have a
  `base_url`, **and that this person may use**: modules with
  `portal_visibility` `everyone`, or `role_holders` modules whose role
  catalog (`GET <module>/api/role-catalog`, fetched by Den and cached for 5
  minutes) names one of the person's groups. Admins see every usable
  module. A module whose catalog Den cannot read is hidden from members
  until it can.
- `identity_links` comes from [Module settings](#module-settings) →
  `identity`; `idp_admin_console_url` is only sent to admins. Empty `{}`
  when nothing is set.
- `brand` is the latest branding revision as stored; it is missing if there
  is none.
- `copy.convention_name` falls back to a `copy.event_name` key, if present.
- `users`, `modules`, `paired_modules` and `unpaired_modules` are only sent
  to admins. `users` counts people with a role in the organisation.

### `GET /api/v1/portal/todos`

The signed-in person's to-dos from every module they may use (the same
modules as `usable_modules`). **Auth:** member.

Den's backend calls each module itself; the browser only talks to Den, and
no user token leaves Den. For each module Den sends
`GET <internal_url or base_url>/api/portal/todos` with:

| Header | Value |
| --- | --- |
| `Authorization` | `Bearer <the module's pairing credential>` |
| `X-Den-User-Issuer` | the person's token issuer, e.g. `https://auth.conservices.test/realms/conservices` |
| `X-Den-User-Subject` | the person's subject (`sub`) |

Den can only present a credential it derived itself, so this needs
`DEN_CREDENTIAL_KEY` (see [Configuration](configuration.md)); modules
paired before the key was set report `not_paired_for_todos` until they are
paired again. The module contract is described in
[API conventions](../../concepts/api-conventions.md#portal-to-dos).

```sh
curl -H "Authorization: Bearer $TOKEN" $DEN/api/v1/portal/todos
```

```json
{
  "enabled": true,
  "items": [
    {
      "id": "shift-42",
      "title": "Confirm your Saturday shift",
      "detail": "Info desk, 10:00–14:00",
      "due_at": "2026-11-14T10:00:00Z",
      "url": "https://hr.conservices.test/shifts/42",
      "severity": "warning",
      "module_slug": "hr",
      "module_name": "HR"
    }
  ],
  "modules": [
    { "slug": "hr", "display_name": "HR", "status": "ok", "count": 1 },
    { "slug": "stash", "display_name": "Stash", "status": "unsupported", "count": 0 }
  ],
  "responded": 1
}
```

- Items are sorted by `due_at` (missing dates last), then severity
  (`danger`, `warning`, `info`). Items without `id`, `title` or an
  `http(s)` `url` are dropped, an unknown `severity` becomes `info`, an
  unreadable `due_at` becomes `null`; at most 50 items per module.
- `modules[].status`: `ok`, `unsupported` (the module answered 404 or 501),
  `not_paired_for_todos` (pair the module again) or `error` (no answer
  within 5 seconds, another error, or an address that is not https outside
  development).
- Without `DEN_CREDENTIAL_KEY`: `{"enabled": false, "items": [], "modules": []}`.

---

## Modules

All module endpoints need the **admin** role.

### The module object

```json
{
  "id": "3d2c1b0a-9f8e-4d7c-b6a5-0f1e2d3c4b5a",
  "organization_id": "00000000-0000-0000-0000-00000000d001",
  "slug": "hr",
  "display_name": "HR",
  "base_url": "https://hr.conservices.test",
  "internal_url": "https://hr-backend.conservices-hr.svc.cluster.local:8080",
  "environment": "production",
  "enabled": true,
  "status": "paired",
  "portal_visibility": "role_holders",
  "manifest": {},
  "last_seen_at": "2026-11-06T09:00:03Z",
  "created_at": "2026-11-03T18:20:11Z",
  "updated_at": "2026-11-06T09:00:03Z",
  "database": "hr",
  "database_created_by_den": true
}
```

| Field | Meaning |
| --- | --- |
| `slug` | Short name: lowercase letters, digits and single hyphens, at most 40 characters. Unique together with `environment`. |
| `base_url` | Public address; the portal links here. May be empty. Must be `https://` (`http://` only with `APP_ENV=development`), without user name, query or fragment; a trailing `/` is removed. |
| `internal_url` | Where Den itself calls the module (role catalog, portal to-dos), for example its in-cluster address. Empty: `base_url`. Same rules as `base_url`. |
| `environment` | Free label, `production` by default. |
| `enabled` | Whether the module may appear on the portal. |
| `status` | `unpaired` until a pairing URL is redeemed, then `paired`; `unpaired` again when every credential is revoked. |
| `portal_visibility` | Who sees the module on the portal: `role_holders` (default; people with a group from the module's role catalog) or `everyone` (every member, for modules without a basic user role such as Learn). Also decides whose preferences the module may read. |
| `manifest` | Reserved; currently always `{}`. |
| `last_seen_at` | When the module last paired. Omitted if it never did. |
| `database` | The module's database on the shared server: the one Den created, else the slug with `-` turned into `_`. |
| `database_created_by_den` | `true` only when Den created the database. Only then can Den delete it. |

### `GET /api/v1/modules`

All modules, sorted by display name.

```sh
curl -H "Authorization: Bearer $TOKEN" $DEN/api/v1/modules
```

Returns an array of module objects.

### `GET /api/v1/modules/{id}`

One module.

```sh
curl -H "Authorization: Bearer $TOKEN" $DEN/api/v1/modules/3d2c1b0a-9f8e-4d7c-b6a5-0f1e2d3c4b5a
```

Errors: `400 invalid id id` (not a UUID), `404 module not found`.

### `POST /api/v1/modules`

Register a module.

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `slug` | string | yes | Trimmed; see the module object for the rules. |
| `display_name` | string | yes | Trimmed. |
| `base_url` | string | no | Public address, `https://`. |
| `internal_url` | string | no | Where Den calls the module, `https://`. |
| `environment` | string | no | Default `production`. |
| `portal_visibility` | string | no | `role_holders` (default) or `everyone`. |
| `create_database` | bool | no | Ask the operator for a database and login, named after the slug. |

```sh
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"slug":"hr","display_name":"HR","base_url":"https://hr.conservices.test","create_database":true}' \
  $DEN/api/v1/modules
```

`201 Created`:

```json
{
  "id": "3d2c1b0a-9f8e-4d7c-b6a5-0f1e2d3c4b5a",
  "database": {
    "name": "hr",
    "username": "hr",
    "password": "<generated, shown once>",
    "database_url": "postgres://hr:<password>@postgres:5432/hr?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt"
  }
}
```

`database` is only present with `create_database`. **The password is shown
only in this response.**

Errors:

| Status | Message |
| --- | --- |
| 422 | `validation failed`, with `details` per field, for example `{"slug": "must be lowercase letters, digits and single hyphens (at most 40), for example \"rally\"", "base_url": "must use https (http is only allowed with APP_ENV=development), got \"http://hr.example.org\""}` |
| 409 | `a module with this slug and environment already exists` |
| 409 | `Den doesn't manage databases in this installation` (asked for a database, but no operator) |
| 409 | `a database with this name already exists` |
| 400 | `database names use lowercase letters, digits and _ and must not be a protected database` |
| 502 | `Can't reach the operator: …` |

If the database cannot be created, the module is not registered either.
The registration is written to the [audit log](#audit-log) (`module.create`).

### `PATCH /api/v1/modules/{id}`

Change a module. Send only the fields to change.

| Field | Type |
| --- | --- |
| `display_name` | string, not empty |
| `base_url` | string, `https://` or `""` |
| `internal_url` | string, `https://` or `""` |
| `environment` | string, not empty |
| `enabled` | bool |
| `portal_visibility` | `role_holders` or `everyone` |

```sh
curl -X PATCH -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"enabled":false,"portal_visibility":"everyone"}' $DEN/api/v1/modules/3d2c1b0a-9f8e-4d7c-b6a5-0f1e2d3c4b5a
```

```json
{ "id": "3d2c1b0a-9f8e-4d7c-b6a5-0f1e2d3c4b5a" }
```

Errors: `400 invalid id id`, `404 module not found` (also for a module of
another organisation), `422 validation failed` with `details`, `409` for a
duplicate environment. The change is audited (`module.update`) with the old
and new values.

!!! note
    Disabling a module hides it from the portal. It does not stop a paired
    module from using its credential.

### `DELETE /api/v1/modules/{id}`

Remove a module and its pairing credentials. By default its data is kept.

| Query parameter | Meaning |
| --- | --- |
| `database=drop` | Also delete the module's database and login. Needs the **ops** role, and only works for a database Den created (`database_created_by_den`). The operator backs it up first; if the backup fails, nothing is deleted. |
| `confirm=<slug>` | Required with `database=drop`: the module's slug. |

```sh
# keep the data
curl -X DELETE -H "Authorization: Bearer $TOKEN" $DEN/api/v1/modules/3d2c1b0a-9f8e-4d7c-b6a5-0f1e2d3c4b5a

# delete the data too
curl -X DELETE -H "Authorization: Bearer $TOKEN" \
  "$DEN/api/v1/modules/3d2c1b0a-9f8e-4d7c-b6a5-0f1e2d3c4b5a?database=drop&confirm=hr"
```

```json
{ "database_dropped": true, "database": "hr", "backup_key": "pre-drop/hr/20261106T091500Z.tar.age" }
```

Without `database=drop`: `{"database_dropped": false}`.

Errors:

| Status | Message |
| --- | --- |
| 404 | `module not found` |
| 403 | `deleting a module's database needs the ops role` |
| 409 | `Den did not create this module's database, so it will not delete it` |
| 422 | `type the module's slug to confirm deleting its data` |
| 409 | `Den doesn't manage databases in this installation` |
| 409 | `this database is protected` |
| 409 | `a backup or database removal is already running` |
| 404 | `backup not found` (the operator has no database by that name) |
| 502 | `backup before removal failed, nothing was deleted: …` |

### `POST /api/v1/modules/{id}/pairing-tokens`

Create a one-time pairing URL for the module. See
[Pairing](../../concepts/pairing.md). No body.

```sh
curl -X POST -H "Authorization: Bearer $TOKEN" \
  $DEN/api/v1/modules/3d2c1b0a-9f8e-4d7c-b6a5-0f1e2d3c4b5a/pairing-tokens
```

`201 Created`:

```json
{
  "token_id": "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",
  "module_id": "3d2c1b0a-9f8e-4d7c-b6a5-0f1e2d3c4b5a",
  "token": "<43 characters, shown once>",
  "pairing_url": "https://den.conservices.test/api/v1/integrations/pairing/redeem?token=<token>",
  "expires_at": "2026-11-06T10:30:00Z"
}
```

The URL starts with `APP_BASE_URL` and is valid for 15 minutes, once.
Errors: `400 invalid id id`, `404 module not found`. Minting is audited
(`pairing.token.create`, with you as the actor); the token itself is never
logged.

### `GET /api/v1/modules/{id}/credentials`

The module's pairing credentials, newest first, including revoked ones. The
credential values are never shown again after pairing. **Auth:** admin.

```sh
curl -H "Authorization: Bearer $TOKEN" $DEN/api/v1/modules/3d2c1b0a-9f8e-4d7c-b6a5-0f1e2d3c4b5a/credentials
```

```json
[
  {
    "id": "8c1d2e3f-4a5b-4c6d-8e7f-9a0b1c2d3e4f",
    "label": "pairing-20261111-101500 v1.0.0",
    "created_at": "2026-11-11T10:15:00Z",
    "last_used_at": "2026-11-11T10:16:02Z",
    "revoked_at": null
  },
  {
    "id": "1b2c3d4e-5f6a-4b7c-8d9e-0f1a2b3c4d5e",
    "label": "pairing-20261105-090000",
    "created_at": "2026-11-05T09:00:00Z",
    "last_used_at": "2026-11-11T10:14:58Z",
    "revoked_at": "2026-11-11T10:15:00Z"
  }
]
```

Pairing again revokes every older credential in the same step, so normally
only the newest is active. Errors: `404 module not found`.

### `DELETE /api/v1/modules/{id}/credentials`

Revoke **every** active credential of the module, for example when one may
have leaked. The module is disconnected at once (its calls get `401`) and
its status becomes `unpaired`. Den never pairs it again by itself: an admin
creates a new pairing URL and pastes it into the module. **Auth:** admin.

```sh
curl -X DELETE -H "Authorization: Bearer $TOKEN" $DEN/api/v1/modules/3d2c1b0a-9f8e-4d7c-b6a5-0f1e2d3c4b5a/credentials
```

```json
{ "revoked": 1, "module_status": "unpaired" }
```

`revoked` is `0` when nothing was active. Audited as
`module.credentials.revoke_all`. Errors: `404 module not found`.

### `DELETE /api/v1/modules/{id}/credentials/{credentialID}`

Revoke one credential. When it was the last active one, the module becomes
`unpaired`. **Auth:** admin.

```sh
curl -X DELETE -H "Authorization: Bearer $TOKEN" \
  $DEN/api/v1/modules/3d2c1b0a-9f8e-4d7c-b6a5-0f1e2d3c4b5a/credentials/8c1d2e3f-4a5b-4c6d-8e7f-9a0b1c2d3e4f
```

```json
{ "revoked": 1, "module_status": "unpaired" }
```

Revoking an already revoked credential answers `{"revoked": 0, …}`.
Audited as `module.credential.revoke`. Errors: `400 invalid credentialID
id`, `404 module not found`, `404 credential not found`.

**Rotating** a credential means pairing again: create a pairing URL and
paste it into the module; the new credential replaces the old one
atomically. See the
[runbook for a leaked pairing URL or credential](../../operations/disaster-recovery.md#a-pairing-url-or-module-credential-leaked).

---

## Branding

All branding endpoints for people need the **admin** role. The public and
module versions are further below.

### The branding profile

```json
{
  "revision": 10,
  "theme": { "primary": "#e44763", "dark": { "page": "#0f0e12" } },
  "typography": { "heading_font": "Montserrat", "body_font": "Inter" },
  "copy": { "convention_name": "Example Con 2027", "tagline": "See you there." },
  "updated_at": "2026-11-06T09:41:27Z"
}
```

Every save creates a new **revision**; old ones are kept. The keys Den
understands are listed in the [admin guide](admin-guide.md#branding); any
other keys are stored and passed on as they are.

### `GET /api/v1/brand/profile`

The latest revision.

```sh
curl -H "Authorization: Bearer $TOKEN" $DEN/api/v1/brand/profile
```

Errors: `404 branding profile not found` (only if the seed revision was
removed).

### `PUT /api/v1/brand/profile`

Save a new revision.

| Field | Type | Notes |
| --- | --- | --- |
| `theme` | object | Missing means `{}`. |
| `typography` | object | Missing means `{}`. |
| `copy` | object | Missing means `{}`. |

Each save replaces all three, so send the whole profile.

```sh
curl -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"theme":{"primary":"#e44763"},"typography":{},"copy":{"convention_name":"Example Con 2027"}}' \
  $DEN/api/v1/brand/profile
```

`201 Created`: `{"revision": 11}`. Paired modules pick it up within a
minute; the Keycloak sign-in page right away.

### `GET /api/v1/brand/assets`

Every uploaded asset, newest first within each role.

```sh
curl -H "Authorization: Bearer $TOKEN" $DEN/api/v1/brand/assets
```

```json
[
  {
    "id": "9e8d7c6b-5a4f-4e3d-2c1b-0a9f8e7d6c5b",
    "role": "logo",
    "content_type": "image/svg+xml",
    "size_bytes": 4821,
    "url": "/api/v1/brand/assets/9e8d7c6b-5a4f-4e3d-2c1b-0a9f8e7d6c5b",
    "created_at": "2026-11-05T20:02:13Z"
  }
]
```

### `POST /api/v1/brand/assets`

Upload an asset, as `multipart/form-data`.

| Field | Required | Notes |
| --- | --- | --- |
| `role` | yes | `logo`, `favicon` or `login-background`; anything else is refused. |
| `file` | yes | Up to 10 MB. PNG, JPEG, WebP, ICO or SVG. Den recognises the type from the file's content, not from its name or the `Content-Type` the client sends, and stores the detected type. |

```sh
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -F role=logo -F file=@logo.svg $DEN/api/v1/brand/assets
```

`201 Created`: `{"id": "9e8d7c6b-5a4f-4e3d-2c1b-0a9f8e7d6c5b"}`. The newest
asset of a role is the one in use. Audited as `branding.asset.create`.

Errors: `400 invalid multipart form: …`, `422 file is required`, and `422
validation failed` with `details.role = "must be logo, favicon or
login-background"`, `details.file = "must be a PNG, JPEG, WebP, ICO or SVG
image"` or `details.file = "must be at most 10 MB"`.

### `GET /api/v1/brand/assets/{id}`

The file itself, with its content type,
`X-Content-Type-Options: nosniff` and
`Cache-Control: public, max-age=86400`. SVG files are served with
`Content-Disposition: attachment` and
`Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; sandbox`:
`<img>` tags show them, but opening one directly runs nothing. A file
stored with any other type (from before the type check) is served as
`application/octet-stream` and as an attachment.

```sh
curl -H "Authorization: Bearer $TOKEN" -o logo.svg \
  $DEN/api/v1/brand/assets/9e8d7c6b-5a4f-4e3d-2c1b-0a9f8e7d6c5b
```

Errors: `400 invalid id id`, `404 asset not found`.

### `DELETE /api/v1/brand/assets/{id}`

Delete an asset and its file.

```sh
curl -X DELETE -H "Authorization: Bearer $TOKEN" \
  $DEN/api/v1/brand/assets/9e8d7c6b-5a4f-4e3d-2c1b-0a9f8e7d6c5b
```

`204 No Content`. Errors: `400 invalid id id`, `404 asset not found`.
Audited as `branding.asset.delete`.

### `GET /api/v1/public/brand`

The **brand bundle** for screens shown before sign-in, including the
Keycloak sign-in page, whose `conservices` theme fetches it in the browser.
**Auth:** none. Cached for 60 seconds (`Cache-Control: public, max-age=60`).
Any web page may read it: the answer carries
`Access-Control-Allow-Origin: *` (without credentials; origins in
`CORS_ALLOWED_ORIGINS` get their usual credentialed answer).
Rate-limited to 120 requests a minute per address.

```sh
curl $DEN/api/v1/public/brand
```

```json
{
  "revision": 10,
  "updated_at": "2026-11-06T09:41:27Z",
  "organization_name": "Example Con e.V.",
  "theme": { "primary": "#e44763" },
  "typography": { "heading_font": "Montserrat", "body_font": "Inter" },
  "copy": { "convention_name": "Example Con 2027" },
  "assets": {
    "logo": "9e8d7c6b-5a4f-4e3d-2c1b-0a9f8e7d6c5b",
    "login-background": "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
  },
  "logo_url": "/api/v1/public/brand/assets/logo",
  "favicon_url": "/api/v1/public/brand/assets/favicon?v=5d4c3b2a-1f0e-4d9c-8b7a-6f5e4d3c2b1a",
  "login_background_url": "/api/v1/public/brand/assets/login-background?v=1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
}
```

- `assets` maps each role to its newest asset.
- `logo_url`, `favicon_url` and `login_background_url` are relative to Den,
  and only present when that asset exists.
- `organization_name` is the `organization_name` setting, else
  `copy.convention_name`, else the organisation's name in Den.

### `GET /api/v1/public/brand/assets/{role}`

The newest asset of a role, for example `logo`. **Auth:** none. Same
headers as [`GET /api/v1/brand/assets/{id}`](#get-apiv1brandassetsid).

```sh
curl -o logo.svg $DEN/api/v1/public/brand/assets/logo
```

Errors: `404 asset not found` (also for a role other than `logo`,
`favicon` and `login-background`), `429 rate_limited`.

---

## Organisation settings

The **organisation settings** are one JSON document for the whole
installation. Den is the source of truth; paired modules read it through
[`/api/v1/integrations/bundle`](#get-apiv1integrationsbundle) and show these
fields as "Managed in Den". Den checks and cleans the keys it knows and
stores any other key as it is, so a module can add its own setting without
a Den release.

| Key | Type | Rules | Read by |
| --- | --- | --- | --- |
| `organization_name` | string | Trimmed. | Every module (emails, sign-in pages); also the Keycloak realm display name when the name sync is on. |
| `org_email_domain` | string | A domain like `example.org`; lower-cased, a leading `@` is removed. | HR (organisation emails). |
| `username_template` | string | Letters, digits, `.`, `-`, `_`, and at least one of `{first}`, `{last}`, `{nickname}`. | HR (login names). |
| `org_email_template` | string | Same as `username_template`. | HR (organisation email suggestions). |
| `events_public_schedule` | bool | `true` or `false`. | Rally: switches the [public schedule API](../rally/api.md#public-schedule-api). |
| `wiki_public_links` | bool | `true` or `false`. | Wiki: allows public share links. |

A known key set to `null` is removed. Strings that are not strings, or
booleans that are not booleans, give `422`.

### `GET /api/v1/org-settings`

**Auth:** admin.

```sh
curl -H "Authorization: Bearer $TOKEN" $DEN/api/v1/org-settings
```

```json
{
  "data": {
    "organization_name": "Example Con e.V.",
    "org_email_domain": "example.org",
    "username_template": "{nickname}"
  },
  "updated_at": "2026-11-06T09:44:02Z"
}
```

Never saved: `{"data":{},"updated_at":null}`.

### `PUT /api/v1/org-settings`

Replace the whole settings document. **Auth:** admin.

The body is the document itself (not wrapped in `data`). Known keys are
checked and cleaned up; other keys are stored as they are. The keys and
rules are listed in the
[admin guide](admin-guide.md#organisation-settings).

```sh
curl -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"organization_name":"Example Con e.V.","org_email_domain":"@Example.org","events_public_schedule":true}' \
  $DEN/api/v1/org-settings
```

Returns the saved document, as `GET` (here with `org_email_domain` stored as
`example.org`), and triggers a Keycloak name sync. The change is audited
(`org_settings.update`) with the old and new document.

Validation errors are `422` with one message per key:

```json
{
  "error": {
    "code": "validation_failed",
    "message": "validation failed",
    "details": {
      "org_email_domain": "must be a domain like example.org",
      "wiki_public_links": "must be true or false"
    }
  }
}
```

---

## Module settings

**Module settings** are the settings every module must follow, decided once
in Den: retention periods, the e-mail server, Finance's seller details,
Stash's Lost & Found retention, Wiki's revision history, Tasks' retention
and reminders, Rally's submission site, plus Den's own identity links. The
keys, meanings and defaults are the
[module settings contract](../../concepts/module-settings.md); Den stores
one document for the organisation and gives each module `retention`,
`smtp` and only its own section. Every section and every field is
optional; a missing value means "the module decides". Unknown fields are
refused (`400`).

| Section | Fields | Rules | Given to |
| --- | --- | --- | --- |
| `retention` | `offboarded_volunteers_days`, `inactive_users_days`, `module_data_days` | Whole days, 0–3650. | every module |
| `smtp` | `host` (host name), `port` (1–65535, default `587`), `security` (`starttls` default, `tls`, or `none` only with `APP_ENV=development`), `username` (at most 256), `from` (e-mail address), `from_name` (at most 200) | Do not send `password`. A body that contains `smtp.password` (a string or `null`) is `422`: the password is the secret `DEN_SMTP_PASSWORD` or `DEN_SMTP_PASSWORD_FILE`, not a module setting. Answers show `password_set` instead, true when that secret has a value. Removing the section does not change the password. | every module; the password only through [`GET /api/v1/integrations/module-settings/secrets`](#get-apiv1integrationsmodule-settingssecrets) |
| `finance` | `seller`: `legal_name` (at most 200), `address` (multi-line, at most 1000), `country`, `vat_id`, `tax_number` (at most 64), `registration` (at most 200), `email`, `website` | `country`: two-letter ISO code, upper-cased. `vat_id`: spaces, `.` and `-` removed, upper-cased, starts with a country code (`ATU12345678`). `website`: `https://` (http only in development). | slug `finance` |
| `stash` | `lost_found`: `{"mode": "kept_after_con", "days": N}` (0–3650, default 30) or `{"mode": "deleted_after_closing", "hours": N}` (0–8760, default 48) | | slug `stash` |
| `wiki` | `revision_retention_days` | 0–3650; `0` keeps every revision. | slug `wiki` |
| `tasks` | `trash_days`, `notification_days`, `audit_days`, `automation_run_days` (0–3650), `due_soon_days` (0–30) | Whole days. `0` keeps forever (retention) or sends no reminder. Defaults when Tasks itself decides: trash 30, notifications 90, audit 730, automation runs 90, due soon 1. | slug `tasks` |
| `rally` | `submission_site_host` | A host name without `https://`, e.g. `submit.example.org`. | slug `events` (or `rally`) |
| `identity` | `account_console_url`, `sso_name` (at most 100), `idp_admin_console_url` | URLs `https://` (http only in development). The admin console link in Den's menu and the account link on the portal come from here. | no module; Den's portal (`identity_links`) |

Den sets the defaults shown when a section is given without them (an SMTP
host without port and security, a Lost & Found mode without its number).
Existing settings saved by an earlier Den (`lost_and_found`,
`seller_name`, …) are converted to these keys by a database migration on
upgrade.

### `GET /api/v1/module-settings`

**Auth:** admin.

```sh
curl -H "Authorization: Bearer $TOKEN" $DEN/api/v1/module-settings
```

```json
{
  "data": {
    "retention": { "offboarded_volunteers_days": 365, "inactive_users_days": 730 },
    "smtp": { "host": "smtp.example.org", "port": 587, "security": "starttls", "username": "noreply", "password_set": true, "from": "noreply@example.org", "from_name": "Example Con" },
    "finance": { "seller": { "legal_name": "Example Con e.V.", "address": "Main Street 1\n1010 Vienna", "country": "AT", "vat_id": "ATU12345678" } },
    "stash": { "lost_found": { "mode": "deleted_after_closing", "hours": 48 } },
    "wiki": { "revision_retention_days": 365 },
    "tasks": { "trash_days": 30, "notification_days": 90, "audit_days": 730, "automation_run_days": 90, "due_soon_days": 1 },
    "rally": { "submission_site_host": "submit.example.org" },
    "identity": {
      "account_console_url": "https://auth.example.org/realms/conservices/account",
      "sso_name": "Example Con account",
      "idp_admin_console_url": "https://auth.example.org/admin/master/console/#/conservices"
    }
  },
  "updated_at": "2026-11-11T12:00:00Z"
}
```

Never saved: `{"data":{},"updated_at":null}`.

### `PUT /api/v1/module-settings`

Replace the whole document. **Auth:** admin. **Body:** `{"data": {…}}`,
the same shape `GET` returns (sending a `GET` answer back, with its
`updated_at`, works; `updated_at` is ignored). Returns the saved document as
`GET`. Audited as `module_settings.update`. The password is not in the
audit log, and this call cannot change it.

```sh
curl -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"data":{"smtp":{"host":"smtp.example.org","username":"noreply","from":"noreply@example.org","from_name":"Example Con"},"rally":{"submission_site_host":"submit.example.org"}}}' \
  $DEN/api/v1/module-settings
```

`password_set` in the answer below is true because `DEN_SMTP_PASSWORD` is
set on this Den. The request does not send a password.

```json
{
  "data": {
    "smtp": { "host": "smtp.example.org", "port": 587, "security": "starttls", "username": "noreply", "password_set": true, "from": "noreply@example.org", "from_name": "Example Con" },
    "rally": { "submission_site_host": "submit.example.org" }
  },
  "updated_at": "2026-11-11T12:05:00Z"
}
```

**Errors:**

| Status | Code | When |
| --- | --- | --- |
| `400` | `bad_request` | The body is not `{"data": {…}}` (for example the old unwrapped document), or has an unknown field. |
| `401` / `403` | `unauthorized` / `forbidden` | Not signed in, or not an admin. |
| `413` | `request_too_large` | The body is larger than 1 MiB. |
| `422` | `validation_failed` | A value breaks a rule in the table above, or the body contains `smtp.password`. |

Validation errors have one message per field, keyed with the dotted key:

```json
{
  "error": {
    "code": "validation_failed",
    "message": "validation failed",
    "details": {
      "smtp.port": "must be between 1 and 65535",
      "smtp.password": "is set with the secret DEN_SMTP_PASSWORD (or DEN_SMTP_PASSWORD_FILE), not in module settings",
      "rally.submission_site_host": "must be a host name without https://, for example submit.example.org"
    }
  }
}
```

### `GET /api/v1/modules/{id}/settings`

Read-only: exactly the `module_settings` that module receives in its bundle
(`retention`, `smtp` with `password_set`, and its own section). **Auth:**
admin.

```sh
curl -H "Authorization: Bearer $TOKEN" $DEN/api/v1/modules/$STASH_ID/settings
```

```json
{
  "data": {
    "retention": { "inactive_users_days": 730 },
    "stash": { "lost_found": { "mode": "deleted_after_closing", "hours": 48 } }
  },
  "updated_at": "2026-11-11T12:00:00Z"
}
```

**Errors:** `404 not_found` when there is no such module. `401` / `403` as
for the other admin routes.

---

## Keycloak sync

The Keycloak sign-in page **pulls** the brand from
[`GET /api/v1/public/brand`](#get-apiv1publicbrand) by itself (see
[ADR 0008](https://github.com/AGlElectronics/den/blob/main/docs/adr/0008-keycloak-branding-pull.md)).
What Den can still push is the realm's **display name**, which Keycloak uses
in its own e-mails and page titles. That sync is on when `KEYCLOAK_ADMIN_URL`,
`KEYCLOAK_REALM`, `KEYCLOAK_CLIENT_ID` and `KEYCLOAK_CLIENT_SECRET` are set,
and always off with `IDENTITY_STAFF_MODE=existing`.

### `GET /api/v1/keycloak-sync`

The state of the display-name sync. **Auth:** admin.

```sh
curl -H "Authorization: Bearer $TOKEN" $DEN/api/v1/keycloak-sync
```

```json
{ "enabled": true, "mode": "pull", "realm": "conservices", "revision": 10, "display_name": "Example Con e.V.", "synced_at": "2026-11-06T09:41:28.512Z" }
```

| Field | Meaning |
| --- | --- |
| `enabled` | Whether the display-name sync runs. |
| `mode` | Always `pull`: the sign-in page fetches the brand itself. |
| `message` | Why the sync is off, when it is (not configured, or identity mode `existing`). |
| `realm` | The realm being updated. |
| `revision` | The branding revision of the last sync. |
| `display_name` | The name last written. |
| `synced_at` | When the last successful sync finished. |
| `last_error` | The error of the last attempt, if it failed. |

Off in identity mode `existing`:

```json
{ "enabled": false, "mode": "pull", "message": "Off because IDENTITY_STAFF_MODE is existing: the realm belongs to your convention and Den never changes it. Its sign-in page shows Den's brand only if the conservices login theme is installed there." }
```

### `POST /api/v1/keycloak-sync`

Sync the display name now and return the result, in the same shape.
**Auth:** admin. It answers `200` even if the sync fails; check
`last_error` and the
[Keycloak sync runbook](../../operations/disaster-recovery.md#the-keycloak-name-sync-fails).
Audited as `keycloak.sync` (background syncs only when the name or the
outcome changes).

```sh
curl -X POST -H "Authorization: Bearer $TOKEN" $DEN/api/v1/keycloak-sync
```

---

## Audit log

Every change made in Den, newest first. Den writes the row in the same
database transaction as the change (operator actions right after the
operator answered). Credentials, tokens and the SMTP password are never
written to it.

### `GET /api/v1/audit-events`

**Auth:** admin.

| Query parameter | Meaning |
| --- | --- |
| `action` | An exact action, or a prefix ending in `*` (`module.*`). |
| `entity_type` | `module`, `branding_profile`, `branding_asset`, `organization`, `backup`. |
| `entity_id` | A UUID, e.g. a module id. |
| `actor_user_id` | A UUID of a user. |
| `since`, `until` | RFC 3339 times; `since` is inclusive, `until` exclusive. |
| `limit` | 1–200, default 50. |
| `cursor` | `next_cursor` of the previous page. |

```sh
curl -H "Authorization: Bearer $TOKEN" "$DEN/api/v1/audit-events?action=module.*&limit=2"
```

```json
{
  "items": [
    {
      "id": "0d1e2f3a-4b5c-4d6e-8f7a-9b0c1d2e3f4a",
      "created_at": "2026-11-11T10:20:00Z",
      "action": "module.update",
      "entity_type": "module",
      "entity_id": "3d2c1b0a-9f8e-4d7c-b6a5-0f1e2d3c4b5a",
      "actor": { "id": "6f1c2b9e-3a7d-4f0e-9b8a-1d2c3e4f5a6b", "display_name": "Dev Admin", "email": "admin@conservices.local" },
      "note": "",
      "before": { "enabled": true, "portal_visibility": "role_holders", "display_name": "HR", "base_url": "https://hr.conservices.test", "internal_url": "", "environment": "production" },
      "after": { "enabled": false, "portal_visibility": "role_holders", "display_name": "HR", "base_url": "https://hr.conservices.test", "internal_url": "", "environment": "production" }
    },
    {
      "id": "5e6f7a8b-9c0d-4e1f-8a2b-3c4d5e6f7a8b",
      "created_at": "2026-11-11T10:15:00Z",
      "action": "module.credentials.revoke_all",
      "entity_type": "module",
      "entity_id": "3d2c1b0a-9f8e-4d7c-b6a5-0f1e2d3c4b5a",
      "actor": { "id": "6f1c2b9e-3a7d-4f0e-9b8a-1d2c3e4f5a6b", "display_name": "Dev Admin" },
      "note": "every credential of hr revoked",
      "after": { "revoked": 1, "status": "unpaired" }
    }
  ],
  "next_cursor": "MjAyNi0xMS0xMVQxMDoxNTowMFosNWU2ZjdhOGItOWMwZC00ZTFmLThhMmItM2M0ZDVlNmY3YThi"
}
```

`actor` is `null` for events Den caused by itself (pre-registration,
background Keycloak syncs). For `pairing.token.redeem` it is the admin who
created the pairing URL. `before` and `after` are left out when empty.
`next_cursor` is missing on the last page.

| Action | When |
| --- | --- |
| `module.create`, `module.update`, `module.delete` | Modules page, API, pre-registration |
| `pairing.token.create`, `pairing.token.redeem` | A pairing URL is created / used (`after.revoked_credentials` counts older credentials revoked) |
| `module.credential.revoke`, `module.credentials.revoke_all` | Modules → Credentials |
| `branding.profile.update`, `branding.asset.create`, `branding.asset.delete` | Branding page |
| `org_settings.update`, `module_settings.update` | Organisation and Module settings pages |
| `keycloak.sync` | "Sync name now", or the background sync when the name or outcome changed |
| `operations.backup.start`, `operations.schedule.update`, `operations.download_link.create`, `operations.backup.download` | Backups page (`note` is the backup key) |

Errors: `400` for a bad `limit`, id, time or cursor (`since must be an RFC
3339 time, e.g. 2026-11-11T00:00:00Z`).

---

## Operations (backups and databases)

These endpoints front Den's operator. They need the **ops** role, except
`GET /operations/status`, which admins may read too (for the backup warning
and the database list). An admin without `ops` gets `403 insufficient role`.
When Den has no operator configured, they answer as described per endpoint
(mostly `409 the operator is not set up`). Backups, schedule changes, link
creation and downloads are written to the [audit log](#audit-log).

### `GET /api/v1/operations/status`

```sh
curl -H "Authorization: Bearer $TOKEN" $DEN/api/v1/operations/status
```

```json
{
  "configured": true,
  "reachable": true,
  "managed_databases": true,
  "backups_enabled": true,
  "target": "http://s3:9000/conservices-backups",
  "recipients": ["age1…"],
  "file_buckets": ["den-data-dev", "hr-data-dev"],
  "same_storage_as_data": true,
  "warning": "Backups are stored on the same S3 service as the live data. If that service is lost, the data and its backups are lost together; move backups to another provider or location.",
  "timezone": "Europe/Vienna",
  "settings": { "hour": 3, "keep_daily": 7, "keep_weekly": 4, "keep_monthly": 6 },
  "last": {
    "kind": "scheduled",
    "started_at": "2026-11-06T02:00:00Z",
    "finished_at": "2026-11-06T02:00:09Z",
    "ok": true,
    "key": "backups/20261106T020000Z-scheduled.tar.age",
    "size_bytes": 1849344,
    "databases": ["den", "hr", "keycloak"],
    "buckets": ["den-data-dev", "hr-data-dev"]
  },
  "last_success": { "…": "same shape as last" },
  "next_run": "2026-11-07T02:00:00Z",
  "databases": [
    { "name": "den", "owner": "den", "size_bytes": 8421376, "protected": true },
    { "name": "hr", "owner": "hr", "size_bytes": 9203712, "protected": false }
  ]
}
```

- `running` is present while a backup or removal is running.
- `problem` is present when backups need attention: the last one failed,
  there has never been one, or the last good one is more than 26 hours old.
- `same_storage_as_data` is `true` when backups go to the same S3 service
  as the module files (`BACKUP_SAME_STORAGE_AS_DATA=true`, or the same
  host and port in `FILES_S3_ENDPOINT` and `BACKUP_S3_ENDPOINT`). Then
  `warning` explains the risk; Den shows it on the Backups page and as a
  banner in the admin area. See
  [Configuration](configuration.md#operator).
- `last` and `last_success` are absent before the first backup.
- `target`, `recipients`, `settings`, `last`, `last_success` and `next_run`
  are absent when backups are turned off.

No operator: `{"configured": false}`. Operator not answering:
`{"configured": true, "reachable": false, "error": "Can't reach the operator: …"}`.
All of these are `200`.

### `PUT /api/v1/operations/settings`

The backup schedule and how many backups to keep.

| Field | Range |
| --- | --- |
| `hour` | 0–23, in the operator's time zone |
| `keep_daily` | 1–365 |
| `keep_weekly` | 0–520 |
| `keep_monthly` | 0–240 |

Send all four; a missing field counts as `0`.

```sh
curl -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"hour":4,"keep_daily":7,"keep_weekly":4,"keep_monthly":12}' \
  $DEN/api/v1/operations/settings
```

Returns the saved settings. Errors: `409 the operator is not set up`,
`400 hour must be 0–23, keep at least 1 daily backup` (any value out of
range), `409 backups are turned off`.

### `GET /api/v1/operations/backups`

Every stored backup.

```sh
curl -H "Authorization: Bearer $TOKEN" $DEN/api/v1/operations/backups
```

```json
[
  { "key": "backups/20261106T020000Z-scheduled.tar.age", "kind": "scheduled", "size_bytes": 1849344, "created_at": "2026-11-06T02:00:09Z" },
  { "key": "pre-drop/hr/20261105T171200Z.tar.age", "kind": "pre-drop", "database": "hr", "size_bytes": 402944, "created_at": "2026-11-05T17:12:00Z" }
]
```

No operator, or backups turned off: `[]`.

### `POST /api/v1/operations/backups`

Start a full backup now. It runs in the background.

```sh
curl -X POST -H "Authorization: Bearer $TOKEN" $DEN/api/v1/operations/backups
```

`202 Accepted`: `{"started": true}`. Errors:
`409 the operator is not set up`, `409 backups are turned off`,
`409 a backup or database removal is already running`.

### `POST /api/v1/operations/backups/download-link`

Create a one-time link to download a backup, valid for 5 minutes.

| Field | Type | Notes |
| --- | --- | --- |
| `key` | string | A `key` from the backup list. |

```sh
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"key":"backups/20261106T020000Z-scheduled.tar.age"}' \
  $DEN/api/v1/operations/backups/download-link
```

```json
{ "url": "/api/v1/backup-downloads/5f0c…9a1e" }
```

The link works once, for 5 minutes. It is stored (as a hash) in Den's
database, so any backend replica can serve it and it survives a restart.
The key is checked only when the link is used. Errors: `422` with
`details.key = "is required"`, `409 the operator is not set up`.

### `GET /api/v1/backup-downloads/{token}`

Download the backup. **Auth:** none; the link is the permission, and it
works once. Rate-limited to 10 a minute per address.

```sh
curl -OJ $DEN/api/v1/backup-downloads/5f0c…9a1e
```

Streams the encrypted file as `application/octet-stream` with a
`Content-Disposition` file name, `X-Content-Type-Options: nosniff` and
`Cache-Control: no-store`. The link is used up before streaming starts, so
an interrupted download needs a new link. The download is audited
(`operations.backup.download`) with the person who created the link.
Errors: `404 download link not found` (unknown, used or expired), `404
backup not found`, `429 rate_limited`.

---

## Integration API for paired modules

These endpoints are for **paired modules**, called from their backends. Apart
from redeem, they need `Authorization: Bearer <module credential>`. Every
answer is limited to the organisation the module belongs to.

### Pairing end to end

**Pairing** connects a module to Den with a one-time URL, so the module
gets a long-lived credential without anyone copying secrets around (see
[Pairing](../../concepts/pairing.md)). The whole flow, with the calls each
side makes:

1. **Register the module** (admin, once):

    ```sh
    curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      -d '{"slug":"hr","display_name":"HR","base_url":"https://hr.conservices.test"}' \
      $DEN/api/v1/modules
    ```

    `{"id":"3d2c1b0a-9f8e-4d7c-b6a5-0f1e2d3c4b5a"}`

2. **Create a pairing URL** (admin). It is valid for 15 minutes, once:

    ```sh
    curl -s -X POST -H "Authorization: Bearer $TOKEN" \
      $DEN/api/v1/modules/3d2c1b0a-9f8e-4d7c-b6a5-0f1e2d3c4b5a/pairing-tokens | jq -r .pairing_url
    ```

    `https://den.conservices.test/api/v1/integrations/pairing/redeem?token=…`

3. **Give the URL to the module.** In the module's web app (Admin → Den)
   paste it, or call the module's own pair endpoint, for example
   [HR's](../hr/api.md#post-apidenpair). The module's backend then calls
   `POST /api/v1/integrations/pairing/redeem?token=…` (below), stores the
   credential, and Den marks the module `paired`.

4. **The module syncs.** It calls
   [`GET /api/v1/integrations/bundle`](#get-apiv1integrationsbundle) right
   away and then every minute, and copies brand assets through
   [`/api/v1/integrations/branding/assets/{id}`](#get-apiv1integrationsbrandingassetsid).

To **unpair**, unpair in the module (it forgets the credential) and
[revoke its credentials](#delete-apiv1modulesidcredentials) or
[delete the module](#delete-apiv1modulesid) in Den. Pairing again with a
new URL revokes the module's older credentials in Den and replaces the
credential on the module's side. Pairing is always started by an admin;
Den never re-pairs a module by itself.

Network policy: the module's namespace needs egress to `den-backend` on
port 8080, and Den's namespace an ingress rule for it; see
[Network policies](../../operations/network-policies.md).

### `POST /api/v1/integrations/pairing/redeem`

Trade a pairing token for a long-lived credential. **Auth:** the token in the
URL. This is the pairing URL from
[`pairing-tokens`](#post-apiv1modulesidpairing-tokens), called with `POST`.
Rate-limited to 10 a minute per address.

| Query parameter | Required |
| --- | --- |
| `token` | yes |

Optional body:

| Field | Type | Notes |
| --- | --- | --- |
| `module_id` | string | If sent, must be the id of the module the URL was made for. |
| `module_slug` | string | If sent, must be that module's slug. |
| `module_version` | string | Added to the credential's label. |

```sh
curl -X POST -H "Content-Type: application/json" \
  -d '{"module_slug":"hr","module_version":"1.4.0"}' \
  "$DEN/api/v1/integrations/pairing/redeem?token=<token>"
```

```json
{
  "credential": "<43 characters, shown once>",
  "credential_id": "b7c8d9e0-f1a2-4b3c-8d4e-5f6a7b8c9d0e",
  "module_id": "3d2c1b0a-9f8e-4d7c-b6a5-0f1e2d3c4b5a",
  "organization_id": "00000000-0000-0000-0000-00000000d001",
  "den_base_url": "https://den.conservices.test"
}
```

**200 OK.** The module is marked `paired` and every older credential of the
module is revoked, all in one transaction: if the same URL is redeemed
twice at the same moment, exactly one call gets a credential and the other
gets `401 pairing token already consumed`. Den stores only a hash of the
credential, so it cannot be shown again. The redeem is audited
(`pairing.token.redeem`) with the admin who created the URL as the actor.

| Status | Message |
| --- | --- |
| 400 | `missing token` |
| 400 | `invalid JSON: …` (the body is not valid JSON, or has an unknown field; an empty body is fine) |
| 401 | `invalid pairing token` |
| 401 | `pairing token already consumed` |
| 401 | `pairing token expired` |
| 409 | `this pairing URL was made for another module (module_id does not match)` |
| 409 | `this pairing URL was made for the module hr, not stash` |
| 429 | `too many requests, try again later` |

A `400` or `409` does not use up the token; paste the URL into the right
module.

In the examples below, `$CRED` is the credential.

### `GET /api/v1/integrations/bundle`

Brand and settings in one call. This is what modules poll, every minute.

```sh
curl -H "Authorization: Bearer $CRED" $DEN/api/v1/integrations/bundle
```

```json
{
  "brand": {
    "revision": 10,
    "updated_at": "2026-11-06T09:41:27Z",
    "organization_name": "Example Con e.V.",
    "theme": { "primary": "#e44763" },
    "typography": { "heading_font": "Montserrat", "body_font": "Inter" },
    "copy": { "convention_name": "Example Con 2027" },
    "assets": { "logo": "9e8d7c6b-5a4f-4e3d-2c1b-0a9f8e7d6c5b" }
  },
  "settings": {
    "data": { "organization_name": "Example Con e.V.", "org_email_domain": "example.org" },
    "updated_at": "2026-11-06T09:44:02Z"
  },
  "module_settings": {
    "data": {
      "retention": { "offboarded_volunteers_days": 365 },
      "smtp": { "host": "smtp.example.org", "port": 587, "security": "starttls", "username": "noreply", "password_set": true, "from": "noreply@example.org", "from_name": "Example Con" },
      "stash": { "lost_found": { "mode": "deleted_after_closing", "hours": 48 } }
    },
    "updated_at": "2026-11-11T12:00:00Z"
  }
}
```

`brand` is the [public brand bundle](#get-apiv1publicbrand) without
`logo_url`, `favicon_url` and `login_background_url`; fetch the files with
the asset endpoint below. `module_settings` is always
`{"data": {…}, "updated_at": "…"}`. `data` holds `retention` and `smtp`
(with `password_set`, never the password) for every module, plus only that
module's own section (`finance.seller` for slug `finance`, `stash.lost_found`
for `stash`, `wiki` for `wiki`, `tasks` for `tasks`, `rally` for slug
`events` or `rally`). `identity` is Den's own and is not included. `data`
is `{}` when nothing is set for that module. A module shows these values
as "Managed in Den" and keeps its own value for anything missing. The
password, when `password_set` is true, comes from
[`GET /api/v1/integrations/module-settings/secrets`](#get-apiv1integrationsmodule-settingssecrets).

### `GET /api/v1/integrations/settings`

Only the organisation settings, as in `bundle.settings`.

```sh
curl -H "Authorization: Bearer $CRED" $DEN/api/v1/integrations/settings
```

### `GET /api/v1/integrations/module-settings`

Only the module settings, as in `bundle.module_settings`: `{"data": {…}, "updated_at": "…"}`.

```sh
curl -H "Authorization: Bearer $CRED" $DEN/api/v1/integrations/module-settings
```

```json
{
  "data": {
    "retention": { "offboarded_volunteers_days": 365 },
    "rally": { "submission_site_host": "submit.example.org" }
  },
  "updated_at": "2026-11-11T12:00:00Z"
}
```

### `GET /api/v1/integrations/module-settings/secrets`

The SMTP password from Den's secret (`DEN_SMTP_PASSWORD`, or the file
`DEN_SMTP_PASSWORD_FILE`). The bundle never carries it (a module stores
the bundle). **Auth:** module credential.
**Response:** `200`, `Cache-Control: no-store`. Keys without a value are
left out, so `{}` means the secret is empty.

```sh
curl -H "Authorization: Bearer $CRED" $DEN/api/v1/integrations/module-settings/secrets
```

```json
{"smtp": {"password": "change-me"}}
```

**Errors:** `401` when the credential is missing or revoked.

Den does not keep the password in its database. The admin API, the bundle
and the audit log never return it. It is as safe as the secret it comes
from ([Secrets](../../operations/secrets.md)): update the secret manager
and restart Den. A mounted `DEN_SMTP_PASSWORD_FILE` is read on each
request, so replacing the file needs no restart.

### `GET /api/v1/integrations/branding/profile`

Only the latest branding profile, as in
[`GET /api/v1/brand/profile`](#get-apiv1brandprofile).

```sh
curl -H "Authorization: Bearer $CRED" $DEN/api/v1/integrations/branding/profile
```

### `GET /api/v1/integrations/branding/assets`

The asset list, as in [`GET /api/v1/brand/assets`](#get-apiv1brandassets),
with `url` pointing at the integration endpoint below.

### `GET /api/v1/integrations/branding/assets/{id}`

An asset file, streamed through Den so modules never need access to Den's
storage.

```sh
curl -H "Authorization: Bearer $CRED" -o logo.svg \
  $DEN/api/v1/integrations/branding/assets/9e8d7c6b-5a4f-4e3d-2c1b-0a9f8e7d6c5b
```

Errors: `400 invalid id id`, `404 asset not found` (also for assets of
another organisation).

### `GET /api/v1/integrations/user-preferences`

A person's preferences, so a module can apply the theme they chose in any
app. The person is identified by the `iss` and `sub` of their token.

A module may only ask about **its own users**: people who signed in to Den
at least once, are not disabled, and may use the module (its
`portal_visibility` is `everyone`, or one of their groups from their last
Den sign-in is in the module's role catalog). Anyone else gives
`404 person for this module not found`; the module keeps the theme locally.
In dev mode (`AUTH_MODE=dev`) the check is off.

| Query parameter | Required |
| --- | --- |
| `issuer` | yes |
| `subject` | yes |

```sh
curl -H "Authorization: Bearer $CRED" \
  "$DEN/api/v1/integrations/user-preferences?issuer=https%3A%2F%2Fauth.conservices.test%2Frealms%2Fconservices&subject=0b6e2c4d-8f1a-4b3c-9d7e-5a6b7c8d9e0f"
```

```json
{ "theme": "dark", "updated_at": "2026-11-06T09:12:44Z" }
```

Errors: `422` with `details.subject = "issuer and subject are required"`,
`404 person for this module not found`.

### `PUT /api/v1/integrations/user-preferences`

Save a person's theme on their behalf.

| Field | Type | Required |
| --- | --- | --- |
| `issuer` | string | yes |
| `subject` | string | yes |
| `theme` | string | yes: `system`, `light` or `dark` |

```sh
curl -X PUT -H "Authorization: Bearer $CRED" -H "Content-Type: application/json" \
  -d '{"issuer":"https://auth.conservices.test/realms/conservices","subject":"0b6e2c4d-8f1a-4b3c-9d7e-5a6b7c8d9e0f","theme":"light"}' \
  $DEN/api/v1/integrations/user-preferences
```

Returns the saved preferences. Errors as for `GET`, plus
`422 details.theme = "must be system, light or dark"`.

---

## Troubleshooting

**`403 insufficient role` on `/modules`, `/brand` or `/org-settings`.**
You need Den's `admin` role: a group from `DEN_ADMIN_GROUPS` (default
`den-admin`) in your token. Call [`GET /api/v1/me`](#get-apiv1me); an empty
`memberships` list means none of your groups matched. Get a new token
after changing groups.

**`401 invalid token` with a token that works in another module.**
Den accepts an **access token** whose audience includes `den-api`
(`OIDC_AUDIENCE`). An ID token, or an access token minted for another
module's audience, is refused. Get a token with `client_id=den-spa` (the
realm's audience mapper adds `den-api`) and send `access_token`.

**A module's pairing fails with `pairing token expired` or `already consumed`.**
Pairing URLs work once and for 15 minutes. Create a new one with
[`POST /api/v1/modules/{id}/pairing-tokens`](#post-apiv1modulesidpairing-tokens).

**A paired module gets `401 invalid or revoked credential`.**
Its credential was revoked (Modules → Credentials, or by pairing it again
elsewhere), or the module was deleted in Den. Check
[`GET /api/v1/modules/{id}/credentials`](#get-apiv1modulesidcredentials),
then pair it again with a new URL (register it first if it was deleted).

**`403 insufficient role` on `/operations/backups`, although you are an admin.**
Backups need the `ops` role: add yourself to a group from `DEN_OPS_GROUPS`
(default `den-ops`) and sign in again. `GET /api/v1/me` shows `"ops"` in
`roles` once it works.

**`429 rate_limited`.**
Wait the seconds in `Retry-After`. If every user behind one proxy shares the
limit, the proxy is not in `TRUSTED_PROXY_CIDRS`, so Den sees the proxy's
address as the client.

**A module is missing from a member's portal.**
The member has none of the groups in the module's role catalog, or Den cannot
read the catalog at the module's `internal_url` (or `base_url`). Check
`curl <address>/api/role-catalog` from the Den backend, or set the module's
`portal_visibility` to `everyone`.

**`409 the operator is not set up`.**
`OPERATOR_URL` is not set, so Den cannot manage databases or backups; see
[Configuration](configuration.md).

**A backup download link answers `404 download link not found`.**
Links work once, for 5 minutes. Create a new one.
