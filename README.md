# Con services (local suite)

Docker Desktop stack for **Stash**, **HR**, **Den**, **Events (Rally)**, shared **Postgres**, **MinIO (dev only)**, and **Keycloak (dev only)**.

## Quick start

```powershell
# from this folder — Docker Desktop must be running
# Full MVP (Stash + HR + Den + Events + Keycloak + MinIO + Postgres):
docker compose --profile den --profile events up --build -d
```

Without profiles: **Postgres + MinIO + Keycloak + Stash + HR** only.

First boot can take several minutes (image builds + Keycloak realm import). OIDC backends wait until Keycloak is healthy.

## URLs

| Service | URL |
| --- | --- |
| Stash UI | http://localhost:3000 |
| Stash API | http://localhost:8088 (host; avoids common :8080 clashes) |
| Den UI | http://localhost:3001 |
| Den API | http://localhost:8090 |
| Events (Rally) UI | http://localhost:3002 |
| Events API | http://localhost:8100 |
| HR UI | http://localhost:3003 |
| HR API | http://localhost:8110 |
| Keycloak | http://localhost:8085 |
| MinIO console | http://localhost:9001 |
| Mailpit (dev inbox for Keycloak emails) | http://localhost:8025 |

## DEV credentials (temporary — not for production)

### Keycloak admin console

- URL: http://localhost:8085
- User: `admin`
- Password: `admin`

Realm: **`conservices`** (auto-imported).

### App login users (OIDC)

| Username | Password | Groups (approx.) |
| --- | --- | --- |
| `admin` | `adminadmin` | stash-admin, den-admin, events-admin, hr-admin |
| `alice` | `alicealice` | stash-admin, events-admin, den-admin |
| `bob` | `bobbob` | stash-readonly |

Stash SPA client: `stash-spa`  
Den SPA client: `den-spa`  
Events SPA client: `events-spa`  
HR SPA client: `hr-spa` (same Keycloak; provisioner client `hr-provisioner`)

### Shared infra

| Thing | Value |
| --- | --- |
| Postgres | `localhost:5432` / user `postgres` / pass `postgres` |
| App DBs | `stash`/`stash`, `den`/`den`, `events`/`events`, `hr`/`hr` |
| MinIO API | `localhost:9000` / `conservices` / `conservicesdev` |
| Buckets | `stash-data-dev`, `den-data-dev`, `events-data-dev`, `hr-data-dev` |

**MinIO and this Keycloak are DEV ONLY. Never use them in production.** Prod uses managed S3 + your real IdP.

## Smoke check

```powershell
docker compose --profile den --profile events ps
Invoke-WebRequest http://localhost:8088/api/health
Invoke-WebRequest http://localhost:8090/livez
Invoke-WebRequest http://localhost:8100/livez
Invoke-WebRequest http://localhost:8110/livez
Invoke-WebRequest http://localhost:8085/realms/conservices
```

Then open Stash at http://localhost:3000 → Login → Keycloak → `admin` / `adminadmin`.

## Notes

- One Postgres host, **one database per module**.
- One MinIO, **one bucket per module** (no cross-bucket access).
- Stash, Den, Events, and HR use **OIDC** against local Keycloak (`conservices` realm).
- **Role catalogs:** every module serves public `GET /api/role-catalog` (`{module, display_name, roles:[{key,label,description,group,assignable,scope,permissions,note}]}`). HR aggregates them (`ROLE_CATALOG_SOURCES`) into its access picker; assigning a role adds the person to that role's Keycloak `group` (created on first use). Stash and Rally roles/descriptions/bindings live in each module's `infra/access-config.toml`.
- Den has a member **portal** (`/dashboard`) and a separate **admin console** (`/admin/*`, admins/owners only — enforced on the API too).
- **HR onboarding** (`/onboarding`): after a department approves an application, HR fills in the volunteer profile (first/last name, nickname, date of birth, private email, phone, address, emergency contact name + phone are required) and picks the department → access page prefilled with the department's default roles → review → **Complete**. Complete creates the Keycloak user (username = private email), adds the department group (`dept-<slug>`) and role groups, sets the person active, and Keycloak emails a "set your password" link that lands in Den. Nothing touches Keycloak before Complete.
- **Departments** (`/departments` in HR) own a Keycloak group, created automatically on save, plus default module roles for new members.
- Keycloak sends email through **Mailpit** in dev (realm `smtpServer`, email theme `infra/keycloak/themes/conservices`). For production, set real SMTP on the realm. If the email fails, HR falls back to a one-time temporary password shown on the review page.
- Existing dev stack: after pulling, run `docker exec conservices-keycloak bash /opt/keycloak/data/import/apply-mvp.sh` to apply SMTP and the email theme to an already-imported realm.
- **After onboarding** (HR People → click a person, or their profile): change access per department, pause/reactivate, or **offboard** (removes every HR-granted Keycloak group and disables the login; the profile is kept so they can be onboarded again). Profile edits push name/email to Keycloak. Status only changes through these actions.
- HR **Keycloak** page: read-only view of realm groups and members, tagged with the department they belong to. HR **Settings**: the organization email domain, so profile forms only ask for the part before the `@`.
- Smoke: `scripts/smoke-hr-keycloak.ps1` runs the whole onboarding against the live stack, checks Keycloak groups and the Mailpit email, then edits the profile and offboards (checks the user is disabled and out of the groups).
- **Access comes from Keycloak groups, checked on every request.** Den admins are members of `DEN_ADMIN_GROUPS` (default `den-admin`); HR requires `HR_ACCESS_GROUPS` (default `hr-admin`); Stash and Rally map groups to roles in their `infra/access-config.toml` (`stash-*`, `events-*`). Removing someone from a group revokes the access on their next request. Realm self-registration is on for greenfield.
- Branding for Den-backed mode: set style in Den; modules pull via pairing token (API), never Den’s bucket credentials.
- If an OIDC backend crash-loops right after a Keycloak recreate, wait for Keycloak healthy then `docker compose restart <service>`.

## Tear down

```powershell
docker compose down
# wipe volumes (fresh DBs / MinIO):
docker compose down -v
```
