# Learn configuration reference

Learn is configured through **environment variables**. The backend and the
migrate step read a `.env` file in their working directory if one exists,
then the real environment (which wins). The repository's
[`.env.example`](https://github.com/AGlElectronics/learn/blob/main/.env.example)
lists them for local development. An empty value counts as not set. The
backend checks its settings at start and refuses to start with a list of
every problem.

## Where the settings live on Kubernetes

| Kubernetes object | Holds |
| --- | --- |
| ConfigMap `<release>-config` (from `values.yaml` `config:`) | Every setting below that is not a secret. The chart adds `ACCESS_CONFIG_PATH`. |
| Secret `learn-secrets` (`existingSecret`, from your secret manager) | `DATABASE_URL`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `KEYCLOAK_CLIENT_SECRET`, `LEARN_SERVICE_TOKEN`, `SMTP_PASSWORD`, `TELEGRAM_BOT_TOKEN`. |
| ConfigMap `learn-access-config` | The access config file. |

## Backend

### Core, sign-in and Den

| Variable | Default | Required | Secret | What it does |
| --- | --- | --- | --- | --- |
| `APP_ENV` | `development` | no | no | `production` on real installations. |
| `APP_BASE_URL` | `http://localhost:8080` | no | no | Public address. |
| `HTTP_ADDR` | `:8080` | no | no | Listen address inside the container. |
| `DATABASE_URL` | none | **yes** | **yes** | PostgreSQL URL. Also read by the migrate step. |
| `SHUTDOWN_TIMEOUT` | `15s` | no | no | How long a stopping backend waits for requests. |
| `CORS_ALLOWED_ORIGINS` | `http://localhost:3005` | no | no | Comma-separated browser origins. **Include Den's address**, because Den's web app calls Learn. |
| `PUBLIC_BASE_URL` | none | recommended | no | Browser-facing Learn address used in emails, certificates, QR codes and portal to-do links. |
| `AUTH_MODE` | `dev` | no | no | `oidc` for real sign-in; `dev` trusts `X-Dev-User`/`X-Dev-Groups` headers (local only). |
| `OIDC_ISSUER_URL` | none | with `oidc` | no | Issuer URL. |
| `OIDC_CLIENT_ID` | none | with `oidc` | no | `learn-spa`. |
| `OIDC_AUDIENCE` | none | no | no | Normally `learn-spa`. |
| `OIDC_EXTRA_AUDIENCES` | none | no | no | Comma-separated extra token audiences accepted, for example `den-spa` so Den's web app can show Learn to-dos. |
| `ACCESS_CONFIG_PATH` | none | in production | no | Path of the [access config file](#access-config-file). |
| `DEV_DEFAULT_USER` | `dev-admin` | no | no | `dev` mode only. |
| `DEV_DEFAULT_GROUPS` | `learn-admin` | no | no | `dev` mode only. |
| `DEN_INTERNAL_URL` | none | no | no | Den's in-cluster address for pairing. |
| `BRAND_LOCAL_PATH` | none | no | no | Optional `brand.json` while not paired. |

### Storage

| Variable | Default | Required | Secret | What it does |
| --- | --- | --- | --- | --- |
| `S3_ENDPOINT` | none | no | no | S3 address for course media. **Empty turns uploads off** (`503`). |
| `S3_BUCKET` | `learn-data-dev` | no | no | Media bucket. Add it to the Den operator's `FILES_S3_BUCKETS`. |
| `S3_ACCESS_KEY_ID` | none | with S3 | **yes** | Key for the bucket. |
| `S3_SECRET_ACCESS_KEY` | none | with S3 | **yes** | Secret for the key. |
| `S3_REGION` | `us-east-1` | no | no | Region. |
| `S3_USE_PATH_STYLE` | `true` | no | no | `true` for MinIO and most self-hosted S3. |
| `S3_PUBLIC_BASE_URL` | none | no | no | Rewrites presigned media links to an address browsers can reach, for example `https://s3.example.org` when the backend uses an in-cluster address. |

### Email, Keycloak and integrations

| Variable | Default | Required | Secret | What it does |
| --- | --- | --- | --- | --- |
| `SMTP_HOST` | none | no | no | SMTP server for reminders and notices. **Empty turns email off.** |
| `SMTP_PORT` | `587` | no | no | SMTP port. |
| `SMTP_USERNAME` | none | no | no | SMTP login. |
| `SMTP_PASSWORD` | none | no | **yes** | SMTP password. |
| `SMTP_FROM` | none | with SMTP | no | Sender address, for example `no-reply@example.org`. |
| `SMTP_FROM_NAME` | none | no | no | Sender name, for example `Con Services`. |
| `KEYCLOAK_BASE_URL` | none | for group sync | no | Keycloak address for read-only admin API calls, for example `http://keycloak.conservices-identity.svc.cluster.local:8080`. Group sync runs only when all four `KEYCLOAK_*` are set. |
| `KEYCLOAK_REALM` | none | for group sync | no | `conservices`. |
| `KEYCLOAK_CLIENT_ID` | none | for group sync | no | `learn-provisioner`. |
| `KEYCLOAK_CLIENT_SECRET` | none | for group sync | **yes** | That client's secret. Regenerate the public development value before production. |
| `LEARN_SERVICE_TOKEN` | none | for HR | **yes** | Bearer token HR uses for `GET /api/internal/holdings`. **Empty turns that endpoint off** (`404`). Same value on HR. |
| `TELEGRAM_BOT_TOKEN` | none | no | **yes** | Telegram notifications (a stub so far). Empty turns them off. |

## Frontend build settings

Compiled into the `learn-frontend` image at **build** time:

| Build argument | Default | What it does |
| --- | --- | --- |
| `VITE_AUTH_MODE` | `dev` | `oidc` for real sign-in. |
| `VITE_OIDC_AUTHORITY` | none | Issuer URL. |
| `VITE_OIDC_CLIENT_ID` | none | `learn-spa`. |
| `VITE_OIDC_SCOPE` | `openid profile email` | Scopes. |
| `VITE_API_BASE_URL` | empty | Leave empty behind nginx. |
| `VITE_PRODUCT_NAME` | `Learn` | Name shown before Den's brand loads. |
| `NGINX_CONF` | `nginx.conf` | nginx config baked into the image (the Helm chart replaces it). |

## Access config file

| Keycloak group | Role | Permissions |
| --- | --- | --- |
| `learn-admin` | `organization_admin` | `course.manage`, `enrol.manage`, `settings.manage`, `report.view` |
| `learn-trainer` | `trainer` | `course.teach`, `enrol.manage` |
| `learn-coordinator` | `coordinator` | `report.view` |

| Permission | Allows |
| --- | --- |
| `course.manage` | Every course. |
| `course.teach` | Create courses; edit and run the courses you staff. |
| `enrol.manage` | Enrol people. |
| `report.view` | Completion and qualification reports for all courses. |
| `settings.manage` | The Den connection; running reminders by hand. |

Reading a published course needs an **enrolment**, not a role.
