# Tasks configuration reference

Tasks is configured through **environment variables**. The backend and the
migrate step read a `.env` file in their working directory if one exists,
then the real environment (which wins). The repository's
[`.env.example`](https://github.com/AGlElectronics/tasks/blob/main/.env.example)
lists them for local development. An empty value counts as not set. The
backend checks its settings at start and refuses to start with a list of
every problem.

## Where the settings live on Kubernetes

| Kubernetes object | Holds |
| --- | --- |
| ConfigMap `<release>-config` (from `values.yaml` `config:`) | Every setting below that is not a secret. The chart adds `ACCESS_CONFIG_PATH`. |
| Secret `tasks-secrets` (`existingSecret`, from your secret manager) | `DATABASE_URL`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `TASKS_SERVICE_TOKEN`. |
| ConfigMap `tasks-access-config` | The access config file. |

After changing the Secret: `kubectl rollout restart -n conservices-tasks deploy/tasks-backend`.

## Backend

| Variable | Default | Required | Secret | What it does |
| --- | --- | --- | --- | --- |
| `APP_ENV` | `development` | no | no | `production` on real installations. |
| `APP_BASE_URL` | `http://localhost:8080` | no | no | Public address, for example `https://tasks.example.org`. |
| `HTTP_ADDR` | `:8080` | no | no | Listen address inside the container. Keep `:8080`. |
| `DATABASE_URL` | none | **yes** | **yes** | PostgreSQL URL, for example `postgres://tasks:change-me@db.example.org:5432/tasks?sslmode=require`. Also read by the migrate step. |
| `SHUTDOWN_TIMEOUT` | `15s` | no | no | How long a stopping backend waits for requests to finish. |
| `CORS_ALLOWED_ORIGINS` | `http://localhost:3009` | no | no | Comma-separated browser origins allowed to call the API. |
| `AUTH_MODE` | `dev` | no | no | `oidc` for real sign-in. `dev` trusts `X-Dev-User`/`X-Dev-Groups` headers: **local development only**. |
| `OIDC_ISSUER_URL` | none | with `oidc` | no | Issuer, for example `https://auth.example.org/realms/conservices`. |
| `OIDC_CLIENT_ID` | none | with `oidc` | no | `tasks-spa`. |
| `OIDC_AUDIENCE` | none | no | no | Expected token audience, normally `tasks-spa`. |
| `ACCESS_CONFIG_PATH` | none | in production | no | Path of the [access config file](#access-config-file). Without it the built-in catalog is used. |
| `DEV_DEFAULT_USER` | `dev-admin` | no | no | `dev` mode only: user when no header is sent. |
| `DEV_DEFAULT_GROUPS` | `tasks-admin` | no | no | `dev` mode only: groups when no header is sent. |
| `DEN_INTERNAL_URL` | none | no | no | Den's in-cluster address, for example `http://den-backend.conservices-den.svc.cluster.local:8080`; replaces the host of pasted pairing URLs. Empty without Den. |
| `BRAND_LOCAL_PATH` | none | no | no | Optional `brand.json` while not paired. |
| `TASKS_SERVICE_TOKEN` | none | for HR | **yes** | Bearer token HR uses for `POST /api/internal/departments`. **Empty turns the endpoint off** (`404`). Must equal the token in HR's `DEPARTMENT_HOOKS`. Generate with `openssl rand -hex 32`. |
| `S3_ENDPOINT` | none | no | no | S3 address for attachments. **Empty turns attachments off** (`503`). |
| `S3_BUCKET` | `tasks-data-dev` | no | no | Bucket for attachments. Add it to the Den operator's `FILES_S3_BUCKETS`. |
| `S3_ACCESS_KEY_ID` | none | with S3 | **yes** | Key for the bucket. |
| `S3_SECRET_ACCESS_KEY` | none | with S3 | **yes** | Secret for the key. |
| `S3_REGION` | `us-east-1` | no | no | Region of the bucket. |
| `S3_USE_PATH_STYLE` | `true` | no | no | `true` for MinIO and most self-hosted S3. |

## Frontend build settings

Compiled into the `tasks-frontend` image at **build** time:

| Build argument | Default | What it does |
| --- | --- | --- |
| `VITE_AUTH_MODE` | `dev` | `oidc` for real sign-in. |
| `VITE_OIDC_AUTHORITY` | none | Issuer URL. |
| `VITE_OIDC_CLIENT_ID` | none | `tasks-spa`. |
| `VITE_OIDC_SCOPE` | `openid profile email` | Scopes. |
| `VITE_API_BASE_URL` | empty | Leave empty behind nginx. |
| `VITE_PRODUCT_NAME` | `Tasks` | Name shown before Den's brand loads. |
| `NGINX_CONF` | `nginx.conf` | nginx config baked into the image (the Helm chart replaces it). |

```sh
cd tasks
docker build -f infra/Dockerfile.frontend \
  --build-arg VITE_AUTH_MODE=oidc \
  --build-arg VITE_OIDC_AUTHORITY=https://auth.example.org/realms/conservices \
  --build-arg VITE_OIDC_CLIENT_ID=tasks-spa \
  -t registry.example.org/conservices/tasks-frontend:1.0.0-1 .
```

## Access config file

Read once at start (restart after editing). Roles and their permissions:

| Keycloak group | Role | Permissions |
| --- | --- | --- |
| `tasks-admin` | `organization_admin` | `space.manage` (every space), `space.create`, `settings.manage` (Den connection) |
| `tasks-creator` | `space_creator` | `space.create` (new spaces, and manage the ones you created) |

Working on tasks is not a role: it comes from sharing spaces and lists
inside Tasks. See the [Admin guide](admin-guide.md#sharing).
