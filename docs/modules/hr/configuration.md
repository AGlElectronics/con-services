# HR configuration

HR's backend reads its settings from **environment variables** when it
starts (plus a `.env` file in the working directory, for local
development). Restart after a change. Missing or inconsistent values stop
it with one message listing every problem:

```text
invalid config: DATABASE_URL is required; KEYCLOAK_BASE_URL is required when Keycloak provisioning is enabled
```

Source of truth:
[`backend/internal/config/config.go`](https://github.com/AGlElectronics/hr/blob/main/backend/internal/config/config.go).
Example file: [`.env.example`](https://github.com/AGlElectronics/hr/blob/main/.env.example).

**Where each value goes on Kubernetes:** *Secret* = your secret manager,
delivered as the `hr-secrets` Secret ([Secrets](../../operations/secrets.md));
*ConfigMap* = `config:` in the Helm values.

## Core

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `APP_ENV` | `development` | no | ConfigMap | `development` gives console logs; use `production` otherwise. |
| `APP_BASE_URL` | `http://localhost:8080` | no | ConfigMap | HR's public address. |
| `HTTP_ADDR` | `:8080` | no | ConfigMap | Listen address inside the container. Keep `:8080`. |
| `DATABASE_URL` | none | **yes** | **Secret** | PostgreSQL URL. Also the only setting the `hr-migrate` image reads. |
| `CORS_ALLOWED_ORIGINS` | `http://localhost:3003` | no | ConfigMap | Comma-separated browser origins allowed to call the API. |
| `SHUTDOWN_TIMEOUT` | `15s` | no | ConfigMap | Grace period for running requests on stop. |

## Sign-in to HR

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `AUTH_MODE` | `dev` | no | ConfigMap | `oidc` verifies bearer tokens. `dev` trusts `X-Dev-User` and lets everyone in: local only. |
| `OIDC_ISSUER_URL` | none | with `oidc` | ConfigMap | Token issuer, for example `https://auth.example.org/realms/conservices`. |
| `OIDC_CLIENT_ID` | none | with `oidc` | ConfigMap | Web app client (`hr-spa`). |
| `OIDC_AUDIENCE` | none | no | ConfigMap | Expected audience if different from the client id. |
| `HR_ACCESS_GROUPS` | `hr-admin` | no | ConfigMap | Comma-separated groups allowed to use HR at all (matched with or without Keycloak's leading `/`, case-insensitive). Everyone else gets 403. |
| `DEV_DEFAULT_USER` | `dev-hr-admin` | no | ConfigMap | Name used in `dev` mode without an `X-Dev-User` header. |

## Account provisioning (Keycloak)

When both `KEYCLOAK_BASE_URL` and `KEYCLOAK_CLIENT_SECRET` are set, HR
creates and deletes real accounts. When neither is set it uses a fake
provisioner that creates nothing (logged as `using FakeIdP`). Setting only
one is an error.

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `KEYCLOAK_BASE_URL` | none | for real accounts | ConfigMap | Keycloak address HR's backend can reach, for example `http://keycloak.conservices-identity.svc.cluster.local:8080`. |
| `KEYCLOAK_REALM` | `conservices` | no | ConfigMap | Realm the accounts live in. |
| `KEYCLOAK_CLIENT_ID` | `hr-provisioner` | no | ConfigMap | Service-account client used for the admin API. |
| `KEYCLOAK_CLIENT_SECRET` | none | for real accounts | **Secret** | Its secret. It can manage users: keep it in the secret manager. |
| `KEYCLOAK_SETUP_CLIENT_ID` | none | no | ConfigMap | Client the set-password email link returns to (platform: `den-spa`). |
| `KEYCLOAK_SETUP_REDIRECT_URI` | none | no | ConfigMap | Where people land after setting their password (platform: Den's address). |

## Other modules

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `ROLE_CATALOG_SOURCES` | none | no | ConfigMap | Comma-separated `slug=url` list of other modules' `GET /api/role-catalog`, for example `stash=http://stash-backend.conservices-stash.svc.cluster.local:8080/api/role-catalog,events=http://rally-backend.conservices-rally.svc.cluster.local:8080/api/role-catalog`. HR always includes its own catalog. |
| `QUALIFICATION_CATALOG_SOURCES` | none | no | ConfigMap | Same format, for qualification catalogs (Learn's `/api/qualification-catalog`). |
| `LEARN_HOLDINGS_URL` | none | no | ConfigMap | Learn's `/api/internal/holdings`. With `LEARN_SERVICE_TOKEN`, turns on training requirements for roles. |
| `LEARN_SERVICE_TOKEN` | none | no | **Secret** | Shared with Learn. |
| `ROLE_GATE_INTERVAL` | `1m` | no | ConfigMap | How often roles waiting for training are re-checked. |
| `OFFBOARD_HOOKS` | none | no | **Secret** | Comma-separated `url|token` entries called when someone is offboarded (for example the Wiki's `/api/internal/offboarded`). Failures become warnings. Secret because it contains tokens. |
| `DEPARTMENT_HOOKS` | none | no | **Secret** | Same format, called when a department is created or renamed (for example Tasks' `/api/internal/departments`). |

## Den

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `DEN_INTERNAL_URL` | none | no | ConfigMap | Replaces the host of a pasted Den pairing URL (platform: `http://den-backend.conservices-den.svc.cluster.local:8080`). Empty when standalone. |

## Email (HR's own notices)

Empty `SMTP_HOST` turns them off; HR then shows a warning instead of
sending. Password-setup emails are sent by Keycloak, not by these settings.

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `SMTP_HOST` | none | no | ConfigMap | Mail server. |
| `SMTP_PORT` | `587` | no | ConfigMap | Port. |
| `SMTP_USERNAME` | none | no | ConfigMap | Login. |
| `SMTP_PASSWORD` | none | no | **Secret** | Password. |
| `SMTP_FROM` | none | no | ConfigMap | Sender address. |
| `SMTP_FROM_NAME` | none | no | ConfigMap | Sender name. |

## Object storage

HR stores no files yet. These are read so a later feature needs no
configuration change. Leave them all empty, or set the first four together.

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `S3_ENDPOINT` | none | if any `S3_*` is set | ConfigMap | S3 API address. |
| `S3_BUCKET` | `hr-data-dev` | if any `S3_*` is set | ConfigMap | Bucket. |
| `S3_ACCESS_KEY_ID` | none | if any `S3_*` is set | **Secret** | Access key. |
| `S3_SECRET_ACCESS_KEY` | none | if any `S3_*` is set | **Secret** | Secret key. |
| `S3_REGION` | `us-east-1` | no | ConfigMap | Region. |
| `S3_USE_PATH_STYLE` | `true` | no | ConfigMap | `false` for AWS S3. |

## Frontend build settings

Read when the frontend image is **built**:

| Build argument | Default | What it does |
| --- | --- | --- |
| `VITE_AUTH_MODE` | `dev` | `oidc` for real sign-in. |
| `VITE_OIDC_AUTHORITY` | empty | Must equal `OIDC_ISSUER_URL`. |
| `VITE_OIDC_CLIENT_ID` | empty | `hr-spa`. |
| `VITE_OIDC_SCOPE` | `openid profile email` | Scopes. |
| `VITE_DEV_USER` | `dev-hr-admin` | User the app sends in `dev` mode. |
| `HR_VERSION` | `dev` | Version shown in the app. |
| `NGINX_CONF` | `nginx.conf` | `nginx.conf` (upstream `backend:8080`) or `nginx.stack.conf` (`hr-backend:8080`). The Helm chart mounts its own. |
| `VITE_API_BASE_URL` | empty | Not a build argument: read by the local dev server (`npm run dev`) only. |

```sh
docker build -f infra/Dockerfile.frontend \
  --build-arg VITE_AUTH_MODE=oidc \
  --build-arg VITE_OIDC_AUTHORITY=https://auth.example.org/realms/conservices \
  --build-arg VITE_OIDC_CLIENT_ID=hr-spa \
  -t registry.example.org/hr-frontend:1.0.0-1 .
```
