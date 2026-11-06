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

This page lists all **40 endpoints**, taken from
[`backend/internal/http/router.go`](https://github.com/AGlElectronics/den/blob/main/backend/internal/http/router.go)
and its handlers. What all modules share (error shape, request IDs, probes,
how tokens are checked) is on
[API conventions](../../concepts/api-conventions.md); how sign-in works is
on [Authentication](../../concepts/authentication.md).

## Basics

**Base address and routing.** The API is served under Den's own web
address: the ingress sends the request to `den-frontend`, whose nginx
passes everything under `/api/` on to `den-backend`. All examples use the
address of the [local example installation](../../getting-started/den-quickstart.md);
`$DEN` stands for it:

```sh
DEN=https://den.conservices.test
```

| From | Address |
| --- | --- |
| Your computer, scripts, the web app | `https://den.conservices.test` (your own domain in a real installation) |
| Paired modules, inside the cluster | `http://den-backend.conservices-den.svc.cluster.local:8080`, only paths the [network policies](../../operations/network-policies.md) allow |
| Docker Compose development stack | `http://localhost:8090` |

Paths are grouped by caller: `/api/v1/…` for people, `/api/v1/integrations/…`
for paired modules, `/api/v1/public/…` and `/api/v1/backup-downloads/…`
for anyone, plus `/api/health`, `/api/role-catalog` and the root probes.

**Rate limits.** Den does not rate limit any endpoint and never answers
`429`. The public endpoints are cached (`Cache-Control`) instead.

**Request bodies** are JSON (`Content-Type: application/json`), except the
asset upload. Unknown fields are rejected with `400 bad_request`.

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
| `validation_failed` | 422 | The values are not acceptable. |
| `internal` | 500 | Something broke inside Den; the details are in Den's log. |
| `unavailable` | 502 | A service Den depends on (the operator) failed; the message says why. |

The health endpoints `/readyz` and `/api/health` answer `503` with their
normal body when the database is down.

### Authentication

There are three kinds of caller (explained in
[Authentication](../../concepts/authentication.md)):

| Kind | How it authenticates | Used for |
| --- | --- | --- |
| **People** | `Authorization: Bearer <ID token>` from Keycloak (OIDC mode), or `X-Dev-User: <name>` (dev mode). | Everything under `/api/v1` except the integration and public endpoints. |
| **Paired modules** | `Authorization: Bearer <module credential>`. | `/api/v1/integrations/*`. |
| **Anyone** | Nothing. | Health, role catalog, public brand, pairing redeem, backup download links. |

Endpoints for people additionally need a **role** in the default
organisation:

- **signed in**: any authenticated person;
- **member**: `member`, `admin` or `owner`;
- **admin**: `admin` or `owner`.

Authentication errors:

| Status | Message | When |
| --- | --- | --- |
| 401 | `missing bearer token` | No `Authorization: Bearer` header. |
| 401 | `invalid token` | The token is expired, or not from the configured issuer and client. |
| 401 | `invalid or revoked credential` | A module credential Den does not know. |
| 403 | `insufficient role` | Your role is too low for this endpoint. |

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
      | jq -r .id_token)
    ```

=== "Windows (PowerShell)"

    ```powershell
    $TOKEN = (Invoke-RestMethod -Method Post `
      -Uri https://auth.conservices.test/realms/conservices/protocol/openid-connect/token `
      -Body @{ grant_type='password'; client_id='den-spa'; username='admin'; password='adminadmin'; scope='openid' }).id_token
    ```

Den expects the **ID token** (not the access token) as the bearer. The
`curl` examples below use bash syntax and `$TOKEN`. Tokens last 5 minutes in
the local realm.

In dev mode (`AUTH_MODE=dev`) skip the token and send a header instead:
`-H "X-Dev-User: dev-admin"`.

#### Which credential to use

| You are | Use | Get it from |
| --- | --- | --- |
| A person or a script acting as one | Keycloak **ID token** for `den-spa`, with the `admin` role for anything under `/modules`, `/brand`, `/org-settings`, `/keycloak-sync`, `/operations` | The token endpoint above (dev), or your web app sign-in. Roles come from `DEN_ADMIN_GROUPS` (default `den-admin`) and `DEN_MEMBER_GROUPS`. |
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
| GET, POST | `/api/v1/modules` | admin | [Modules](#modules) |
| GET, PATCH, DELETE | `/api/v1/modules/{id}` | admin | [Modules](#modules) |
| POST | `/api/v1/modules/{id}/pairing-tokens` | admin | [Modules](#post-apiv1modulesidpairing-tokens) |
| GET, PUT | `/api/v1/brand/profile` | admin | [Branding](#branding) |
| GET, POST | `/api/v1/brand/assets` | admin | [Branding](#branding) |
| GET, DELETE | `/api/v1/brand/assets/{id}` | admin | [Branding](#branding) |
| GET | `/api/v1/public/brand`, `/api/v1/public/brand/assets/{role}` | anyone | [Branding](#get-apiv1publicbrand) |
| GET, PUT | `/api/v1/org-settings` | admin | [Organisation settings](#organisation-settings) |
| GET, POST | `/api/v1/keycloak-sync` | admin | [Keycloak sync](#keycloak-sync) |
| GET | `/api/v1/operations/status` | admin | [Operations](#operations-backups-and-databases) |
| PUT | `/api/v1/operations/settings` | admin | [Operations](#operations-backups-and-databases) |
| GET, POST | `/api/v1/operations/backups` | admin | [Operations](#operations-backups-and-databases) |
| POST | `/api/v1/operations/backups/download-link` | admin | [Operations](#operations-backups-and-databases) |
| GET | `/api/v1/backup-downloads/{token}` | anyone with the link | [Operations](#get-apiv1backup-downloadstoken) |
| POST | `/api/v1/integrations/pairing/redeem` | pairing token | [Integration](#integration-api-for-paired-modules) |
| GET | `/api/v1/integrations/bundle`, `/settings` | module credential | [Integration](#integration-api-for-paired-modules) |
| GET | `/api/v1/integrations/branding/profile`, `/assets`, `/assets/{id}` | module credential | [Integration](#integration-api-for-paired-modules) |
| GET, PUT | `/api/v1/integrations/user-preferences` | module credential | [Integration](#integration-api-for-paired-modules) |

---

## Health

`/livez` and `/readyz` are for Kubernetes' probes and are not under `/api/`,
so they are only reachable on the backend itself, not through Den's web
address. To try them from your computer, forward the port first:

```sh
kubectl port-forward -n conservices-den deploy/den-backend 8090:8080
curl http://localhost:8090/livez
```

`/api/health` works through the web address.

### `GET /livez`

Is the process running? Never touches the database. **Auth:** none.
Used by the liveness probe.

```sh
curl http://localhost:8090/livez
```

```json
{ "status": "ok", "version": "dev", "uptime_sec": 5321 }
```

### `GET /readyz`

Can Den serve traffic? Pings the database (2-second limit). **Auth:** none.
Used by the readiness probe.

```sh
curl http://localhost:8090/readyz
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
      "description": "Manage modules, pairing, branding and portal settings.",
      "group": "den-admin",
      "assignable": true,
      "scope": "organization",
      "permissions": ["modules.manage", "branding.manage", "settings.manage"]
    },
    {
      "key": "member",
      "label": "Member",
      "description": "Sees the portal home and every usable service.",
      "group": "den-member",
      "assignable": true,
      "default": true,
      "scope": "organization",
      "permissions": ["portal.view"]
    }
  ]
}
```

`group` is the first group in `DEN_ADMIN_GROUPS` / `DEN_MEMBER_GROUPS`. With
no member group, the member role has `"group": ""`, `"assignable": false`
and a `note` saying it is automatic for every signed-in user.

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
  ]
}
```

`memberships` is empty for someone who signed in but has no role.

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
  "organizations": 1,
  "users": 2,
  "modules": 3,
  "paired_modules": 1,
  "unpaired_modules": 2
}
```

- `usable_modules` lists modules that are enabled, paired and have a
  `base_url`.
- `brand` is the latest branding revision as stored; it is missing if there
  is none.
- `copy.convention_name` falls back to a `copy.event_name` key, if present.
- The counts are for the whole installation.

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
  "environment": "production",
  "enabled": true,
  "status": "paired",
  "manifest": {},
  "last_seen_at": "2026-11-06T09:00:03Z",
  "created_at": "2026-11-03T18:20:11Z",
  "updated_at": "2026-11-06T09:00:03Z",
  "database": "hr"
}
```

| Field | Meaning |
| --- | --- |
| `slug` | Short name. Unique together with `environment`. |
| `base_url` | Public address; the portal links here. May be empty. |
| `environment` | Free label, `production` by default. |
| `enabled` | Whether the module may appear on the portal. |
| `status` | `unpaired` until a pairing URL is redeemed, then `paired`. |
| `manifest` | Reserved; currently always `{}`. |
| `last_seen_at` | When the module last paired. Omitted if it never did. |
| `database` | The module's database on the shared server: the one Den created, else the slug with `-` turned into `_`. |

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
| `slug` | string | yes | Trimmed. |
| `display_name` | string | yes | Trimmed. |
| `base_url` | string | no | Public address. |
| `environment` | string | no | Default `production`. |
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
    "database_url": "postgres://hr:<password>@postgres:5432/hr?sslmode=disable"
  }
}
```

`database` is only present with `create_database`. **The password is shown
only in this response.**

Errors:

| Status | Message |
| --- | --- |
| 422 | `slug and display_name are required` |
| 409 | `Den doesn't manage databases in this installation` (asked for a database, but no operator) |
| 409 | `a database with this name already exists` |
| 400 | `database names use lowercase letters, digits and _ and must not be a protected database` |
| 502 | `Can't reach the operator: …` |
| 500 | Registering the same slug and environment twice (not yet reported more clearly). |

If the database cannot be created, the module is not registered either.

### `PATCH /api/v1/modules/{id}`

Change a module. Send only the fields to change.

| Field | Type |
| --- | --- |
| `display_name` | string |
| `base_url` | string |
| `environment` | string |
| `enabled` | bool |

```sh
curl -X PATCH -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"enabled":false}' $DEN/api/v1/modules/3d2c1b0a-9f8e-4d7c-b6a5-0f1e2d3c4b5a
```

```json
{ "id": "3d2c1b0a-9f8e-4d7c-b6a5-0f1e2d3c4b5a" }
```

Errors: `400 invalid id id`, `404 module not found`.

!!! note
    Disabling a module hides it from the portal. It does not stop a paired
    module from using its credential.

### `DELETE /api/v1/modules/{id}`

Remove a module and its pairing credentials. By default its data is kept.

| Query parameter | Meaning |
| --- | --- |
| `database=drop` | Also delete the module's database and login. The operator backs it up first; if the backup fails, nothing is deleted. |
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
Errors: `400 invalid id id`, `404 module not found`.

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
| `role` | yes | `logo`, `favicon` or `login-background` are the roles Den uses. Den does not check the value. |
| `file` | yes | Up to 10 MB. Its content type is stored as sent. |

```sh
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -F role=logo -F file=@logo.svg $DEN/api/v1/brand/assets
```

`201 Created`: `{"id": "9e8d7c6b-5a4f-4e3d-2c1b-0a9f8e7d6c5b"}`. The newest
asset of a role is the one in use.

Errors: `400 invalid multipart form: …`, `422 role is required`,
`422 file is required`.

### `GET /api/v1/brand/assets/{id}`

The file itself, with its content type and
`Cache-Control: public, max-age=86400`.

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

### `GET /api/v1/public/brand`

The **brand bundle** for screens shown before sign-in. **Auth:** none.
Cached for 60 seconds (`Cache-Control: public, max-age=60`).

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
  "login_background_url": "/api/v1/public/brand/assets/login-background?v=1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
}
```

- `assets` maps each role to its newest asset.
- `logo_url` and `login_background_url` are relative to Den, and only
  present when that asset exists.
- `organization_name` is the `organization_name` setting, else
  `copy.convention_name`, else the organisation's name in Den.

### `GET /api/v1/public/brand/assets/{role}`

The newest asset of a role, for example `logo`. **Auth:** none.

```sh
curl -o logo.svg $DEN/api/v1/public/brand/assets/logo
```

Errors: `404 asset not found`.

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
| `organization_name` | string | Trimmed. | Every module (emails, sign-in pages); also the Keycloak realm display name. |
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
`example.org`), and triggers a Keycloak sync.

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

## Keycloak sync

### `GET /api/v1/keycloak-sync`

The state of the brand push into Keycloak. **Auth:** admin.

```sh
curl -H "Authorization: Bearer $TOKEN" $DEN/api/v1/keycloak-sync
```

```json
{ "enabled": true, "realm": "conservices", "revision": 10, "synced_at": "2026-11-06T09:41:28.512Z" }
```

| Field | Meaning |
| --- | --- |
| `enabled` | Whether the sync is configured. `false` is the only field when it is not. |
| `realm` | The realm being updated. |
| `revision` | The branding revision last pushed. |
| `synced_at` | When the last successful push finished. |
| `last_error` | The error of the last attempt, if it failed. |

### `POST /api/v1/keycloak-sync`

Push now and return the result, in the same shape. **Auth:** admin. It
answers `200` even if the push fails; check `last_error`.

```sh
curl -X POST -H "Authorization: Bearer $TOKEN" $DEN/api/v1/keycloak-sync
```

---

## Operations (backups and databases)

These endpoints front Den's operator. They need the **admin** role. When Den
has no operator configured, they answer as described per endpoint (mostly
`409 the operator is not set up`).

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
  "target": "http://minio:9000/conservices-backups",
  "recipients": ["age1…"],
  "file_buckets": ["den-data-dev", "hr-data-dev"],
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

The key is checked only when the link is used. Links are kept in the
backend's memory, so they stop working when it restarts.

### `GET /api/v1/backup-downloads/{token}`

Download the backup. **Auth:** none; the link is the permission, and it
works once.

```sh
curl -OJ $DEN/api/v1/backup-downloads/5f0c…9a1e
```

Streams the encrypted file as `application/octet-stream` with a
`Content-Disposition` file name. Errors: `404 download link not found`
(unknown, used or expired), `404 backup not found`.

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
[delete the module](#delete-apiv1modulesid) in Den, which removes its
credentials. Pairing again with a new URL replaces the module's old
credential on its side.

Network policy: the module's namespace needs egress to `den-backend` on
port 8080, and Den's namespace an ingress rule for it; see
[Network policies](../../operations/network-policies.md).

### `POST /api/v1/integrations/pairing/redeem`

Trade a pairing token for a long-lived credential. **Auth:** the token in the
URL. This is the pairing URL from
[`pairing-tokens`](#post-apiv1modulesidpairing-tokens), called with `POST`.

| Query parameter | Required |
| --- | --- |
| `token` | yes |

Optional body:

| Field | Type | Notes |
| --- | --- | --- |
| `module_version` | string | Added to the credential's label. |
| `module_slug` | string | Accepted but currently unused. |

```sh
curl -X POST -H "Content-Type: application/json" \
  -d '{"module_version":"1.4.0"}' \
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

**200 OK.** The module is marked `paired`. Den stores only a hash of the
credential, so it cannot be shown again. A body that is not valid JSON is
ignored rather than rejected.

| Status | Message |
| --- | --- |
| 400 | `missing token` |
| 401 | `invalid pairing token` |
| 401 | `pairing token already consumed` |
| 401 | `pairing token expired` |

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
  }
}
```

`brand` is the [public brand bundle](#get-apiv1publicbrand) without
`logo_url` and `login_background_url`; fetch the files with the asset
endpoint below.

### `GET /api/v1/integrations/settings`

Only the organisation settings, as in `bundle.settings`.

```sh
curl -H "Authorization: Bearer $CRED" $DEN/api/v1/integrations/settings
```

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

Errors: `422` with `details.subject = "issuer and subject are required"`.

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
Den checks that the token was issued for `den-spa`. Get one with that
`client_id`, and send the `id_token`, not the `access_token`.

**A module's pairing fails with `pairing token expired` or `already consumed`.**
Pairing URLs work once and for 15 minutes. Create a new one with
[`POST /api/v1/modules/{id}/pairing-tokens`](#post-apiv1modulesidpairing-tokens).

**A paired module gets `401 invalid or revoked credential`.**
The module was deleted in Den (which removes its credentials). Register it
again and pair it with a new URL.

**`500` when registering a module.**
Registering the same `slug` and `environment` twice is not yet reported
more clearly; check [`GET /api/v1/modules`](#get-apiv1modules) for an
existing entry.

**`409 the operator is not set up`.**
`OPERATOR_URL` is not set, so Den cannot manage databases or backups; see
[Configuration](configuration.md).

**A backup download link answers `404 download link not found`.**
Links work once, for 5 minutes, and are forgotten when `den-backend`
restarts. Create a new one.
