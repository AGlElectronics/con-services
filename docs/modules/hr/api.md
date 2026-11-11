# HR API reference

HR's backend is a JSON-over-HTTP API for everything that happens to a
person in Con Services: the volunteer register, **onboarding** (profile,
department, planned access), **provisioning** of their Keycloak account,
access changes, pausing, banning and **offboarding**, plus departments and
their leads, access groups, the review queue for new volunteers,
spreadsheet imports, training requirements for roles, the audit log and
HR's settings. HR's own web app is one client of it; you can use the same
endpoints to script bulk onboarding, connect an applicant form, or build
reports. Almost every call is made by a signed-in person; the only
machine-to-machine endpoint is the
[directory](#get-apiinternaldirectorygroups) other modules read with a
service token.

This page lists all **86 endpoints**, taken from
[`backend/internal/http/router.go`](https://github.com/AGlElectronics/hr/blob/main/backend/internal/http/router.go)
and the handlers and services behind it. What all modules share (error
shape, request IDs, health probes, how tokens are checked) is on
[API conventions](../../concepts/api-conventions.md); how sign-in works is
on [Authentication](../../concepts/authentication.md).

## Basics

### Base URL and routing

HR is reached at its own address. The Gateway sends every request to
`hr-frontend`, whose nginx passes `/api/`, `/livez` and `/readyz` on to
`hr-backend`. The examples on this page use the
[local example installation](../../getting-started/den-quickstart.md):

```sh
HR=https://hr.conservices.test
```

| From | Address |
| --- | --- |
| Your computer, scripts, the web app | `https://hr.conservices.test` (your own domain in a real installation) |
| Inside the cluster | `https://hr-backend.conservices-hr.svc.cluster.local:8080`, only from namespaces the [network policies](../../operations/network-policies.md) allow |
| Docker Compose development stack | the backend's published port; see [Setup](setup.md#development-with-docker) |

!!! note "No `/v1` segment"
    HR serves its signed-in endpoints directly under `/api/…` (for example
    `GET /api/people`), not under `/api/v1/…` like Den and Rally. Copy paths
    from this page.

Collection paths are mounted with a trailing slash in the router
(`/api/people/`), and chi also matches them without it, so
`GET /api/people` and `GET /api/people/` are the same request.

### Authenticating to HR

Every `/api/…` request except the public ones and the directory carries a
user token:

| Mode | What to send | Who it is |
| --- | --- | --- |
| `AUTH_MODE=oidc` (every real installation) | `Authorization: Bearer <ID token>` issued by Keycloak to the `hr-spa` client (or a token whose audience matches `OIDC_AUDIENCE`). | The person in the token. Their HR roles come from the token's `groups` claim. |
| `AUTH_MODE=dev` (local development only) | `X-Dev-User: <name>` (or nothing: then `DEV_DEFAULT_USER`, default `dev-hr-admin`). Optional `X-Dev-Groups: hr-lead,stash-volunteer` (comma-separated) and `X-Dev-Email: someone@example.test`. | A made-up person whose subject is the name. Without `X-Dev-Groups` they are in `HR_ADMIN_GROUPS`, so an HR admin. |

#### Roles and permissions

HR has **three roles**. A person gets a role by being in one of its IdP
groups (matched case-insensitively, with or without Keycloak's leading
`/`; see [Configuration](configuration.md)):

| Role | Groups | Applies to | Permissions |
| --- | --- | --- | --- |
| **admin** | `HR_ADMIN_GROUPS` (default `hr-admin`) | everything | every permission below |
| **viewer** | `HR_VIEWER_GROUPS` (default `hr-viewer`) | everything | `people.read`, `audit.read`, `idp.groups.read` |
| **lead** | `HR_LEAD_GROUPS` (default `hr-lead`) | only the departments whose lead list includes them ([`PUT /api/departments/{id}/leads`](#put-apidepartmentsidleads)) | `people.read`, `people.write`, `people.pause`, `access.manage`, `onboarding.manage`, `training.override`, `review.manage`, `requirements.delete` |

The permissions are: `people.read`, `people.create`, `people.write`,
`people.pause`, `people.offboard`, `access.manage`,
`access.assign_privileged` (assign admin-type roles of any module),
`onboarding.manage`, `departments.manage`, `settings.manage`,
`bundles.manage`, `den.manage`, `requirements.manage`,
`requirements.delete`, `training.override`, `audit.read`, `review.manage`,
`import.run`, `idp.groups.read`, `workspace.manage`.

A lead is matched to the departments they lead through their HR person
record (the token's `sub` equals the person's stored IdP subject). Someone
in an HR lead group who leads no (non-archived) department holds no
permissions at all. [`GET /api/me`](#get-apime) shows what you hold.

Every endpoint below says who may call it:

- **public**: no token.
- **service token**: the shared `HR_DIRECTORY_TOKEN`, not a user token.
- **signed in**: any valid token; no HR role needed.
- **any HR role**: admin, viewer or lead.
- a permission such as **`people.read`**: admins and viewers who hold it
  everywhere, and leads who hold it for their departments. For leads, HR
  then checks that the person, onboarding, department or review item
  belongs to a department they lead; if not, the answer is **403**.
- a permission marked **global only**, such as **`settings.manage` (global
  only)**: only callers who hold it everywhere (in practice admins; viewers
  for `audit.read` and `idp.groups.read`). A lead's department-scoped
  permission is not enough.

Nobody may change their own access, status, ban, onboarding, training
requirements or critical profile fields (names, nickname, emails, notes):
those calls answer **403** `you can't change your own <what>; ask another HR admin`.

Authentication and permission errors:

| Status | Body | When |
| --- | --- | --- |
| 401 | `{"error":{"code":"unauthorized","message":"missing bearer token"}}` | No `Authorization: Bearer` header. |
| 401 | `{"error":{"code":"unauthorized","message":"invalid token"}}` | Expired, wrong issuer, or issued for another client (for example a `den-spa` token). |
| 403 | `{"error":{"code":"forbidden","message":"you don't have access to HR"}}` | Signed in, but in none of the three role groups. Such people can only use the [self-service registration](#self-service-registration). Check with [`GET /api/me`](#get-apime). |
| 403 | `{"error":{"code":"forbidden","message":"you don't have the HR permission people.write"}}` | Your roles do not grant the permission (or only for departments, on a global-only endpoint). |
| 403 | `this person is not in a department you lead`, `this onboarding is not in a department you lead`, `you don't lead this department`, `this item is not in a department you lead` | A lead acting outside their departments. |

#### Getting a token for testing

!!! danger "Local development only"
    This uses Keycloak's password grant and the local realm's dev account
    `admin` / `adminadmin` (a member of `hr-admin`). Real installations
    must turn off direct access grants for app clients, and the dev
    accounts must not exist there. See [Secrets](../../operations/secrets.md).

=== "macOS / Linux"

    ```sh
    TOKEN=$(curl -s https://auth.conservices.test/realms/conservices/protocol/openid-connect/token \
      -d grant_type=password -d client_id=hr-spa \
      -d username=admin -d password=adminadmin -d scope=openid \
      | jq -r .id_token)
    ```

=== "Windows (PowerShell)"

    ```powershell
    $TOKEN = (Invoke-RestMethod -Method Post `
      -Uri https://auth.conservices.test/realms/conservices/protocol/openid-connect/token `
      -Body @{ grant_type='password'; client_id='hr-spa'; username='admin'; password='adminadmin'; scope='openid' }).id_token
    ```

Tokens last 5 minutes in the local realm. The `curl` examples below use
bash syntax with `$HR` and `$TOKEN`. In dev mode replace the
`Authorization` header with `-H "X-Dev-User: dev-hr-admin"` (add
`-H "X-Dev-Groups: hr-lead"` to try the lead role).

### Requests, responses and errors

- Bodies are JSON. Unknown fields are rejected with
  `400 bad_request` (`invalid JSON: json: unknown field "…"`); an empty body
  where one is required gives `400 request body is empty`. The import
  endpoints take `multipart/form-data` instead.
- IDs are UUIDs; a malformed one in the path gives `400 invalid id`, in a
  query parameter `400 <name> must be a uuid`.
- Times are RFC 3339 (`2026-11-06T09:00:00Z`); dates of birth are
  `YYYY-MM-DD`.
- Lists answer `{"items": [...]}`. The people, drafts (onboardings), review
  queue and audit log lists are **paged**: they take `limit` (default 50,
  at most 200) and `offset` (default 0), and answer
  `{"items": [...], "total": 132, "limit": 50, "offset": 0}`, where `total`
  counts every match.
- Every response carries `X-Request-ID`. Requests are cut off after 60
  seconds.
- No HR endpoint is rate limited (HR never answers `429`). The address
  lookup throttles itself instead, see
  [`GET /api/address/search`](#get-apiaddresssearch).

Errors use the shared shape `{"error":{"code","message","details"}}`:

| Status | `code` | Typical cause in HR |
| --- | --- | --- |
| 400 | `bad_request` | Malformed JSON, unknown field, bad UUID, bad date in a query. |
| 401 | `unauthorized` | No or invalid token. |
| 403 | `forbidden` | No HR role, missing permission, outside your departments, or acting on yourself. |
| 404 | `not_found` | `person not found`, `department not found`, `employment_draft not found`, `review item not found`, `access group not found`, `import not found`, `job not found`, … |
| 409 | `conflict` | The action does not fit the current state, for example completing an onboarding that is not a draft, or undoing an import that was already used. |
| 422 | `validation_failed` | Field errors in `details`, keyed by field path (`address.city`, `emergency_contact.phone`, `roles.stash:admin`). |
| 502 | `upstream_failed` | Keycloak or another system failed; the message says what to check. |
| 503 | `den_pairing_required` | `DEN_MODE=required` and HR is not paired with Den yet (below). |
| 500 | `internal` | A bug or database failure; details only in HR's log. |

The Den pairing endpoints answer with their own codes (`pairing_failed`,
`sync_failed`), described with them.

#### Waiting for Den

With `DEN_MODE=required` (the Kubernetes default, see
[Configuration](configuration.md)), every `/api/…` endpoint answers
**503** until an admin pairs HR with Den:

```json
{"error":{"code":"den_pairing_required","message":"This module is waiting to be connected to Den."}}
```

Still open while unpaired: `/api/role-catalog`, `/api/brand…`, `/api/me…`
(including preferences), `/api/den…` (state and the pairing routes) and
`/api/internal/directory/groups`. The self-service registration is **not**
open: volunteers also get 503 until HR is paired. Check with
[`GET /api/den/state`](#get-apidenstate).

---

## Endpoint summary

| Method | Path | Who may call it | Section |
| --- | --- | --- | --- |
| GET | `/livez`, `/readyz` | public | [Health](#health-and-catalog) |
| GET | `/api/role-catalog` | public | [Health](#health-and-catalog) |
| GET | `/api/den/state` | public | [Health](#get-apidenstate) |
| GET | `/api/brand`, `/api/brand/{role}` | public | [Brand](#brand-and-preferences) |
| GET | `/api/internal/directory/groups` | service token | [Directory](#get-apiinternaldirectorygroups) |
| GET | `/api/me` | signed in | [You](#you) |
| GET, PUT | `/api/me/preferences` | signed in | [Brand](#brand-and-preferences) |
| GET, PUT | `/api/self-service/registration` | signed in (own entry only) | [Self-service](#self-service-registration) |
| GET | `/api/self-service/departments` | signed in | [Self-service](#self-service-registration) |
| GET | `/api/people` | `people.read` | [People](#get-apipeople) |
| POST | `/api/people` | `people.create` (global only) | [People](#post-apipeople) |
| GET | `/api/people/{id}` | `people.read` | [People](#get-apipeopleid) |
| PUT | `/api/people/{id}` | `people.write` | [People](#put-apipeopleid) |
| GET | `/api/people/{id}/access` | `people.read` | [Access](#access-of-one-person) |
| PUT | `/api/people/{id}/access` | `access.manage` | [Access](#put-apipeopleidaccess) |
| POST | `/api/people/{id}/status` | `people.pause` | [Pause and ban](#post-apipeopleidstatus) |
| POST | `/api/people/{id}/ban` | `people.offboard` (global only) | [Pause and ban](#post-apipeopleidban) |
| POST | `/api/people/{id}/password-setup-email` | `access.manage` | [Pause and ban](#post-apipeopleidpassword-setup-email) |
| POST | `/api/people/{id}/offboard` | `people.offboard` (global only) | [Offboarding](#offboarding) |
| GET | `/api/departments`, `/api/departments/{id}` | `people.read` (all departments) | [Departments](#departments) |
| POST | `/api/departments` | `departments.manage` (global only) | [Departments](#post-apidepartments) |
| PUT | `/api/departments/{id}` | `departments.manage` (global only) | [Departments](#put-apidepartmentsid) |
| PUT | `/api/departments/{id}/leads` | `departments.manage` (global only) | [Departments](#put-apidepartmentsidleads) |
| POST | `/api/departments/{id}/archive`, `/api/departments/{id}/restore` | `departments.manage` (global only) | [Departments](#post-apidepartmentsidarchive-and-post-apidepartmentsidrestore) |
| GET | `/api/access-bundles`, `/api/access-bundles/{id}` | `people.read` (all access groups) | [Access groups](#access-groups) |
| POST | `/api/access-bundles` | `bundles.manage` (global only) | [Access groups](#post-apiaccess-bundles) |
| PUT, DELETE | `/api/access-bundles/{id}` | `bundles.manage` (global only) | [Access groups](#put-apiaccess-bundlesid) |
| POST | `/api/onboardings` | `onboarding.manage` | [Onboarding](#post-apionboardings) |
| GET | `/api/onboardings/{id}` | `people.read` | [Onboarding](#get-apionboardingsid) |
| PUT | `/api/onboardings/{id}/details` | `onboarding.manage` | [Onboarding](#put-apionboardingsiddetails) |
| POST | `/api/onboardings/{id}/cancel` | `onboarding.manage` | [Onboarding](#post-apionboardingsidcancel) |
| POST | `/api/onboardings/{id}/complete` | `access.manage` | [Provisioning](#complete-an-onboarding-provisioning) |
| GET | `/api/jobs/{id}` | `people.read` | [Jobs](#get-apijobsid) |
| GET, POST | `/api/drafts` | `people.read` / `onboarding.manage` | [Drafts](#employment-drafts-low-level) |
| GET | `/api/drafts/{id}` | `people.read` | [Drafts](#employment-drafts-low-level) |
| PUT | `/api/drafts/{id}/roles` | `onboarding.manage` | [Drafts](#put-apidraftsidroles) |
| GET | `/api/drafts/{id}/provisioning-jobs` | `people.read` | [Provisioning](#get-apidraftsidprovisioning-jobs) |
| GET | `/api/review` | `review.manage` | [Review queue](#get-apireview) |
| POST | `/api/review/scan` | `review.manage` (global only) | [Review queue](#post-apireviewscan) |
| GET, PUT | `/api/review/{id}` | `review.manage` | [Review queue](#get-apireviewid) |
| POST | `/api/review/{id}/accept`, `/merge`, `/reject` | `review.manage` (plus the checks listed there) | [Review queue](#post-apireviewidaccept) |
| GET, POST | `/api/imports` | `import.run` (global only) | [Imports](#spreadsheet-imports) |
| POST | `/api/imports/inspect`, `/api/imports/preview` | `import.run` (global only) | [Imports](#spreadsheet-imports) |
| GET, DELETE | `/api/imports/{id}` | `import.run` (global only) | [Imports](#get-apiimportsid) |
| GET | `/api/imports/{id}/errors` | `import.run` (global only) | [Imports](#get-apiimportsiderrors) |
| GET, POST | `/api/import-templates` | `import.run` (global only) | [Imports](#import-templates) |
| DELETE | `/api/import-templates/{id}` | `import.run` (global only) | [Imports](#import-templates) |
| GET | `/api/access-catalog`, `/api/qualification-catalog` | `people.read` | [Catalogs](#catalogs-and-training-requirements) |
| GET | `/api/role-requirements` | `people.read` | [Catalogs](#get-apirole-requirements) |
| POST | `/api/role-requirements` | `requirements.manage` (global only) | [Catalogs](#post-apirole-requirements) |
| DELETE | `/api/role-requirements/{id}` | `requirements.delete` | [Catalogs](#delete-apirole-requirementsid) |
| GET | `/api/pending-grants` | `people.read` | [Catalogs](#pending-grants) |
| POST | `/api/pending-grants/{id}/override` | `training.override` | [Catalogs](#pending-grants) |
| GET | `/api/settings` | any HR role | [Settings](#settings) |
| PUT | `/api/settings` | `settings.manage` (global only) | [Settings](#put-apisettings) |
| GET | `/api/den` | `den.manage` (global only) | [Den pairing](#den-pairing) |
| POST, DELETE | `/api/den/pair` | `den.manage` (global only) | [Den pairing](#den-pairing) |
| POST | `/api/den/sync` | `den.manage` (global only) | [Den pairing](#den-pairing) |
| GET | `/api/workspace/accounts` | `workspace.manage` (global only) | [Google Workspace](#google-workspace) |
| POST | `/api/workspace/accounts/{id}/delete` | `workspace.manage` (global only) | [Google Workspace](#google-workspace) |
| POST | `/api/workspace/sync` | `workspace.manage` (global only) | [Google Workspace](#google-workspace) |
| GET | `/api/audit` | `audit.read` (global only) | [Audit and retention](#get-apiaudit) |
| GET | `/api/retention/candidates` | `settings.manage` (global only) | [Audit and retention](#get-apiretentioncandidates) |
| GET | `/api/check/email`, `/api/check/username` | `people.write` | [Checks](#checks-and-helpers) |
| GET | `/api/address/search` | `people.write` | [Checks](#checks-and-helpers) |
| GET | `/api/dashboard` | `people.read` | [Checks](#get-apidashboard) |
| GET | `/api/idp/groups` | `idp.groups.read` (global only) | [Checks](#get-apiidpgroups) |

---

## Health and catalog

### `GET /livez`

Is the process running? Never touches the database. **Access:** public.
Not routed through the Gateway; forward the port to try it:

```sh
kubectl -n conservices-hr port-forward deploy/hr-backend 8080:8080
curl -sk https://localhost:8080/livez
```

The backend serves HTTPS with a certificate for its service name, not for
`localhost`, so `-k` skips the name check for this local test only.

```json
{"status":"ok","version":"1.0.0-1","uptime_sec":930}
```

### `GET /readyz`

Can HR serve traffic? Pings the database (2-second limit). **Access:** public.

```sh
curl -sk https://localhost:8080/readyz
```

```json
{"status":"ready","database":"ok"}
```

When the database does not answer: **503** with
`{"status":"not_ready","database":"down"}`.

### `GET /api/role-catalog`

HR's own roles in the shared role-catalog format, so other tools (Den,
HR's own access catalog) can show and assign them. **Access:** public.

```sh
curl -s $HR/api/role-catalog
```

```json
{
  "module": "hr",
  "display_name": "HR",
  "description": "Onboarding, people and access.",
  "roles": [
    {
      "key": "admin",
      "label": "HR admin",
      "description": "Everything in HR: onboard and offboard people, departments, access groups, settings, audit log.",
      "group": "hr-admin",
      "assignable": true,
      "scope": "organization",
      "permissions": ["access.assign_privileged", "access.manage", "audit.read", "bundles.manage", "den.manage",
        "departments.manage", "idp.groups.read", "import.run", "onboarding.manage", "people.create",
        "people.offboard", "people.pause", "people.read", "people.write", "requirements.delete",
        "requirements.manage", "review.manage", "settings.manage", "training.override", "workspace.manage"],
      "privileged": true
    },
    {
      "key": "viewer",
      "label": "HR viewer",
      "description": "Read-only access to people, departments and the audit log.",
      "group": "hr-viewer",
      "assignable": true,
      "scope": "organization",
      "permissions": ["audit.read", "idp.groups.read", "people.read"]
    },
    {
      "key": "lead",
      "label": "Department lead",
      "description": "Onboard people, change their access, pause them and review new volunteers, only in the departments whose lead list includes them.",
      "group": "hr-lead",
      "assignable": true,
      "scope": "department",
      "permissions": ["access.manage", "onboarding.manage", "people.pause", "people.read", "people.write",
        "requirements.delete", "review.manage", "training.override"],
      "note": "Put the person on a department's lead list in HR (Departments); HR then gives them this group."
    }
  ],
  "source": "self",
  "status": "ok"
}
```

Each `group` is the first entry of `HR_ADMIN_GROUPS`, `HR_VIEWER_GROUPS`
and `HR_LEAD_GROUPS`.

### `GET /api/den/state`

Is HR waiting for Den? The web app asks this before sign-in to decide
whether to show *Waiting for Den*. **Access:** public.
`Cache-Control: no-store`.

```sh
curl -s $HR/api/den/state
```

```json
{"mode":"required","paired":false}
```

`mode` is `required` or `standalone` (`DEN_MODE`); `paired` is `true` once
an admin has paired HR with Den ([Den pairing](#den-pairing)). While
`mode` is `required` and `paired` is `false`, the rest of the API answers
[503 `den_pairing_required`](#waiting-for-den).

---

## You

### `GET /api/me`

Who HR thinks you are, your roles and what you may do. The first thing to
check when someone gets a 403. **Access:** signed in.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $HR/api/me
```

A department lead:

```json
{
  "username": "Lena Lead",
  "auth_mode": "oidc",
  "has_access": true,
  "groups": ["/dept-tech", "/dept-tech-lead", "/hr-lead", "/stash-volunteer"],
  "roles": ["lead"],
  "permissions": {
    "access.manage": "departments",
    "onboarding.manage": "departments",
    "people.pause": "departments",
    "people.read": "departments",
    "people.write": "departments",
    "requirements.delete": "departments",
    "review.manage": "departments",
    "training.override": "departments"
  },
  "lead_of": ["5b0c7f1e-9d2a-4c3b-8e6f-1a2b3c4d5e6f"],
  "person_id": "d4c3b2a1-2222-4e2f-8a9b-0c1d2e3f4a5b"
}
```

A signed-in volunteer without an HR role:

```json
{"username":"Vera Volunteer","auth_mode":"oidc","has_access":false,"groups":["/stash-volunteer"],"roles":[],"permissions":{},"lead_of":[]}
```

| Field | Meaning |
| --- | --- |
| `username` | Display name built from the token (name, else preferred username). Used as the actor in HR's audit log. |
| `auth_mode` | `oidc` or `dev`. |
| `has_access` | `true` when you hold at least one HR role (`roles` is not empty). |
| `groups` | The token's `groups` claim. In dev mode: `X-Dev-Groups`, or `HR_ADMIN_GROUPS` when that header is missing. |
| `roles` | Your HR roles: `admin`, `viewer` and/or `lead`. |
| `permissions` | Every permission you hold, mapped to `global` (everywhere) or `departments` (only in `lead_of`). Empty for a lead who leads no department. |
| `lead_of` | IDs of the non-archived departments whose lead list includes you. |
| `person_id` | Your own HR person record, when HR has one for your account (matched on the token's `sub`). Missing otherwise. Only filled for callers with an HR role. |

---

## Brand and preferences

These follow the same pattern in every paired module. HR copies Den's brand
and serves it itself, so browsers never call Den.

### `GET /api/brand`

The active brand for HR's sign-in screen and theme. **Access:** public.
`Cache-Control: no-cache`.

```sh
curl -s $HR/api/brand
```

Paired with Den:

```json
{
  "source": "den",
  "revision": 10,
  "organization_name": "Example Con e.V.",
  "logo_url": "/api/brand/logo?v=9e8d7c6b-5a4f-4e3d-2c1b-0a9f8e7d6c5b",
  "login_background_url": "/api/brand/login-background?v=1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
  "theme": { "primary": "#e44763" },
  "copy": { "convention_name": "Example Con 2027", "login_layout": "panel" }
}
```

Not paired: `{"source":"standalone","revision":0,"organization_name":"","theme":{},"copy":{}}`.
The URLs are only present when Den has that asset.

### `GET /api/brand/{role}`

A brand file copied from Den: `logo` or `login-background`. **Access:**
public. Served with its content type and `Cache-Control: public, max-age=86400`.

```sh
curl -s -o logo.svg $HR/api/brand/logo
```

Errors: **404** `{"error":{"code":"not_found","message":"no such brand asset"}}`
when HR is not paired or Den has no such asset.

### `GET /api/me/preferences`

Your theme. Stored in Den (shared by every app) when HR is paired.
**Access:** signed in.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $HR/api/me/preferences
```

```json
{"theme":"dark","updated_at":"2026-11-06T09:12:44Z","synced":true}
```

`synced` is `false` when HR is standalone or Den could not be reached; the
answer is then `{"theme":"system","updated_at":null,"synced":false}` and
the web app keeps the choice cached in the browser. This endpoint never
fails because of Den.

### `PUT /api/me/preferences`

Save your theme. **Access:** signed in.

| Field | Type | Required | Values |
| --- | --- | --- | --- |
| `theme` | string | yes | `system`, `light`, `dark` |

```sh
curl -s -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"theme":"dark"}' $HR/api/me/preferences
```

```json
{"theme":"dark","updated_at":"2026-11-06T09:15:02Z","synced":true}
```

Errors: **400** `invalid JSON body`, **422** `theme must be system, light or dark`.
If Den cannot store it, HR still answers **200** with
`{"theme":"dark","updated_at":null,"synced":false}`.

---

## Self-service registration

A volunteer who can sign in but has no HR record yet (for example someone
who created their own account) sees HR's *Waiting for a coordinator* page.
There they fill in their own profile and pick a department. HR stores it
as an entry in the [review queue](#review-queue) (source `self_service`),
where an admin or a lead of the chosen department accepts it. These three
endpoints need **no HR role**, and each caller only ever sees and changes
their own entry (found by the token's `sub`).

### `GET /api/self-service/registration`

Your own entry. **Access:** signed in.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $HR/api/self-service/registration
```

```json
{
  "status": "pending",
  "email": "vera.volunteer@mail.example",
  "item": {
    "first_name": "Vera", "last_name": "Volunteer", "nickname": "", "phone": "", "date_of_birth": "",
    "address": {"street": "", "postal_code": "", "city": "", "country": ""},
    "emergency_contact": {},
    "department_id": "5b0c7f1e-9d2a-4c3b-8e6f-1a2b3c4d5e6f"
  },
  "missing_fields": {
    "nickname": "required", "phone": "required", "date_of_birth": "required",
    "address.street": "required", "address.postal_code": "required", "address.city": "required", "address.country": "required",
    "emergency_contact.name": "required", "emergency_contact.phone": "required"
  }
}
```

| Field | Meaning |
| --- | --- |
| `status` | `pending` (something is still missing), `ready` (complete, waiting for a coordinator), or the decision: `accepted`, `merged`, `rejected`. |
| `email` | From your token; you cannot change it here. |
| `missing_fields` | What still blocks the entry from being `ready`. |

Errors: **404** `registration not found` (nothing submitted yet),
**401** `sign in first` (the token has no subject).

### `PUT /api/self-service/registration`

Create or update your entry. You may save a partial profile: missing
fields are fine, wrong ones are not. **Access:** signed in.

| Field | Type | Notes |
| --- | --- | --- |
| `first_name`, `last_name`, `nickname` | string | Same rules as [the person body](#the-person-body-create-and-update). |
| `phone` | string | International form, or national for the default country. |
| `date_of_birth` | string `YYYY-MM-DD` | |
| `address` | object | `street`, `postal_code`, `city`, `country`. |
| `emergency_contact` | object | `name`, `phone`, `email`, `comments`. |
| `social_handles` | object | Known networks only. |
| `department_id` | UUID | Optional; one of [`GET /api/self-service/departments`](#get-apiself-servicedepartments). Sending none keeps the earlier choice. |

There is no `email` field: HR takes your address from the token.

```sh
curl -s -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  $HR/api/self-service/registration -d '{
    "first_name": "Vera", "last_name": "Volunteer", "nickname": "vera",
    "phone": "+43 660 1112233", "date_of_birth": "1999-02-03",
    "address": {"street": "Ringstraße 5", "postal_code": "1010", "city": "Wien", "country": "AT"},
    "emergency_contact": {"name": "Viktor Volunteer", "phone": "+43 660 4445566"},
    "department_id": "5b0c7f1e-9d2a-4c3b-8e6f-1a2b3c4d5e6f"
  }'
```

**200** with your entry as `GET` shows it, now `"status": "ready"` and
`"missing_fields": {}`.

| Status | Message |
| --- | --- |
| 422 | Field errors other than `required`, for example `phone: must be a valid phone number with country code, e.g. +43 660 1234567`; `department_id: unknown department` (unknown or archived). |
| 409 | `you already have an HR record; ask a coordinator to change it` |
| 409 | `a coordinator already decided on your registration (accepted)` (or `merged`, `rejected`) |
| 401 | `sign in first` |

### `GET /api/self-service/departments`

The departments a volunteer may pick (not archived), by name.
**Access:** signed in.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $HR/api/self-service/departments
```

```json
{"items": [
  {"id": "5b0c7f1e-9d2a-4c3b-8e6f-1a2b3c4d5e6f", "name": "Tech", "description": "Stage tech, network and streaming."}
]}
```

---

## People

A **person** is HR's record of one volunteer or staff member. It survives
onboardings and access changes; offboarding deletes it.

### The person object

```json
{
  "id": "a9b8c7d6-1111-4e2f-8a9b-0c1d2e3f4a5b",
  "first_name": "Alex",
  "last_name": "Sample",
  "nickname": "alex",
  "username": "alex",
  "date_of_birth": "1996-04-12",
  "is_banned": false,
  "legal_name": "Alex Sample",
  "display_name": "alex",
  "email": "alex.sample@mail.example",
  "org_email": "alex.sample@example.org",
  "phone": "+436601234567",
  "address": { "street": "Hauptstraße 1", "postal_code": "1010", "city": "Wien", "country": "AT" },
  "social_handles": { "telegram": "@alexsample" },
  "emergency_contact": { "name": "Sam Sample", "phone": "+436609876543", "email": "sam@mail.example", "comments": "Sibling" },
  "status": "active",
  "notes": "Prefers night shifts.",
  "idp_user_id": "8f7e6d5c-4b3a-4291-8f7e-6d5c4b3a2918",
  "idp_subject": "8f7e6d5c-4b3a-4291-8f7e-6d5c4b3a2918",
  "created_at": "2026-11-03T18:20:11Z",
  "updated_at": "2026-11-06T09:05:00Z"
}
```

| Field | Notes |
| --- | --- |
| `username` | Login name, computed from the username template (default `{nickname}`, falling back to `{first}.{last}`); read-only. |
| `legal_name`, `display_name` | Computed: first + last, and the nickname (else the legal name). |
| `email` | Private address; account emails (set-password links, notices) go here. |
| `org_email` | Organisation address; must end with `@<org_email_domain>` when a domain is set. |
| `phone` | Stored in E.164 form. |
| `status` | `applicant`, `onboarding`, `active` or `paused`. There is no `offboarded`: offboarding deletes the person. |
| `social_handles` | Keys `telegram`, `discord`, `x`, `instagram`, `bluesky`, `mastodon`. |
| `idp_user_id` | The linked Keycloak account's id; missing before provisioning. |
| `idp_subject` | The OIDC `sub` other modules know the person by (usually the same as `idp_user_id`). |
| `paused_at` | When the person was paused; only while `paused`. |

### The person body (create and update)

Used by `POST /api/people`, `PUT /api/people/{id}` and the `person` field
of onboarding and review accept.

| Field | Type | Required | Rules |
| --- | --- | --- | --- |
| `first_name`, `last_name` | string | yes | Letters (any script), spaces, `.`, `-`, `'`; must start with a letter. |
| `nickname` | string | yes | Same rule. Must give a login name of at least 3 letters that nobody else (in HR or Keycloak) uses. |
| `date_of_birth` | string `YYYY-MM-DD` | yes | Realistic (not in the future, not over 120 years ago). |
| `email` | string | yes | Valid ASCII address, unique in HR. Lower-cased. |
| `phone` | string | yes | Valid number; international form, or national form for `default_country`. Rewritten to E.164. |
| `address` | object | yes | `street`, `postal_code`, `city`, `country` (two-letter ISO code), all required. |
| `emergency_contact` | object | `name` and `phone` required | `email` and `comments` optional. |
| `org_email` | string | no | Unique; lower-case letters, digits, `.`, `-`, `_` before the `@`. |
| `social_handles` | object | no | Known networks only; empty values are dropped. |
| `is_banned` | bool | no | Only honoured on create. Ignored on update; use [ban](#post-apipeopleidban). |
| `notes` | string | no | Internal notes. |
| `status` | string | no | Only honoured on create (default `applicant`). Ignored on update; use the lifecycle endpoints. |

Validation errors come back together:

```json
{
  "error": {
    "code": "validation_failed",
    "message": "validation failed",
    "details": {
      "phone": "must be a valid phone number with country code, e.g. +43 660 1234567",
      "address.country": "must be a two-letter country code",
      "nickname": "this nickname is already taken (login name alex)"
    }
  }
}
```

### `GET /api/people`

One page of people, sorted by display name, in a reduced form without
date of birth, phone, address or emergency contact. **Access:**
`people.read`; a lead only sees people with an onboarding or membership
(not cancelled) in a department they lead.

| Query | Meaning |
| --- | --- |
| `q` | Case-insensitive substring of legal name, display name, nickname, login name, email or organisation email. |
| `status` | `applicant`, `onboarding`, `active` or `paused`. |
| `department_id` | Only people with an onboarding or membership in this department. |
| `limit`, `offset` | Paging; default 50, at most 200. |

```sh
curl -s -H "Authorization: Bearer $TOKEN" "$HR/api/people?status=active&q=sample&limit=20"
```

```json
{
  "items": [
    {"id": "a9b8c7d6-1111-4e2f-8a9b-0c1d2e3f4a5b", "display_name": "alex", "legal_name": "Alex Sample", "nickname": "alex",
     "username": "alex", "email": "alex.sample@mail.example", "org_email": "alex.sample@example.org",
     "status": "active", "is_banned": false, "updated_at": "2026-11-06T09:05:00Z"}
  ],
  "total": 1,
  "limit": 20,
  "offset": 0
}
```

Errors: **400** `department_id must be a uuid`.

### `POST /api/people`

Create a person without starting an onboarding (for example an applicant).
**Access:** `people.create` (global only). Body: [the person body](#the-person-body-create-and-update).

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" $HR/api/people -d '{
  "first_name": "Alex", "last_name": "Sample", "nickname": "alex",
  "date_of_birth": "1996-04-12", "email": "alex.sample@mail.example", "phone": "+43 660 1234567",
  "address": {"street": "Hauptstraße 1", "postal_code": "1010", "city": "Wien", "country": "AT"},
  "emergency_contact": {"name": "Sam Sample", "phone": "+43 660 9876543"}
}'
```

**201** with the person object (`status: "applicant"`). Errors: **422**
as above.

### `GET /api/people/{id}`

One person, with every field. **Access:** `people.read` (leads: people in
their departments). Errors: **400** `invalid id`, **403**
`this person is not in a department you lead`, **404** `person not found`.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $HR/api/people/a9b8c7d6-1111-4e2f-8a9b-0c1d2e3f4a5b
```

### `PUT /api/people/{id}`

Replace the profile (send every field). Status and ban flag are kept. If
the person has a Keycloak account, HR also pushes name, email, login name
and profile attributes there, and emails the person when their login name
or organisation email changed. **Access:** `people.write` (leads: people in
their departments). On your own record you may change everything except
names, nickname, emails and notes.

```sh
curl -s -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  $HR/api/people/a9b8c7d6-1111-4e2f-8a9b-0c1d2e3f4a5b -d @alex.json
```

**200** with the person object plus, when something went wrong outside HR:

| Field | When |
| --- | --- |
| `idp_sync_error` | Keycloak refused the update or could not be reached (HR's record **is** saved). For example `HR's Keycloak service account is not allowed to update their profile (needs manage-users).` |
| `warning` | The account was updated but the notice email was not sent, or the account no longer exists. |

Errors: **403** (outside your departments, or
`you can't change your own nickname; ask another HR admin`), **404**,
**422** (same rules as create).

---

## Access of one person

### `GET /api/people/{id}/access`

What the person holds through HR: their completed memberships (one per
completed onboarding), their Keycloak account, and every onboarding.
**Access:** `people.read` (leads: people in their departments). HR asks
Keycloak live for the account state.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $HR/api/people/a9b8c7d6-1111-4e2f-8a9b-0c1d2e3f4a5b/access
```

```json
{
  "person": { "id": "a9b8c7d6-1111-4e2f-8a9b-0c1d2e3f4a5b", "display_name": "alex", "status": "active", "…": "…" },
  "memberships": [
    {
      "draft_id": "c1d2e3f4-0000-4a1b-9c8d-7e6f5a4b3c2d",
      "department": { "id": "5b0c7f1e-9d2a-4c3b-8e6f-1a2b3c4d5e6f", "slug": "tech", "name": "Tech", "group_name": "dept-tech", "…": "…" },
      "roles": [
        { "id": "0d9c8b7a-…", "draft_id": "c1d2e3f4-…", "role_name": "stash:volunteer", "group_name": "stash-volunteer", "scope": "global",
          "created_at": "2026-11-06T09:00:00Z", "bundle_id": "6e5d4c3b-2a19-4f08-9e7d-6c5b4a392817", "bundle_name": "Standard volunteer" },
        { "id": "1e0d9c8b-…", "draft_id": "c1d2e3f4-…", "role_name": "stash:lead", "group_name": "stash-lead", "scope": "global",
          "created_at": "2026-11-06T09:00:00Z" }
      ],
      "bundle_ids": ["6e5d4c3b-2a19-4f08-9e7d-6c5b4a392817"]
    }
  ],
  "external_id": "8f7e6d5c-4b3a-4291-8f7e-6d5c4b3a2918",
  "account": { "state": "linked", "username": "alex", "enabled": true },
  "onboardings": [ { "id": "c1d2e3f4-…", "state": "active", "title": "Tech volunteer", "…": "…" } ]
}
```

- `account.state` is `none` (never provisioned), `linked`, `missing` (the
  stored Keycloak id no longer exists), `unreachable` (`error` says why)
  or `off` (`IDP_PROVISIONER_MODE=off`).
- A role with `bundle_id`/`bundle_name` comes from that
  [access group](#access-groups); one without was picked individually.
  `"retired": true` marks a role its module no longer offers.

### `PUT /api/people/{id}/access`

Replace the individually picked roles (and optionally the access groups)
of **one** membership and sync Keycloak groups: new groups are added,
groups no other membership needs are removed. Roles that need training
not yet done are held back as [pending grants](#pending-grants).
**Access:** `access.manage`; a lead must send `draft_id` of a membership in
a department they lead. Nobody changes their own access.

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `draft_id` | UUID | when the person has more than one membership, and always for leads | Which membership to change. |
| `roles` | array | yes | Each `{"role_name": "<module>:<role>"}`; `scope` defaults to `global`. HR always uses the group from the module's catalog (`group_name` is ignored). |
| `bundle_ids` | array of UUID | no | Replaces the membership's access groups; leave it out to keep them. |

```sh
curl -s -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  $HR/api/people/a9b8c7d6-1111-4e2f-8a9b-0c1d2e3f4a5b/access -d '{
    "draft_id": "c1d2e3f4-0000-4a1b-9c8d-7e6f5a4b3c2d",
    "roles": [{"role_name": "events:reviewer"}],
    "bundle_ids": ["6e5d4c3b-2a19-4f08-9e7d-6c5b4a392817"]
  }'
```

**200** with the updated access view, as `GET`.

| Status | Message |
| --- | --- |
| 422 | `pick which membership to change` (`details.draft_id`) |
| 422 | `each role requires role_name` |
| 422 | `some roles cannot be assigned`, with one entry per role in `details`, for example `"roles.stash:admin": "assigning admin roles needs the HR permission access.assign_privileged"`, `"roles.foo:bar": "unknown role: its module is not connected or has never published a catalog"`, `"this role is no longer offered by its module"`, `"this role cannot be assigned by HR"` |
| 422 | `bundle_ids: unknown access group` |
| 403 | `you can't change your own access; ask another HR admin`; `you don't have the HR permission access.manage` (a lead without `draft_id`) |
| 409 | `This person's Keycloak account no longer exists, so access cannot be synced. …` |
| 502 | Keycloak unreachable or refused (`upstream_failed`). Nothing in HR is changed. |

---

## Pause, reactivate and ban

### `POST /api/people/{id}/status`

Swap a person between `active` and `paused`. Pausing **disables their
Keycloak account** (they cannot sign in) and keeps their access for when
they come back; reactivating enables the account again, unless they are
banned. **Access:** `people.pause` (leads: people in their departments).
Nobody pauses themselves.

| Field | Type | Required | Values |
| --- | --- | --- | --- |
| `status` | string | yes | `paused` (from `active`) or `active` (from `paused`) |

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  $HR/api/people/a9b8c7d6-1111-4e2f-8a9b-0c1d2e3f4a5b/status -d '{"status":"paused"}'
```

**200** with the person object plus `warnings`:

```json
{"id": "a9b8c7d6-1111-4e2f-8a9b-0c1d2e3f4a5b", "status": "paused", "paused_at": "2026-11-10T08:00:00Z", "…": "…", "warnings": []}
```

`warnings` lists what HR could not do in Keycloak, for example
`This installation links to the convention's own accounts (link mode), so HR did not disable or enable the account.`
or `Their account no longer exists in the identity provider.` They never
fail the request. People paused longer than the retention period are
offboarded automatically ([retention](#get-apiretentioncandidates)).

Errors: **409**
`only active ↔ paused can be changed here (status is onboarding)`, **403**,
**404**.

### `POST /api/people/{id}/ban`

Ban or unban a person. A banned person's account is disabled and they
cannot be onboarded again; unbanning an `active` person enables the account
again. **Access:** `people.offboard` (global only). Nobody bans themselves.

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `banned` | bool | yes | `true` to ban, `false` to lift the ban. |
| `reason` | string | when banning | Kept in the audit log. |

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  $HR/api/people/a9b8c7d6-1111-4e2f-8a9b-0c1d2e3f4a5b/ban -d '{"banned": true, "reason": "Harassment at the 2026 event"}'
```

**200** with the person object (`"is_banned": true`) plus `warnings`, as
for status. Banning someone who is already banned changes nothing and
answers 200.

Errors: **422** `reason: required`, **403**
`you can't change your own ban status; ask another HR admin`, **404**.

### `POST /api/people/{id}/password-setup-email`

Have Keycloak email the person a new set-password link, for example when
the first one failed or expired. No body. The realm needs SMTP.
**Access:** `access.manage` (leads: people in their departments).

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  $HR/api/people/a9b8c7d6-1111-4e2f-8a9b-0c1d2e3f4a5b/password-setup-email
```

```json
{"sent":true}
```

| Status | Message |
| --- | --- |
| 409 | `this person has no account yet` |
| 409 | `this installation links to the convention's own accounts; passwords are managed there` |
| 409 | `the identity provider cannot send set-password emails` |
| 409 | `their account no longer exists in the identity provider` |
| 502 | `Keycloak refused to send the set-password email (check the realm's SMTP settings): …` (or unreachable) |

---

## Offboarding

### `POST /api/people/{id}/offboard`

Remove a person: take care of their Keycloak account (below), email them
(if SMTP is configured and the account was deleted), **delete them from
HR** (profile and every onboarding), suspend their Google Workspace
account if the connector is on, then call the
[offboarding hook](#offboarding-hook). **Access:** `people.offboard`
(global only). Nobody offboards themselves.

What happens to the account depends on `IDP_PROVISIONER_MODE`
([Configuration](configuration.md)):

| Mode | Account |
| --- | --- |
| `manage` | Deleted. |
| `link` (accounts belong to the convention's own identity provider) | **Not** deleted. HR removes its groups (memberships and lead groups) and clears the `hrPersonId` attribute, and adds a warning. |
| `off` | Nothing; HR has no accounts. |

HR keeps the access history (who granted or removed which access, the
offboarding line) for `retention.offboarded_audit_days` (default 365),
then deletes it; every other audit entry about the person is deleted at
once.

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `reason` | string | yes | Recorded for HR. |
| `share_reason` | bool | no | Include the reason in the email to the person. |
| `hr_only` | bool | no | Skip Keycloak (for example when it is down); delete the account in the Keycloak console afterwards. |

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  $HR/api/people/a9b8c7d6-1111-4e2f-8a9b-0c1d2e3f4a5b/offboard \
  -d '{"reason": "Left the team", "share_reason": false}'
```

```json
{
  "username": "alex",
  "warnings": [
    "Could not tell https://wiki-backend.conservices-wiki.svc.cluster.local:8080/api/internal/offboarded about the offboarding: HTTP 503 Service Unavailable. The module keeps their data until it hears about it."
  ]
}
```

`warnings` lists what HR could not do (Keycloak skipped, account already
gone, link mode, email not sent, Google Workspace, a hook failed). They
never block the offboarding.

!!! note "Convention SSO"
    When **Settings → Identity** says staff sign in through the
    convention's own SSO (`identity.effective.staff_mode` is `brokered` or
    `existing`, see [Settings](#settings)), the web app warns before
    offboarding that the SSO account stays active. That warning is only in
    the web app; the API call behaves as in the table above.

| Status | Message |
| --- | --- |
| 422 | `reason: required` |
| 403 | `you can't change your own account; ask another HR admin` |
| 404 | `person not found` |
| 502 | `Keycloak is unreachable, so HR could not look up the account. … You can also offboard in HR only and delete the account in Keycloak by hand.` Nothing is deleted; retry, or send `"hr_only": true`. |
| 502 | `Keycloak refused to delete their account: …` (or `remove their HR groups` in link mode). Nothing is deleted. |

### Offboarding hook

After the person is deleted, and only if they ever had a Keycloak account,
HR sends this to every entry of `OFFBOARD_HOOKS` (comma-separated
`url|token`, see [Configuration](configuration.md)), for example Wiki,
which then orphans the person's private space:

```http
POST /api/internal/offboarded HTTP/1.1
Authorization: Bearer <token from OFFBOARD_HOOKS>
Content-Type: application/json

{
  "issuer": "https://auth.conservices.test/realms/conservices",
  "subject": "8f7e6d5c-4b3a-4291-8f7e-6d5c4b3a2918",
  "external_id": "8f7e6d5c-4b3a-4291-8f7e-6d5c4b3a2918",
  "idp_user_id": "8f7e6d5c-4b3a-4291-8f7e-6d5c4b3a2918",
  "username": "alex"
}
```

| Field | Meaning |
| --- | --- |
| `issuer` | The OIDC issuer the subject belongs to (`OIDC_ISSUER_URL`); `dev:` in dev auth mode. A subject is only unique together with its issuer. |
| `subject` | The person's IdP subject: the `sub` claim of their tokens (falls back to `external_id` when HR never learned it). |
| `external_id` | The account's id in the identity provider (Keycloak user id). |
| `idp_user_id` | The same value as `external_id`, kept for older receivers. |
| `username` | Their login name (else display name). |

The bearer token is only sent when the entry has one. Timeout 5 seconds;
a non-2xx answer or a timeout becomes a warning in the offboard response.
Each hook is a cross-module call and needs NetworkPolicy rules on both
sides ([Network policies](../../operations/network-policies.md)).

---

## Departments

A **department** is a team volunteers join. Each one has a Keycloak group
`dept-<slug>` and a lead group `dept-<slug>-lead` (created by HR), a list
of **leads**, and **default access** (roles and access groups) that every
new member gets planned.

### The department object

```json
{
  "id": "5b0c7f1e-9d2a-4c3b-8e6f-1a2b3c4d5e6f",
  "slug": "tech",
  "name": "Tech",
  "description": "Stage tech, network and streaming.",
  "group_name": "dept-tech",
  "lead_group": "dept-tech-lead",
  "leads": [{ "person_id": "d4c3b2a1-2222-4e2f-8a9b-0c1d2e3f4a5b", "display_name": "lena" }],
  "default_roles": [
    { "role_name": "stash:volunteer", "group_name": "stash-volunteer", "scope": "global" }
  ],
  "default_bundles": ["6e5d4c3b-2a19-4f08-9e7d-6c5b4a392817"],
  "idp_synced_at": "2026-11-05T17:00:02Z",
  "member_count": 14,
  "created_at": "2026-10-01T12:00:00Z",
  "updated_at": "2026-11-05T17:00:02Z"
}
```

`idp_sync_error` appears when HR could not create the groups in Keycloak;
saving the department again retries. `member_count` counts active and
paused people with a completed onboarding in the department.
`archived_at` appears on an archived department.

### `GET /api/departments`

Departments by name: `{"items": [ … ]}`. Archived departments are left out
unless you add `?archived=true`. **Access:** `people.read`; leads and
viewers see every department, not only their own.

```sh
curl -s -H "Authorization: Bearer $TOKEN" "$HR/api/departments?archived=true"
```

### `POST /api/departments`

Create a department. HR then makes sure the Keycloak groups (department,
lead and default role groups) exist and calls the
[department hooks](#department-hooks-outbound). **Access:**
`departments.manage` (global only).

| Field | Type | Required | Rules |
| --- | --- | --- | --- |
| `name` | string | yes | |
| `slug` | string | no | Lower-case letters, digits, `-`. Default: made from the name. Fixed after creation; the group is `dept-<slug>`. |
| `description` | string | no | |
| `default_roles` | array | no | Each `{"role_name": "<module>:<role>"}`; checked against the module catalogs, which also give the group; duplicates are dropped; `scope` defaults to `global`. |
| `default_bundles` | array of UUID | no | [Access groups](#access-groups) every new member gets. |

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" $HR/api/departments -d '{
  "name": "Tech", "description": "Stage tech, network and streaming.",
  "default_roles": [{"role_name": "stash:volunteer"}],
  "default_bundles": ["6e5d4c3b-2a19-4f08-9e7d-6c5b4a392817"]
}'
```

**201** with the department. Errors: **422** `name: required`,
`slug: lowercase letters, digits and dashes only`,
`slug: already used by another department`,
`default_roles: role_name must look like <module>:<role>`,
`some roles cannot be assigned` (details per role, as for
[access](#put-apipeopleidaccess)), `default_bundles: unknown access group`.
A Keycloak failure does **not** fail the request; it shows in
`idp_sync_error`.

### `GET /api/departments/{id}`

One department (also an archived one). **Access:** `people.read`.
**404** `department not found`.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $HR/api/departments/5b0c7f1e-9d2a-4c3b-8e6f-1a2b3c4d5e6f
```

### `PUT /api/departments/{id}`

Change `name`, `description`, `default_roles` and `default_bundles` (send
all of them; a missing `default_bundles` clears it; `slug` is ignored and
never changes). Changing default access does not touch people who are
already members. Calls the department hooks again. **Access:**
`departments.manage` (global only). **200** with the department; errors as
for create plus **404**.

```sh
curl -s -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  $HR/api/departments/5b0c7f1e-9d2a-4c3b-8e6f-1a2b3c4d5e6f -d '{
    "name": "Tech & Stage", "description": "Stage tech, network and streaming.",
    "default_roles": [{"role_name": "stash:volunteer"}], "default_bundles": []
  }'
```

### `PUT /api/departments/{id}/leads`

Replace the department's lead list. Leads get the role **lead** for this
department. In Keycloak, HR gives each new lead the department's lead
group and the HR lead group (first of `HR_LEAD_GROUPS`); people removed
from their last lead list lose the HR lead group again. **Access:**
`departments.manage` (global only).

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `person_ids` | array of UUID | yes | HR people; an empty list removes every lead. |

```sh
curl -s -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  $HR/api/departments/5b0c7f1e-9d2a-4c3b-8e6f-1a2b3c4d5e6f/leads \
  -d '{"person_ids": ["d4c3b2a1-2222-4e2f-8a9b-0c1d2e3f4a5b"]}'
```

```json
{
  "department": { "id": "5b0c7f1e-9d2a-4c3b-8e6f-1a2b3c4d5e6f", "name": "Tech", "lead_group": "dept-tech-lead",
                  "leads": [{ "person_id": "d4c3b2a1-2222-4e2f-8a9b-0c1d2e3f4a5b", "display_name": "lena" }], "…": "…" },
  "warnings": []
}
```

`warnings` lists Keycloak problems, for example
`lena has no account yet; they get the lead groups when they are onboarded.`
The lead list is saved either way. A lead's new permissions apply on
their next request; the Keycloak groups once they get a new token.

Errors: **422** `person_ids: unknown person`, **404** `department not found`.

### `POST /api/departments/{id}/archive` and `POST /api/departments/{id}/restore`

Archive a department (no new onboardings, it disappears from lists and
self-service, its leads lose their lead permissions; existing members keep
their access) or restore it. No body. Both call the
[department hooks](#department-hooks-outbound) with the new `archived`
value. **Access:** `departments.manage` (global only).

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  $HR/api/departments/5b0c7f1e-9d2a-4c3b-8e6f-1a2b3c4d5e6f/archive
```

**200** with the department (`"archived_at": "2026-11-11T17:00:00Z"`;
restore removes it). Errors: **404** `department not found`. Onboarding
into an archived department answers **422**
`department_id: this department is archived`.

### Department hooks (outbound)

When a department is created, saved, archived or restored, HR sends this
to every entry of `DEPARTMENT_HOOKS` (comma-separated `url|token`, see
[Configuration](configuration.md)), for example Tasks, which keeps one
space per department:

```http
POST /api/internal/departments HTTP/1.1
Authorization: Bearer <token from DEPARTMENT_HOOKS>
Content-Type: application/json

{"id":"5b0c7f1e-9d2a-4c3b-8e6f-1a2b3c4d5e6f","slug":"tech","name":"Tech","group":"dept-tech","lead_group":"dept-tech-lead","archived":false}
```

There is no event field: every call carries the department's current
state, and `archived` is `true` after an archive and `false` after a
restore. Lead changes do not call the hooks. Timeout 5 seconds. Failures
are only logged; the save still succeeds.

---

## Access groups

An **access group** (in the API: *access bundle*) is a named set of module
roles, for example *Standard volunteer* = `den:member` + `stash:volunteer`.
Onboardings, memberships, departments (as defaults) and review items hold
access groups; HR expands them into the individual Keycloak groups. Only
roles a module publishes in its catalog can be in an access group.

### The access group object

```json
{
  "id": "6e5d4c3b-2a19-4f08-9e7d-6c5b4a392817",
  "name": "Standard volunteer",
  "description": "What every volunteer gets.",
  "roles": [
    {"role_name": "den:member", "group_name": "den-member", "scope": "global"},
    {"role_name": "stash:volunteer", "group_name": "stash-volunteer", "scope": "global"}
  ],
  "members": 42,
  "created_at": "2026-10-01T12:00:00Z",
  "updated_at": "2026-11-02T10:30:00Z"
}
```

`members` counts onboardings and memberships (draft, provisioning or
active) that hold the group.

### `GET /api/access-bundles`

Every access group by name: `{"items": [ … ]}`. **Access:** `people.read`.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $HR/api/access-bundles
```

### `GET /api/access-bundles/{id}`

One access group. **Access:** `people.read`. **404** `access group not found`.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $HR/api/access-bundles/6e5d4c3b-2a19-4f08-9e7d-6c5b4a392817
```

### `POST /api/access-bundles`

**Access:** `bundles.manage` (global only).

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `name` | string | yes | Unique. |
| `description` | string | no | |
| `roles` | array | no | Each `{"role_name": "<module>:<role>"}`; checked against the catalogs (which give the group); duplicates are dropped. |

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" $HR/api/access-bundles -d '{
  "name": "Standard volunteer", "description": "What every volunteer gets.",
  "roles": [{"role_name": "den:member"}, {"role_name": "stash:volunteer"}]
}'
```

**201** with the access group. Errors: **422** `name: required`,
`name: another access group has this name`, `some roles cannot be assigned`
(details per role).

### `PUT /api/access-bundles/{id}`

Replace name, description and roles (same body as create). When the roles
changed and someone holds the group, HR queues a background job
(`bundle.sync`) that updates every holder's planned roles and Keycloak
groups; it shows in the audit log as `bundle.sync` per person. Roles a
module has retired stay in the group until you remove them. **Access:**
`bundles.manage` (global only).

```sh
curl -s -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  $HR/api/access-bundles/6e5d4c3b-2a19-4f08-9e7d-6c5b4a392817 -d '{
    "name": "Standard volunteer", "description": "What every volunteer gets.",
    "roles": [{"role_name": "den:member"}, {"role_name": "stash:volunteer"}, {"role_name": "stash:scanner"}]
  }'
```

**200** with the access group. Errors as for create, plus **404**.

### `DELETE /api/access-bundles/{id}`

Delete an access group nobody holds. **Access:** `bundles.manage`
(global only).

```sh
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" $HR/api/access-bundles/6e5d4c3b-2a19-4f08-9e7d-6c5b4a392817
```

**204**. Errors: **409**
`this access group is still assigned to people or a department; remove it there first`,
**404**.

---

## Onboarding

**Onboarding** is how a person gets access: HR records their profile and
department (page 1 of the wizard), adjusts the planned roles and access
groups (page 2), then completes it (page 3), which queues the creation of
the Keycloak account. Behind the scenes an onboarding is an
[employment draft](#employment-drafts-low-level).

```mermaid
stateDiagram-v2
    [*] --> draft: POST /api/onboardings
    draft --> rejected: POST …/cancel
    draft --> provisioning: POST …/complete
    provisioning --> active: account created
    provisioning --> draft: Keycloak failed (fix and retry)
```

### The onboarding view

Returned by start, get, update and cancel:

```json
{
  "draft": {
    "id": "c1d2e3f4-0000-4a1b-9c8d-7e6f5a4b3c2d",
    "person_id": "a9b8c7d6-1111-4e2f-8a9b-0c1d2e3f4a5b",
    "department_id": "5b0c7f1e-9d2a-4c3b-8e6f-1a2b3c4d5e6f",
    "title": "Tech volunteer",
    "state": "draft",
    "created_by": "Dev Admin",
    "created_at": "2026-11-06T09:00:00Z",
    "updated_at": "2026-11-06T09:00:00Z",
    "roles": [
      { "id": "0d9c8b7a-6f5e-4d3c-2b1a-0f9e8d7c6b5a", "draft_id": "c1d2e3f4-0000-4a1b-9c8d-7e6f5a4b3c2d", "role_name": "stash:volunteer",
        "group_name": "stash-volunteer", "scope": "global", "created_at": "2026-11-06T09:00:00Z",
        "bundle_id": "6e5d4c3b-2a19-4f08-9e7d-6c5b4a392817", "bundle_name": "Standard volunteer" }
    ],
    "bundle_ids": ["6e5d4c3b-2a19-4f08-9e7d-6c5b4a392817"]
  },
  "person": { "id": "a9b8c7d6-1111-4e2f-8a9b-0c1d2e3f4a5b", "status": "onboarding", "…": "…" },
  "department": { "id": "5b0c7f1e-9d2a-4c3b-8e6f-1a2b3c4d5e6f", "slug": "tech", "name": "Tech", "group_name": "dept-tech", "…": "…" },
  "missing_fields": {},
  "pending_grants": []
}
```

- `missing_fields` lists profile fields that would block completion
  (normally empty, because saving already requires a complete profile; it
  catches records created under older rules).
- `pending_grants` lists roles from this onboarding waiting for training
  (only once it is `active`).
- `provisioning` appears after the first *Complete*: the latest completion
  job, see [below](#complete-an-onboarding-provisioning).

### `POST /api/onboardings`

Start onboarding. Creates the person (or updates an existing one), creates
a draft in the department, and plans the default access: every role that a
module's catalog marks as **default**, plus the department's default roles
and access groups. The person's status becomes `onboarding`. **Access:**
`onboarding.manage` (leads: into a department they lead; with `person_id`
also `people.write` on that person). Nobody onboards themselves.

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `department_id` | UUID | yes | Not archived. |
| `person` | object | yes | [The person body](#the-person-body-create-and-update); **every required field must be filled**. |
| `person_id` | UUID | no | Onboard someone HR already knows; `person` then replaces their profile. |

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" $HR/api/onboardings -d '{
  "department_id": "5b0c7f1e-9d2a-4c3b-8e6f-1a2b3c4d5e6f",
  "person": {
    "first_name": "Alex", "last_name": "Sample", "nickname": "alex",
    "date_of_birth": "1996-04-12", "email": "alex.sample@mail.example", "phone": "+43 660 1234567",
    "address": {"street": "Hauptstraße 1", "postal_code": "1010", "city": "Wien", "country": "AT"},
    "emergency_contact": {"name": "Sam Sample", "phone": "+43 660 9876543"}
  }
}'
```

**201** with the onboarding view.

| Status | Message |
| --- | --- |
| 422 | `department_id: required`, `department_id: this department is archived`, or any person field error |
| 403 | `you don't lead this department`; `you can't change your own onboarding; ask another HR admin` |
| 404 | `department not found`, `person not found` |
| 409 | `this person is banned and cannot be onboarded` |

### `GET /api/onboardings/{id}`

The onboarding view. `{id}` is the draft id. **Access:** `people.read`
(leads: onboardings in their departments).

```sh
curl -s -H "Authorization: Bearer $TOKEN" $HR/api/onboardings/c1d2e3f4-0000-4a1b-9c8d-7e6f5a4b3c2d
```

Errors: **403** `this onboarding is not in a department you lead`,
**404** `employment_draft not found`.

### `PUT /api/onboardings/{id}/details`

Re-save page 1. Same body as start (`person_id` is ignored). Switching
department resets the planned access to the new department's defaults.
**Access:** `onboarding.manage` (leads: the onboarding's department and
the new one). **200** with the onboarding view.

```sh
curl -s -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  $HR/api/onboardings/c1d2e3f4-0000-4a1b-9c8d-7e6f5a4b3c2d/details -d @onboarding.json
```

Errors: **409** `this onboarding is no longer editable` (not a draft any
more), plus the start errors.

To change the planned roles and access groups, use
[`PUT /api/drafts/{id}/roles`](#put-apidraftsidroles).

### `POST /api/onboardings/{id}/cancel`

Cancel an onboarding that is still a draft. Its state becomes `rejected`
(final). The person goes back to `applicant` unless they have another
onboarding or membership; HR keeps the person. **Access:**
`onboarding.manage` (leads: their departments). Optional body:

| Field | Type | Required |
| --- | --- | --- |
| `reason` | string | no; kept in the audit log |

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  $HR/api/onboardings/c1d2e3f4-0000-4a1b-9c8d-7e6f5a4b3c2d/cancel -d '{"reason": "Changed their mind"}'
```

**200** with the onboarding view (`"state": "rejected"`, person
`"status": "applicant"`). Errors: **409**
`only an onboarding that is still a draft can be cancelled (it is active)`,
**403**, **404**.

### Complete an onboarding (provisioning)

#### `POST /api/onboardings/{id}/complete`

Check the onboarding and queue its provisioning. No body. **Access:**
`access.manage` (leads: their departments). Nobody completes their own.

HR first checks that the draft is a `draft`, has a department, the profile
is complete and the person is not banned, then moves it to `provisioning`
and answers **202 Accepted** straight away. A background job then:

1. splits the planned roles into those granted now and those waiting for
   training (see [role requirements](#catalogs-and-training-requirements));
2. creates or links the Keycloak account (login name from the username
   template), puts it in the department group, the granted role groups and
   any lead groups, and asks Keycloak to email a set-password link (when
   `KEYCLOAK_SEND_PASSWORD_SETUP` is on and the account is new);
3. marks the draft and the person `active`;
4. creates the Google Workspace account, if that connector is on.

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  $HR/api/onboardings/c1d2e3f4-0000-4a1b-9c8d-7e6f5a4b3c2d/complete
```

```json
{
  "ok": false,
  "queued": true,
  "job_id": "9d8c7b6a-5f4e-4d3c-8b2a-1f0e9d8c7b6a",
  "draft": { "id": "c1d2e3f4-0000-4a1b-9c8d-7e6f5a4b3c2d", "state": "provisioning", "…": "…" },
  "jobs": [],
  "groups_applied": [],
  "account_created": false,
  "password_setup_email_sent": false,
  "pending_grants": []
}
```

`ok` is `false` here only because nothing has run yet. Follow the job with
[`GET /api/jobs/{job_id}`](#get-apijobsid), or read `provisioning` in
[`GET /api/onboardings/{id}`](#get-apionboardingsid):

```json
"provisioning": {
  "job_id": "9d8c7b6a-5f4e-4d3c-8b2a-1f0e9d8c7b6a",
  "status": "succeeded",
  "attempts": 1,
  "max_attempts": 3,
  "queued_at": "2026-11-06T09:05:00Z",
  "result": {
    "ok": true,
    "draft": { "id": "c1d2e3f4-0000-4a1b-9c8d-7e6f5a4b3c2d", "state": "active", "…": "…" },
    "jobs": [
      { "id": "e1f2a3b4-…", "draft_id": "c1d2e3f4-…", "target": "idp", "status": "succeeded", "attempt": 1,
        "message": "password_setup_email_sent", "started_at": "2026-11-06T09:05:00Z",
        "finished_at": "2026-11-06T09:05:01Z", "external_id": "8f7e6d5c-4b3a-4291-8f7e-6d5c4b3a2918" }
    ],
    "groups_applied": ["dept-tech", "stash-volunteer"],
    "account_created": true,
    "password_setup_email_sent": true,
    "pending_grants": []
  }
}
```

| Field | Meaning |
| --- | --- |
| `status` | `pending`, `running`, `succeeded` or `failed`. |
| `error` | Why the last attempt failed. |
| `result.password_setup_email_sent` | `false` when Keycloak could not send the email; then `password_setup_error` says why. Resend it with [`POST /api/people/{id}/password-setup-email`](#post-apipeopleidpassword-setup-email). HR never creates or returns temporary passwords. |
| `result.password_setup_skipped` | No email was due: the account already existed, or `KEYCLOAK_SEND_PASSWORD_SETUP` is off (accounts that sign in through the convention's SSO). |
| `result.pending_grants` | Roles held back until the person finishes training. |
| `result.warnings` | Problems that did not fail the onboarding (Google Workspace). |

A failed attempt is retried up to 3 attempts in total, waiting
attempts² × 30 seconds between them. Errors that a retry cannot fix (the
login name is taken, no account to link in `link` mode) fail at once.
After the last failure the draft is back in `draft`, so you can fix the
cause and call complete again.

| Status | Message |
| --- | --- |
| 409 | `onboarding is already "active"` (or `"provisioning"`, `"rejected"`) |
| 422 | `pick a department before completing`; `volunteer profile is incomplete` with the missing fields in `details` |
| 409 | `this person is banned and cannot be onboarded` |
| 403 | `this onboarding is not in a department you lead`; `you can't change your own onboarding; ask another HR admin` |

### `GET /api/jobs/{id}`

One background job: an onboarding completion (`onboarding.complete`) or
an access group update (`bundle.sync`). **Access:** `people.read`.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $HR/api/jobs/9d8c7b6a-5f4e-4d3c-8b2a-1f0e9d8c7b6a
```

```json
{
  "id": "9d8c7b6a-5f4e-4d3c-8b2a-1f0e9d8c7b6a",
  "kind": "onboarding.complete",
  "payload": {"draft_id": "c1d2e3f4-0000-4a1b-9c8d-7e6f5a4b3c2d"},
  "status": "succeeded",
  "attempts": 1,
  "max_attempts": 3,
  "created_by": "Dev Admin",
  "result": {"ok": true, "groups_applied": ["dept-tech", "stash-volunteer"], "…": "…"},
  "created_at": "2026-11-06T09:05:00Z",
  "finished_at": "2026-11-06T09:05:01Z"
}
```

`status` is `pending`, `running`, `succeeded` or `failed`; `last_error`
holds the error of the last failed attempt. For `bundle.sync`, `result` is
`{"holders": 12, "failed": []}`. Errors: **404** `job not found`.

---

## Employment drafts (low level)

An **employment draft** is the record behind an onboarding: one person, one
department, a planned list of roles and access groups, and a state
(`draft`, `provisioning`, `active`, `rejected`). The onboarding endpoints
are the friendly way to use them; these endpoints expose the drafts
directly.

### `GET /api/drafts`

One page of drafts, newest change first, **without** their roles, with
the person's and department's names. This is the onboarding list of the
web app. **Access:** `people.read`; leads only see drafts in their
departments.

| Query | Meaning |
| --- | --- |
| `state` | `draft`, `provisioning`, `active` or `rejected`. |
| `q` | Case-insensitive substring of the person's legal name, display name or email. |
| `limit`, `offset` | Paging; default 50, at most 200. |

```sh
curl -s -H "Authorization: Bearer $TOKEN" "$HR/api/drafts?state=draft&q=alex"
```

```json
{
  "items": [
    {"id": "c1d2e3f4-0000-4a1b-9c8d-7e6f5a4b3c2d", "person_id": "a9b8c7d6-1111-4e2f-8a9b-0c1d2e3f4a5b",
     "department_id": "5b0c7f1e-9d2a-4c3b-8e6f-1a2b3c4d5e6f", "title": "Tech volunteer", "state": "draft",
     "created_by": "Dev Admin", "created_at": "2026-11-06T09:00:00Z", "updated_at": "2026-11-06T09:02:00Z",
     "person_name": "alex", "department_name": "Tech"}
  ],
  "total": 1,
  "limit": 50,
  "offset": 0
}
```

### `POST /api/drafts`

Create a draft for an existing person. **Access:** `onboarding.manage`
(leads: with a `department_id` they lead).

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `person_id` | UUID | yes | |
| `department_id` | UUID | no | |
| `title` | string | without a department | Default `<department name> volunteer`. |
| `start_date`, `end_date` | RFC 3339 time | no | |
| `notes` | string | no | |

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" $HR/api/drafts \
  -d '{"person_id": "a9b8c7d6-1111-4e2f-8a9b-0c1d2e3f4a5b", "department_id": "5b0c7f1e-9d2a-4c3b-8e6f-1a2b3c4d5e6f"}'
```

**201** with the draft. Errors: **422** `person_id is required`,
`title is required`; **404** `person not found`, `department not found`;
**403**.

### `GET /api/drafts/{id}`

One draft with its roles and `bundle_ids`. **Access:** `people.read`
(leads: their departments). **404** `employment_draft not found`.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $HR/api/drafts/c1d2e3f4-0000-4a1b-9c8d-7e6f5a4b3c2d
```

### `PUT /api/drafts/{id}/roles`

Replace the planned access: individually picked roles plus access groups.
Only while the draft is in state `draft`. **Access:** `onboarding.manage`
(leads: their departments). Nobody plans their own access.

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `roles` | array | yes | Each `{"role_name": "<module>:<role>"}`; checked against the catalogs, which give the group (`group_name` is ignored). Admin-type roles need `access.assign_privileged`. |
| `bundle_ids` | array of UUID | no | Access groups; their roles are added unless picked individually. |

```sh
curl -s -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  $HR/api/drafts/c1d2e3f4-0000-4a1b-9c8d-7e6f5a4b3c2d/roles -d '{
    "roles": [{"role_name": "events:reviewer"}],
    "bundle_ids": ["6e5d4c3b-2a19-4f08-9e7d-6c5b4a392817"]
  }'
```

```json
{"roles": [
  {"id": "…", "draft_id": "c1d2e3f4-…", "role_name": "events:reviewer", "group_name": "events-reviewer", "scope": "global", "created_at": "2026-11-06T09:02:00Z"},
  {"id": "…", "draft_id": "c1d2e3f4-…", "role_name": "stash:volunteer", "group_name": "stash-volunteer", "scope": "global", "created_at": "2026-11-06T09:02:00Z",
   "bundle_id": "6e5d4c3b-2a19-4f08-9e7d-6c5b4a392817", "bundle_name": "Standard volunteer"}
]}
```

Errors: **422** `each role requires role_name`,
`some roles cannot be assigned` (details per role),
`bundle_ids: unknown access group`; **404**; **409**
`roles can only be assigned while the draft is in state 'draft'`; **403**.

### `GET /api/drafts/{id}/provisioning-jobs`

Every provisioning attempt for a draft, newest first: `{"items": [ … ]}`
with the job objects shown under
[complete](#post-apionboardingsidcomplete). **Access:** `people.read`
(leads: their departments).

```sh
curl -s -H "Authorization: Bearer $TOKEN" $HR/api/drafts/c1d2e3f4-0000-4a1b-9c8d-7e6f5a4b3c2d/provisioning-jobs
```

`target` is `idp` or `workspace`; `status` is `pending`, `running`,
`succeeded` or `failed`; `message` holds the outcome
(`password_setup_email_sent`, `password_setup_skipped`,
`password_setup_email_failed: <reason>`, `workspace_account_created`) or
the error of a failed job. Job messages never contain passwords.

---

## Review queue

The **review queue** holds people HR does not know yet, waiting for a
human decision. Entries (*review items*) come from three sources:

| `source` | Where from |
| --- | --- |
| `idp_scan` | Keycloak accounts without an HR record, found by the scan (every `REVIEW_SCAN_INTERVAL`, default 15 minutes, or [on demand](#post-apireviewscan)). |
| `self_service` | Volunteers who filled in the [self-service registration](#self-service-registration). |
| `import` | Rows of a [spreadsheet import](#spreadsheet-imports). |

An item is `pending` (profile incomplete) or `ready` (complete), and ends
`accepted` (a new person was onboarded), `merged` (linked to an existing
person) or `rejected`. HR never decides on its own: an email match is only
a hint (`match_kind`).

### The review item object

```json
{
  "id": "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d",
  "source": "idp_scan",
  "status": "pending",
  "idp_user_id": "3c2b1a09-8f7e-4d6c-b5a4-938271605f4e",
  "email": "nina.neu@mail.example",
  "email_verified": true,
  "first_name": "Nina",
  "last_name": "Neu",
  "nickname": "",
  "phone": "",
  "data": {"address": {"street": "", "postal_code": "", "city": "", "country": ""}, "emergency_contact": {}},
  "department_id": "5b0c7f1e-9d2a-4c3b-8e6f-1a2b3c4d5e6f",
  "bundle_ids": [],
  "match_person_id": "a9b8c7d6-1111-4e2f-8a9b-0c1d2e3f4a5b",
  "match_kind": "verified_email",
  "created_at": "2026-11-10T08:15:00Z",
  "updated_at": "2026-11-10T08:15:00Z"
}
```

| Field | Notes |
| --- | --- |
| `idp_user_id` | The Keycloak account (scan items, and import items the scan linked to an account with the same verified email). |
| `data` | The rest of the profile: `date_of_birth`, `address`, `emergency_contact`, `social_handles`, `org_email`, `notes`, plus `roles` (role names an import row asked for) and `warnings` (problems the importer found). |
| `match_person_id`, `match_kind` | An existing person with the same email: `verified_email` (the identity provider verified the address) or `possible` (not verified). Merge candidates, never applied automatically. |
| `import_batch_id`, `external_ref` | The import and the row's id column (import items). |
| `person_id`, `draft_id`, `decided_by`, `decided_at`, `decision_note` | Set once decided. |

### `GET /api/review`

One page of the queue: `ready` items first, then oldest first.
**Access:** `review.manage`; leads only see items whose department they
lead (items without a department are for admins).

| Query | Meaning |
| --- | --- |
| `status` | Empty (default): open items (`pending` and `ready`). Or one of `pending`, `ready`, `accepted`, `merged`, `rejected`. |
| `source` | `idp_scan`, `self_service` or `import`. |
| `q` | Case-insensitive substring of email, first + last name, or nickname. |
| `import_batch_id` | Only items of this import. |
| `limit`, `offset` | Paging; default 50, at most 200. |

```sh
curl -s -H "Authorization: Bearer $TOKEN" "$HR/api/review?source=self_service&limit=20"
```

```json
{"items": [ { "id": "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", "source": "self_service", "status": "ready", "…": "…" } ],
 "total": 1, "limit": 20, "offset": 0}
```

Errors: **400** `import_batch_id must be a uuid`.

### `POST /api/review/scan`

Scan Keycloak now. Every enabled account without an `hrPersonId`
attribute and without an HR record or open item becomes an `idp_scan`
item. If an open import item has the same **verified** email, HR links
that item to the account instead. No body. **Access:** `review.manage`
(global only).

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" $HR/api/review/scan
```

```json
{"seen":120,"created":3,"linked":1}
```

Errors: **409**
`the identity provider cannot be scanned (IDP_PROVISIONER_MODE=off or no Keycloak)`;
**502** `could not scan the identity provider: …`.

### `GET /api/review/{id}`

One item. **Access:** `review.manage` (leads: items of their departments).

```sh
curl -s -H "Authorization: Bearer $TOKEN" $HR/api/review/0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d
```

Errors: **404** `review item not found`, **403**
`this item is not in a department you lead`.

### `PUT /api/review/{id}`

Assign the department and access groups of an open item, or add a note.
**Access:** `review.manage`; leads must send a `department_id` they lead.

| Field | Type | Notes |
| --- | --- | --- |
| `department_id` | UUID or `null` | Replaces the stored department; `null` clears it, leaving it out keeps it. |
| `bundle_ids` | array of UUID | Replaces the stored access groups; `[]` clears them, leaving it out keeps them. |
| `notes` | string | Optional; leaving it out keeps the note. |

```sh
curl -s -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  $HR/api/review/0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d -d '{
    "department_id": "5b0c7f1e-9d2a-4c3b-8e6f-1a2b3c4d5e6f",
    "bundle_ids": ["6e5d4c3b-2a19-4f08-9e7d-6c5b4a392817"],
    "notes": "Met at the info desk"
  }'
```

**200** with the item. Errors: **409** `this item was already accepted`
(or `merged`, `rejected`), **403**, **404**.

### `POST /api/review/{id}/accept`

Create the person and an onboarding in the department from the checked
item, linked to the item's account (scan) or signed-in subject
(self-service). **Access:** `review.manage`, plus `onboarding.manage` in
the target department, plus `access.manage` there when `complete` is set
(leads: departments they lead).

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `person` | object | yes | [The person body](#the-person-body-create-and-update), complete. `email` defaults to the item's. |
| `department_id` | UUID | yes | |
| `roles` | array | no | Extra individually picked roles. |
| `bundle_ids` | array of UUID | no | Access groups; default: the item's. |
| `complete` | bool | no | Also [complete](#post-apionboardingsidcomplete) the onboarding right away. |
| `note` | string | no | Kept as `decision_note`. |

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  $HR/api/review/0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d/accept -d '{
    "department_id": "5b0c7f1e-9d2a-4c3b-8e6f-1a2b3c4d5e6f",
    "person": {
      "first_name": "Nina", "last_name": "Neu", "nickname": "nina", "date_of_birth": "1999-02-03",
      "phone": "+43 660 1112233",
      "address": {"street": "Ringstraße 5", "postal_code": "1010", "city": "Wien", "country": "AT"},
      "emergency_contact": {"name": "Nils Neu", "phone": "+43 660 4445566"}
    },
    "complete": true
  }'
```

```json
{
  "item": { "id": "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", "status": "accepted", "person_id": "b7a6c5d4-…", "draft_id": "f0e1d2c3-…", "…": "…" },
  "onboarding": { "draft": { "id": "f0e1d2c3-…", "state": "provisioning", "…": "…" }, "person": { "…": "…" }, "…": "…" },
  "complete": { "ok": false, "queued": true, "job_id": "…", "…": "…" }
}
```

`complete` is only present when you asked for it; it is the queued answer
of [complete](#post-apionboardingsidcomplete).

Errors: **409** `this item was already …`; **422** person field errors
(for example `email: another person already uses this email`: merge
instead), `department_id: required`, `department_id: this department is archived`,
`some roles cannot be assigned`; **403** `you don't lead this department`;
**404**.

### `POST /api/review/{id}/merge`

Link the item, and its account, to an existing person instead. HR stores
the account on the person, adds the groups of the person's memberships
(and lead groups) to the account and writes the `hrPersonId` attribute.
**Access:** `review.manage`, plus `people.write` on that person (leads:
people in their departments). Nobody merges into their own record.

| Field | Type | Required |
| --- | --- | --- |
| `person_id` | UUID | yes |
| `note` | string | no |

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  $HR/api/review/0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d/merge \
  -d '{"person_id": "a9b8c7d6-1111-4e2f-8a9b-0c1d2e3f4a5b", "note": "Same person, new SSO account"}'
```

**200** with the item (`"status": "merged"`). Keycloak problems while
adding groups or attributes do not fail the merge; they are recorded in
the audit entry `review.merge`.

Errors: **409** `alex already has another account; offboard or fix that first`,
`this item was already …`; **404** `person not found`; **403**.

### `POST /api/review/{id}/reject`

Close the item. With `IDP_PROVISIONER_MODE=manage` HR also **disables the
item's account**; in `link` mode it leaves the account alone and says so.
**Access:** `review.manage` (leads: items of their departments). Optional
body:

| Field | Type | Required |
| --- | --- | --- |
| `reason` | string | no; kept as `decision_note` |

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  $HR/api/review/0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d/reject -d '{"reason": "Not one of ours"}'
```

```json
{"item": {"id": "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", "status": "rejected", "decision_note": "Not one of ours", "…": "…"}, "warnings": []}
```

Errors: **409** `this item was already …`; **502** Keycloak could not
disable the account (nothing is changed); **403**; **404**.

---

## Spreadsheet imports

An import loads a volunteer list (`.xlsx`, or `.csv` with `,`, `;` or tab)
into the [review queue](#review-queue). Rows never become people directly:
valid rows become `import` review items that someone still accepts or
merges. Running the same file again **updates** the open items (matched
on email or the id column) instead of duplicating them, and never deletes.
HR does not keep the uploaded file, only the mapped fields. All import
endpoints need **`import.run` (global only)**, so in practice HR admins.

The file endpoints take `multipart/form-data` with:

| Part | Required | Notes |
| --- | --- | --- |
| `file` | yes | At most 10 MB and 10,000 rows. |
| `options` | no (yes for preview and commit) | JSON, see below. |

| Option | Notes |
| --- | --- |
| `sheet` | Sheet name (`.xlsx`); default the first. |
| `header_row` | 1-based row of the column headers; `0` or missing finds the first row with two filled cells (skipping title rows). |
| `columns` | HR field → header in the file. Fields: `first_name`, `last_name`, `full_name`, `nickname`, `email`, `org_email`, `phone`, `date_of_birth`, `street`, `postal_code`, `city`, `country`, `emergency_name`, `emergency_phone`, `emergency_email`, `department`, `roles`, `notes`, `external_id`. `email` is required. |
| `department_values` | Values of the department column → department id, for values that are not a department's name or slug (`{"Sec": "<id>"}`). |
| `default_department_id` | Department for rows without one. |

Values of the `roles` column that match an [access group](#access-groups)
name are assigned; others are kept in `data.roles` for the reviewer.

### `POST /api/imports/inspect`

Read a file before mapping: sheets, headers, a sample and suggested
columns (HR recognises English, German, Dutch and French headers).
Options `sheet` and `header_row` are used; `columns` is ignored.

```sh
curl -s -H "Authorization: Bearer $TOKEN" -F file=@volunteers.csv $HR/api/imports/inspect
```

```json
{
  "format": "csv",
  "encoding": "utf-8",
  "delimiter": ";",
  "sheets": ["volunteers"],
  "sheet": "volunteers",
  "header_row": 2,
  "headers": ["Voornaam", "Achternaam", "E-mail", "Telefoon", "Afdeling", "Geboortedatum"],
  "sample": [["Anna", "Alpha", "anna@mail.example", "+44 20 7946 0000", "Sec", "10.12.1990"]],
  "rows": 4,
  "suggested_columns": {"first_name": "Voornaam", "last_name": "Achternaam", "email": "E-mail", "phone": "Telefoon",
                        "department": "Afdeling", "date_of_birth": "Geboortedatum"},
  "fields": ["first_name", "last_name", "full_name", "nickname", "email", "…"]
}
```

### `POST /api/imports/preview`

The dry run: what each row would do, without writing anything.

```sh
curl -s -H "Authorization: Bearer $TOKEN" -F file=@volunteers.csv \
  -F 'options={"columns":{"first_name":"Voornaam","last_name":"Achternaam","email":"E-mail","phone":"Telefoon","department":"Afdeling"},"department_values":{"Sec":"5b0c7f1e-9d2a-4c3b-8e6f-1a2b3c4d5e6f"}}' \
  $HR/api/imports/preview
```

```json
{
  "rows": [
    {"row": 3, "status": "new", "email": "anna@mail.example", "name": "Anna Alpha", "problems": [],
     "warnings": [], "department_id": "5b0c7f1e-9d2a-4c3b-8e6f-1a2b3c4d5e6f", "bundle_ids": []},
    {"row": 4, "status": "new", "email": "ben@mail.example", "name": "Ben Beta", "problems": [],
     "warnings": ["email \"mailto: BEN@MAIL.EXAMPLE \" cleaned to ben@mail.example", "phone 442079460001 was stored as a number, so a leading + or 0 may be missing; check it"],
     "department_id": "5b0c7f1e-9d2a-4c3b-8e6f-1a2b3c4d5e6f", "bundle_ids": []},
    {"row": 5, "status": "error", "email": "", "name": "Cleo Gamma", "problems": ["email is missing"], "warnings": [], "bundle_ids": []},
    {"row": 6, "status": "duplicate", "email": "anna@mail.example", "name": "Anna Again", "problems": ["same email as row 3"], "warnings": [], "bundle_ids": []}
  ],
  "summary": {"new": 2, "update": 0, "unchanged": 0, "error": 1, "duplicate": 1}
}
```

`status` is `new`, `update` (an open import item with that email or id
exists and changes), `unchanged`, `error` or `duplicate`. `problems` keep
a row out; `warnings` are imported and shown to the reviewer.
`match_person_id` marks an existing HR person with that email (merge
instead of accepting); `review_item_id` the item an `update` changes.

Add `?report=xlsx` to download the rows with problems as an Excel file
instead of JSON:

```sh
curl -s -H "Authorization: Bearer $TOKEN" -F file=@volunteers.csv -F 'options={"columns":{"email":"E-mail"}}' \
  -o problems.xlsx "$HR/api/imports/preview?report=xlsx"
```

### `POST /api/imports`

Commit: the same input as preview; valid rows go into the review queue as
one **batch**.

```sh
curl -s -H "Authorization: Bearer $TOKEN" -F file=@volunteers.csv \
  -F 'options={"columns":{"first_name":"Voornaam","last_name":"Achternaam","email":"E-mail"}}' $HR/api/imports
```

**201** with the batch:

```json
{
  "id": "7c6b5a49-3827-4165-9f4e-3d2c1b0a9f8e",
  "file_name": "volunteers.csv",
  "created_by": "Dev Admin",
  "created_at": "2026-11-11T16:40:00Z",
  "rows_total": 4,
  "rows_created": 2,
  "rows_updated": 0,
  "rows_failed": 2,
  "errors": [
    {"row": 5, "problem": "email is missing", "values": {"email": "", "first_name": "Cleo", "last_name": "Gamma"}},
    {"row": 6, "problem": "same email as row 3", "values": {"email": "anna@mail.example", "first_name": "Anna", "last_name": "Again"}}
  ],
  "open": 2
}
```

`open` counts the batch's items still waiting for review; `undone_at`
appears once the batch was undone.

Errors for inspect, preview and commit:

| Status | Message |
| --- | --- |
| 400 | `send the file as multipart/form-data (at most 10 MB): …`; `options must be JSON: …` |
| 422 | `file: required`; `unsupported file: save it as .xlsx (Excel workbook) or .csv and upload that`; `the sheet has more than 10000 rows; split it into several files`; `the file is larger than 10 MB` |
| 422 | `sheet: no sheet named …`; `header_row: no header row found` |
| 422 | `columns.email: map a column to email; it is used to contact and match people`; `columns.phone: no column named Telefon` |

### `GET /api/imports`

The 100 newest batches, newest first, without their error rows:
`{"items": [ … ]}`.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $HR/api/imports
```

### `GET /api/imports/{id}`

One batch with its `errors`. **404** `import not found`.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $HR/api/imports/7c6b5a49-3827-4165-9f4e-3d2c1b0a9f8e
```

### `GET /api/imports/{id}/errors`

The batch's failed rows as an Excel file
(`import-<rows_failed>-problems.xlsx`) with the mapped values and a
`problem` column, to fix and upload again.

```sh
curl -s -H "Authorization: Bearer $TOKEN" -o problems.xlsx \
  $HR/api/imports/7c6b5a49-3827-4165-9f4e-3d2c1b0a9f8e/errors
```

**404** `import not found`.

### `DELETE /api/imports/{id}`

**Undo** a batch: delete its review items, as long as none of them was
accepted or merged. The batch itself stays, marked with `undone_at`.

```sh
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" $HR/api/imports/7c6b5a49-3827-4165-9f4e-3d2c1b0a9f8e
```

**200** with the batch (`"undone_at": "2026-11-11T16:45:00Z"`, `"open": 0`).

| Status | Message |
| --- | --- |
| 409 | `this import was already undone` |
| 409 | `1 people from this import were already accepted or merged, so it can no longer be undone` |
| 404 | `import not found` |

### Import templates

A template saves a mapping (the `options` above) under a name, for files
that come in the same layout every year.

#### `GET /api/import-templates`

```sh
curl -s -H "Authorization: Bearer $TOKEN" $HR/api/import-templates
```

```json
{"items": [
  {"id": "2b3c4d5e-6f7a-4b8c-9d0e-1f2a3b4c5d6e", "name": "Volunteer form 2026",
   "mapping": {"columns": {"first_name": "Voornaam", "email": "E-mail"}, "department_values": {"Sec": "5b0c7f1e-9d2a-4c3b-8e6f-1a2b3c4d5e6f"}},
   "updated_at": "2026-11-11T16:30:00Z"}
]}
```

#### `POST /api/import-templates`

Create a template, or replace the one with the same name (case-insensitive).

| Field | Type | Required |
| --- | --- | --- |
| `name` | string | yes |
| `mapping` | object | the import options (`sheet`, `header_row`, `columns`, `department_values`, `default_department_id`) |

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" $HR/api/import-templates -d '{
  "name": "Volunteer form 2026",
  "mapping": {"columns": {"first_name": "Voornaam", "email": "E-mail"}}
}'
```

**200** with the template. Errors: **422** `name: required`.

#### `DELETE /api/import-templates/{id}`

```sh
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" $HR/api/import-templates/2b3c4d5e-6f7a-4b8c-9d0e-1f2a3b4c5d6e
```

**204**. **404** `import template not found`.

---

## Catalogs and training requirements

### `GET /api/access-catalog`

Every role HR can assign: HR's own catalog followed by each module in
`ROLE_CATALOG_SOURCES` and the modules Den knows (fetched live, cached for
30 seconds). When a module cannot be reached, HR shows its last known
catalog (`"status": "cached"`). **Access:** `people.read`.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $HR/api/access-catalog
```

```json
{"modules": [
  {"module": "hr", "display_name": "HR", "roles": [ … ], "source": "self", "status": "ok"},
  {"module": "stash", "display_name": "Stash", "description": "Inventory.", "roles": [
     {"key": "volunteer", "label": "Volunteer", "group": "stash-volunteer", "assignable": true, "default": true, "scope": "organization", "permissions": ["item.view"]}
   ], "source": "https://stash-backend.conservices-stash.svc.cluster.local:8080/api/role-catalog", "status": "ok"},
  {"module": "events", "display_name": "events", "roles": [ … ], "source": "https://rally-backend.conservices-rally.svc.cluster.local:8080/api/role-catalog",
   "status": "cached", "error": "Get \"https://rally-backend…\": context deadline exceeded", "fetched_at": "2026-11-11T15:58:00Z"}
]}
```

A role is assigned by planning `"<module>:<key>"`; HR uses its `group`.
Roles with `"default": true` are planned for every new onboarding.
`"privileged": true` (or a key or group ending in `admin`) marks an
admin-type role that needs `access.assign_privileged`. `status` is `ok`,
`cached` or `error` (unreachable and never seen).

### `GET /api/qualification-catalog`

Qualifications (trainings) from `QUALIFICATION_CATALOG_SOURCES`, usually
Learn. **Access:** `people.read`.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $HR/api/qualification-catalog
```

```json
{"modules": [
  {"module": "learn", "display_name": "Learn", "qualifications": [
     {"key": "forklift", "name": "Forklift licence", "valid_months": 24}
   ], "source": "http://learn-backend…/api/…", "status": "ok"}
]}
```

### `GET /api/role-requirements`

Which roles need which qualification before HR grants them. **Access:**
`people.read`.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $HR/api/role-requirements
```

```json
{
  "active": true,
  "items": [
    {"id": "7a6b5c4d-…", "role_key": "stash:forklift-driver", "qualification_key": "forklift",
     "qualification_name": "Forklift licence", "revoke_on_expiry": true, "created_at": "2026-10-20T10:00:00Z"}
  ]
}
```

`active` is `false` when gating is off (no `LEARN_HOLDINGS_URL` and
`LEARN_SERVICE_TOKEN`); requirements are then stored but not enforced.

### `POST /api/role-requirements`

**Access:** `requirements.manage` (global only).

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `role_key` | string | yes | `<module>:<key>` |
| `qualification_key` | string | yes | A key from the qualification catalog. |
| `revoke_on_expiry` | bool | no | Remove the group again when the qualification expires. |

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  $HR/api/role-requirements -d '{"role_key":"stash:forklift-driver","qualification_key":"forklift","revoke_on_expiry":true}'
```

**201** with the requirement. Errors: **422** `role_key: pick a role (<module>:<key>)`,
`qualification_key: required`; **409** `this role already requires that qualification`.

### `DELETE /api/role-requirements/{id}`

**Access:** `requirements.delete`. Leads hold this permission, and
requirements are not tied to a department, so any lead can delete any
requirement.

```sh
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" $HR/api/role-requirements/7a6b5c4d-0000-4000-8000-000000000001
```

**204**. Roles waiting only on this requirement are granted on the
background worker's next cycle. **404** `role requirement not found`.

### Pending grants

A **pending grant** is a planned role that HR held back because the person
lacks a required qualification. A background worker grants it once Learn
reports the qualification.

#### `GET /api/pending-grants`

**Access:** `people.read`; leads only see grants of people in their
departments. Query `status`: `pending`, `granted`, `overridden` or
`revoked` (**422** `status: pending, granted, overridden or revoked` for
anything else).

```sh
curl -s -H "Authorization: Bearer $TOKEN" "$HR/api/pending-grants?status=pending"
```

```json
{
  "active": true,
  "items": [
    {"id": "3c4d5e6f-…", "person_id": "a9b8c7d6-…", "person_name": "alex",
     "draft_id": "c1d2e3f4-…", "role_key": "stash:forklift-driver", "group_name": "stash-forklift",
     "status": "pending", "created_at": "2026-11-06T09:05:01Z",
     "waiting_for": [{"key": "forklift", "name": "Forklift licence"}]}
  ]
}
```

#### `POST /api/pending-grants/{id}/override`

Grant the role now, without the training. Adds the Keycloak group
immediately. **Access:** `training.override` (leads: people in their
departments). Nobody overrides their own requirements.

| Field | Type | Required |
| --- | --- | --- |
| `reason` | string | yes |

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  $HR/api/pending-grants/3c4d5e6f-0000-4000-8000-000000000001/override -d '{"reason":"Certified at another event"}'
```

**200** with the grant (`status: "overridden"`). Errors: **422**
`reason: required`; **404** `pending grant not found`; **409**
`this role is already granted` (or `overridden`, `revoked`),
`this person has no account yet, so the role cannot be granted`,
`this person's Keycloak account no longer exists`; **403**; **502**
Keycloak failed.

---

## Settings

### `GET /api/settings`

HR's settings. **Access:** any HR role (admins, viewers and leads can read
them, including `admin_notification_emails`).

```sh
curl -s -H "Authorization: Bearer $TOKEN" $HR/api/settings
```

```json
{
  "organization_name": "Example Con e.V.",
  "org_email_domain": "example.org",
  "username_template": "{nickname}",
  "org_email_template": "{first}.{last}",
  "default_country": "AT",
  "address_lookup_url": "https://photon.komoot.io",
  "admin_notification_emails": "hr@example.org",
  "identity": {
    "staff_mode": "",
    "sso_name": "",
    "sso_url": "",
    "admin_console_url": "",
    "effective": {"staff_mode": "own", "sso_name": "", "sso_url": "", "admin_console_url": "https://auth.conservices.test/admin/conservices/console/"}
  },
  "retention": {
    "enabled": true,
    "applicant_days": 180,
    "paused_days": 730,
    "offboarded_audit_days": 365,
    "warning_days": 14
  },
  "workspace": {
    "enabled": false,
    "domain": "",
    "admin_email": "",
    "org_unit": "/",
    "delete_after_days": 30,
    "reminder_days": 7,
    "available": false
  },
  "managed_by": "den"
}
```

| Field | Meaning |
| --- | --- |
| `managed_by: "den"` | HR is paired: `organization_name`, `org_email_domain`, `username_template` and `org_email_template` come from Den's [organisation settings](../den/api.md#organisation-settings) and are read-only here. |
| `admin_notification_emails` | Comma-separated addresses for HR's notices to admins (retention and Workspace deletion warnings). Empty: the members of the HR admin groups. |
| `identity` | How staff sign in. `staff_mode` is `own` (Con Services accounts), `brokered` or `existing` (the convention's SSO); `sso_name` and `sso_url` name and link that SSO in the offboarding warning; `admin_console_url` is the *Open Keycloak* link. Values set here override Den's; `effective` (read-only) shows the result. |
| `retention` | How long HR keeps personal data ([Personal data](personal-data.md#when-hr-deletes-it)). `managed_by: "den"` inside it means Den's module settings set it, and HR ignores changes. |
| `workspace` | The [Google Workspace connector](google-workspace.md). `available` (read-only) is `true` when `GOOGLE_WORKSPACE_CREDENTIALS_FILE` is set. |

### `PUT /api/settings`

Change settings. Send only the fields you change: HR applies the body on
top of the current settings. **Access:** `settings.manage` (global only).

| Field | Rules | While paired with Den |
| --- | --- | --- |
| `organization_name` | Free text. | ignored |
| `org_email_domain` | A domain like `example.org`; a leading `@` is removed. | ignored |
| `username_template`, `org_email_template` | Letters, digits, `.`, `-`, `_` and at least one of `{first}`, `{last}`, `{nickname}`. | ignored |
| `default_country` | Two-letter ISO code, for phone numbers and address suggestions. | saved |
| `address_lookup_url` | An http(s) URL of a Photon server; empty turns suggestions off. An internal address is refused unless it is listed in `OUTBOUND_ALLOWED_HOSTS`. | saved |
| `admin_notification_emails` | Comma-separated email addresses. | saved |
| `identity.staff_mode` | `own`, `brokered`, `existing` or empty (use Den's). | saved |
| `identity.sso_url`, `identity.admin_console_url` | http(s) URLs. | saved |
| `retention.applicant_days`, `retention.paused_days`, `retention.offboarded_audit_days` | 1 to 3650. | saved, unless Den sets retention |
| `retention.warning_days` | 1 to 90. | saved, unless Den sets retention |
| `workspace.enabled` | `true` only while `workspace.available` is `true` (else **422**, field `workspace.enabled`). | saved |
| `workspace.domain`, `workspace.admin_email`, `workspace.org_unit` | A domain; an email (required when `enabled`); a path starting with `/`. | saved |
| `workspace.delete_after_days`, `workspace.reminder_days` | At least 1; 0 or more and fewer than the days before deletion. | saved |

```sh
curl -s -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" $HR/api/settings -d '{
  "default_country": "AT",
  "admin_notification_emails": "hr@example.org",
  "retention": {"enabled": true, "applicant_days": 180, "paused_days": 730, "offboarded_audit_days": 365, "warning_days": 14}
}'
```

**200** with the settings, as `GET`. A nested object you send
(`identity`, `retention`, `workspace`) replaces that whole object, so send
all its fields. Errors: **422** with one message per field, for example
`default_country: must be a two-letter country code, e.g. AT` or
`retention.warning_days: between 1 and 90 days`. While paired, the
organisation fields are silently ignored (no error); `managed_by`,
`identity.effective` and `workspace.available` in the body are ignored too.

---

## Den pairing

Connects HR to Den so it follows Den's brand and organisation settings.
See [Pairing](../../concepts/pairing.md). **Access:** `den.manage` (global
only). Every call is recorded in HR's audit log (`den.pair`, `den.sync`,
`den.unpair`, with `.failed` when it did not work). The public
[`GET /api/den/state`](#get-apidenstate) tells anyone whether HR is paired.

### `GET /api/den`

```sh
curl -s -H "Authorization: Bearer $TOKEN" $HR/api/den
```

```json
{
  "paired": true,
  "den_base_url": "https://den.conservices.test",
  "module_id": "3d2c1b0a-9f8e-4d7c-b6a5-0f1e2d3c4b5a",
  "paired_at": "2026-11-03T18:25:40Z",
  "synced_at": "2026-11-06T09:14:00Z"
}
```

Not paired: `{"paired": false}`. `last_error` appears when the last sync failed.

### `POST /api/den/pair`

Redeem a pairing URL created in Den (Admin → Modules → Pair), then sync
straight away. When `DEN_INTERNAL_URL` is set, HR calls that address
instead of the URL's host.

| Field | Type | Required |
| --- | --- | --- |
| `pairing_url` | string | yes |

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" $HR/api/den/pair \
  -d '{"pairing_url":"https://den.conservices.test/api/v1/integrations/pairing/redeem?token=change-me"}'
```

**200** with the status, as `GET`. Errors (`{"error":{"code","message"}}`):

| Status | `code` | Message |
| --- | --- | --- |
| 400 | `bad_request` | `invalid JSON body` |
| 422 | `pairing_failed` | `paste the full pairing URL from Den (Admin → Modules → Pair)` |
| 422 | `pairing_failed` | `could not reach Den at den.conservices.test: …` |
| 422 | `pairing_failed` | `Den refused the pairing URL: pairing token expired` (or `already consumed`, `invalid pairing token`) |

### `POST /api/den/sync`

Fetch Den's brand and settings now (HR also does this every minute).
**200** with the status. Errors: **409** `sync_failed` when not paired,
**502** `sync_failed` when Den fails.

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" $HR/api/den/sync
```

### `DELETE /api/den/pair`

Forget the credential; HR goes back to standalone. **204**. The module
stays registered in Den; remove it there too if you are done with it.

```sh
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" $HR/api/den/pair
```

---

## Google Workspace

These endpoints serve the [Google Workspace connector](google-workspace.md).
**Access:** `workspace.manage` (global only).

The connector runs only when `GOOGLE_WORKSPACE_CREDENTIALS_FILE` is set
and an admin has turned it on. Otherwise the list is empty, *Delete now*
answers **409** `the Google Workspace connector is off`, sync answers
**409** `the Google Workspace connector is off or not available`, and
`PUT /api/settings` with `workspace.enabled: true` answers **422**.
`workspace.available` in [`GET /api/settings`](#get-apisettings) is true
when the key file is set.

### `GET /api/workspace/accounts`

The Workspace accounts HR created, ordered by their deletion date (else
creation). Query `status`: `active`, `suspended` or `deleted` (empty: all).

```sh
curl -s -H "Authorization: Bearer $TOKEN" "$HR/api/workspace/accounts?status=suspended"
```

```json
{"items": [
  {"id": "4f3e2d1c-0b9a-4887-a6f5-e4d3c2b1a098", "person_id": "a9b8c7d6-1111-4e2f-8a9b-0c1d2e3f4a5b",
   "primary_email": "alex.sample@example.org", "display_name": "alex", "status": "suspended",
   "created_at": "2026-11-06T09:05:01Z", "suspended_at": "2026-11-10T12:00:00Z",
   "delete_after": "2026-12-10T12:00:00Z", "reminded_at": "2026-12-03T03:00:00Z"}
]}
```

`last_error` appears when Google refused the last change. With HR 1.0.0:
`{"items": []}`.

### `POST /api/workspace/accounts/{id}/delete`

Delete a suspended account (of an offboarded person) now, before its
scheduled date, with its mail and files. No body.

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  $HR/api/workspace/accounts/4f3e2d1c-0b9a-4887-a6f5-e4d3c2b1a098/delete
```

**200** with the account (`"status": "deleted"`).

| Status | Message |
| --- | --- |
| 409 | `the Google Workspace connector is off` |
| 409 | `only suspended accounts of offboarded people can be deleted here` |
| 404 | `workspace account not found` |
| 502 | `Google Workspace: …` (Google refused) |

### `POST /api/workspace/sync`

Mirror every department's Google Group now (HR also does this in its
daily housekeeping). No body.

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" $HR/api/workspace/sync
```

```json
{"synced":true}
```

| Status | Message |
| --- | --- |
| 409 | `the Google Workspace connector is off or not available` |
| 502 | `Google Workspace: …` (Google refused) |

---

## Audit log and retention

### `GET /api/audit`

One page of HR's audit log, newest first. Every change in HR writes an
entry. **Access:** `audit.read` (global only: admins and viewers).

| Query | Meaning |
| --- | --- |
| `entity_type` | `person`, `employment_draft`, `department`, `access_bundle`, `review_item`, `import_batch`, `settings`, `den_link`, … |
| `entity_id` | One entity. |
| `actor` | Exact actor name, or the actor's IdP subject. |
| `action` | An exact action (`person.offboard`), or a prefix ending in `.` (`person.`). |
| `since`, `before` | `YYYY-MM-DD` or RFC 3339; `since` inclusive, `before` exclusive. |
| `limit`, `offset` | Paging; default 50, at most 200. |

```sh
curl -s -H "Authorization: Bearer $TOKEN" \
  "$HR/api/audit?entity_id=a9b8c7d6-1111-4e2f-8a9b-0c1d2e3f4a5b&action=person.&since=2026-11-01"
```

```json
{
  "items": [
    {"id": "1e2d3c4b-5a69-4788-9a6b-5c4d3e2f1a0b", "actor_name": "Dev Admin",
     "actor_issuer": "https://auth.conservices.test/realms/conservices", "actor_subject": "0f1e2d3c-…",
     "action": "person.access.change", "entity_type": "person", "entity_id": "a9b8c7d6-1111-4e2f-8a9b-0c1d2e3f4a5b",
     "metadata": {"draft_id": "c1d2e3f4-…", "added_groups": ["events-reviewer"], "removed_groups": [], "pending_roles": [], "bundles": []},
     "occurred_at": "2026-11-07T10:00:00Z"}
  ],
  "total": 1,
  "limit": 50,
  "offset": 0
}
```

`purge_after` appears on entries HR keeps after an offboarding or
retention purge, and says when they are deleted. Errors: **400**
`entity_id must be a uuid`, `since must be a date (2006-01-02) or RFC 3339 time`.

### `GET /api/retention/candidates`

The people HR's retention rules will remove within the warning period
(and those already due): applicants untouched for
`retention.applicant_days` are deleted, people paused for
`retention.paused_days` are offboarded. HR admins are emailed
`warning_days` before; nothing is removed without a delivered warning.
**Access:** `settings.manage` (global only).

```sh
curl -s -H "Authorization: Bearer $TOKEN" $HR/api/retention/candidates
```

```json
{
  "items": [
    {"person_id": "b8c7d6e5-3333-4e2f-8a9b-0c1d2e3f4a5b", "display_name": "kim", "status": "applicant",
     "due_at": "2026-11-20T10:00:00Z", "warned_at": "2026-11-06T03:00:00Z"}
  ],
  "retention": {"enabled": true, "applicant_days": 180, "paused_days": 730, "offboarded_audit_days": 365, "warning_days": 14}
}
```

To keep someone, update the applicant or reactivate the paused person
before `due_at`. With `retention.enabled: false` the list is still shown,
but nothing is removed.

---

## Checks and helpers

### `GET /api/check/email`

Is an address valid, and does its domain accept mail (MX or address
record lookup, 3-second limit)? Never blocks a save; the web app shows the
result as a warning. **Access:** `people.write`.

```sh
curl -s -H "Authorization: Bearer $TOKEN" "$HR/api/check/email?address=alex.sample@mail.example"
```

```json
{"valid":true,"deliverable":true}
```

Other answers: `{"valid":false,"reason":"not a valid email address"}`,
`{"valid":true,"deliverable":false,"reason":"this domain doesn't seem to receive email"}`,
or `{"valid":true}` when DNS could not be asked.

### `GET /api/check/username`

Preview the login name a set of names would give, and whether it is free
in HR and in Keycloak. **Access:** `people.write`.

| Query | Meaning |
| --- | --- |
| `first`, `last`, `nickname` | The names. |
| `person_id` | The person being edited (so their own name does not count as taken). |

```sh
curl -s -H "Authorization: Bearer $TOKEN" "$HR/api/check/username?first=Alex&last=Sample&nickname=alex"
```

```json
{"username":"alex","available":true}
```

Taken: `{"username":"alex","available":false,"reason":"this nickname is already taken"}`.
Errors: **400** `person_id must be a uuid`.

### `GET /api/address/search`

Address suggestions from the configured Photon (OpenStreetMap) server,
proxied so browsers never contact it. **Access:** `people.write`.

| Query | Meaning |
| --- | --- |
| `q` | At least 3 characters; shorter queries return no items. |

```sh
curl -s -H "Authorization: Bearer $TOKEN" "$HR/api/address/search?q=Hauptstra%C3%9Fe%201%20Wien"
```

```json
{
  "enabled": true,
  "items": [
    {"label": "Hauptstraße 1, 1010 Wien, AT", "street": "Hauptstraße 1", "postal_code": "1010", "city": "Wien", "country": "AT"}
  ],
  "provider": "photon.komoot.io"
}
```

- At most 6 items; addresses in `default_country` come first.
- `provider` is the server the typed text was sent to (shown in the
  privacy notice next to the field).
- `enabled: false` when `address_lookup_url` is empty.
- HR allows one lookup every 250 ms in total; extra requests get
  `"throttled": true` and no items (not a 429).
- **502** `Address suggestions are unavailable right now; type the address by hand.`
  when Photon fails.

### `GET /api/dashboard`

Everything HR's start page needs. **Access:** `people.read`; for leads
the counts, attention list and departments only cover their departments.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $HR/api/dashboard
```

```json
{
  "status_counts": {"active": 42, "onboarding": 3, "paused": 2, "applicant": 5},
  "attention": [
    {"kind": "failed_provisioning", "person_id": "a9b8c7d6-…", "display_name": "alex", "legal_name": "Alex Sample",
     "email": "alex.sample@mail.example", "draft_id": "c1d2e3f4-…",
     "detail": "The login name is already taken. Change their nickname and try again.",
     "technical": "the username \"alex\" is already used by another account; change their nickname and try again"},
    {"kind": "incomplete_profile", "person_id": "b8c7d6e5-…", "display_name": "kim", "legal_name": "Kim Example",
     "email": "kim@mail.example", "fields": ["city", "phone"], "detail": "Missing or invalid: city, phone"}
  ],
  "departments": [
    {"id": "5b0c7f1e-…", "slug": "tech", "name": "Tech", "group_name": "dept-tech", "default_roles": [], "member_count": 14,
     "active_members": 14, "in_onboarding": 1, "created_at": "…", "updated_at": "…"}
  ]
}
```

`kind` is `incomplete_profile`, `failed_provisioning` or
`stalled_onboarding` (a draft untouched for over 7 days).

### `GET /api/idp/groups`

A read-only view of the Keycloak groups HR uses (HR's role groups, module
role groups, department and lead groups, default role groups) and their
direct members, annotated with what HR uses each group for. Other realm
groups are left out. **Access:** `idp.groups.read` (global only: admins
and viewers).

```sh
curl -s -H "Authorization: Bearer $TOKEN" $HR/api/idp/groups
```

```json
{
  "available": true,
  "groups": [
    {"id": "1f2e3d4c-…", "name": "dept-tech", "path": "/dept-tech",
     "members": [{"id": "8f7e6d5c-…", "username": "alex", "email": "alex.sample@mail.example", "first_name": "Alex", "last_name": "Sample", "enabled": true}],
     "department": {"id": "5b0c7f1e-…", "name": "Tech"}},
    {"id": "2e3d4c5b-…", "name": "stash-volunteer", "path": "/stash-volunteer", "members": [], "default_for": ["Tech"]}
  ]
}
```

`available: false` (with an empty list) when HR's identity provider cannot
list groups. **502** when Keycloak fails.

---

## Directory for other modules

### `GET /api/internal/directory/groups`

The groups other modules may offer when sharing something with "a team",
for example the Wiki's share dialog: every active department's group and
its lead group, and every IdP group that an [access group](#access-groups)
grants. Each `name` is an IdP group, so a module can match it against the
`groups` claim of its users' tokens.

**Access:** service token. Send `Authorization: Bearer <HR_DIRECTORY_TOKEN>`
(a user token does not work). The endpoint is off (**404**) while
`HR_DIRECTORY_TOKEN` is not set; see [Configuration](configuration.md) and
[Secrets](../../operations/secrets.md). It is outside the Den pairing
gate. Inside the cluster it is called on the backend's service address:

```sh
curl -s -H "Authorization: Bearer change-me-directory-token" \
  https://hr-backend.conservices-hr.svc.cluster.local:8080/api/internal/directory/groups
```

```json
{
  "groups": [
    {"name": "dept-tech", "display_name": "Tech", "kind": "department"},
    {"name": "dept-tech-lead", "display_name": "Tech (leads)", "kind": "department"},
    {"name": "stash-volunteer", "display_name": "stash-volunteer (Standard volunteer, Tech crew)", "kind": "access",
     "access_groups": ["Standard volunteer", "Tech crew"]}
  ]
}
```

| Field | Meaning |
| --- | --- |
| `name` | The IdP group. |
| `kind` | `department`: a department's group (display name = department name) or its lead group (display name `<Department> (leads)`). `access`: an IdP group that one or more access groups grant. |
| `display_name` | For `access`: `<group> (<access group names>)`. |
| `access_groups` | Only for `access`: the names of the access groups that grant it. |

Archived departments are left out. A group that is both a department
group and in an access group is listed once, as `department`.

| Status | Body | When |
| --- | --- | --- |
| 404 | `{"error":{"code":"not_found","message":"directory not found"}}` | `HR_DIRECTORY_TOKEN` is not set. |
| 401 | `{"error":{"code":"unauthorized","message":"a valid HR_DIRECTORY_TOKEN bearer token is required"}}` | No, wrong or malformed token (the header must start with `Bearer `). |

---

## Troubleshooting

**`403 you don't have access to HR` although you are an admin elsewhere.**
Call [`GET /api/me`](#get-apime) and look at `groups` and `roles`. You need
one of `HR_ADMIN_GROUPS`, `HR_VIEWER_GROUPS` or `HR_LEAD_GROUPS` (defaults
`hr-admin`, `hr-viewer`, `hr-lead`). Group changes apply once you get a
new token, so sign out and in again. `HR_ACCESS_GROUPS` from earlier
previews is no longer read.

**A lead gets `403 you don't have the HR permission people.read` everywhere.**
Being in `hr-lead` is not enough: an admin must put the person on a
department's lead list ([`PUT /api/departments/{id}/leads`](#put-apidepartmentsidleads)),
and HR must know their account (their HR record's IdP subject equals the
token's `sub`). Check `lead_of` and `person_id` in `GET /api/me`. Leads of
an archived department lose their permissions there.

**`403 this person is not in a department you lead`.**
Leads only reach people with an onboarding or membership in one of their
departments. Ask an admin, or have the person onboarded into your
department.

**`503 den_pairing_required`.**
HR runs with `DEN_MODE=required` and is not paired yet. An admin pairs it
with [`POST /api/den/pair`](#post-apidenpair) (or *Connect this module to
Den* in the web app).

**`401 invalid token` with a token that works in Den.**
Tokens are checked for HR's own client. Get one with `client_id=hr-spa`.

**`422` on `POST /api/onboardings` listing many fields.**
HR requires the full volunteer profile (date of birth, phone, address,
emergency contact name and phone) before it saves anything. Send them all;
see [the person body](#the-person-body-create-and-update).

**`422 nickname: this nickname is already taken (login name alex)`.**
Someone in HR or an existing Keycloak account already has that login name.
Use [`GET /api/check/username`](#get-apicheckusername) to find a free one.

**`422 some roles cannot be assigned`.**
Read `details`: the role's module is not connected, no longer offers it,
or it is an admin role and you lack `access.assign_privileged`. Check the
[access catalog](#get-apiaccess-catalog).

**Complete answered 202, but the onboarding went back to `draft`.**
The provisioning job failed. Read `provisioning.error` in
[`GET /api/onboardings/{id}`](#get-apionboardingsid) (or the job list);
typical causes are a taken login name, or HR's Keycloak service account
lacking `manage-users`. Fix it and call complete again.

**`PUT /api/settings` answers 200 but the organisation name does not change.**
HR is paired (`managed_by: "den"`); change organisation fields in Den
([org settings](../den/api.md#organisation-settings)) and wait up to a
minute, or call [`POST /api/den/sync`](#post-apidensync).

**Offboarding answers `502` and nothing was deleted.**
Keycloak is unreachable or refused. Fix Keycloak and retry, or send
`"hr_only": true` and delete the account in the Keycloak console yourself.

**The Wiki's share dialog shows no HR teams.**
`GET /api/internal/directory/groups` answers 404 when HR has no
`HR_DIRECTORY_TOKEN`, and 401 when the Wiki sends a different value. Set
the same secret in both, and allow the Wiki → HR connection in the
[network policies](../../operations/network-policies.md).
