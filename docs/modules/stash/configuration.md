# Stash configuration

Stash's backend reads all of its settings from **environment variables**
when it starts (a `.env` file in the working directory is read too, for
local development). Change a value, then restart the backend. On startup it
checks the required ones and exits with one message listing everything
missing, for example:

```text
invalid config: DATABASE_URL is required; S3_BUCKET is required
```

The source of truth is
[`backend/internal/config/config.go`](https://github.com/AGlElectronics/stash/blob/main/backend/internal/config/config.go);
the example file is [`.env.example`](https://github.com/AGlElectronics/stash/blob/main/.env.example).

**Where each value goes on Kubernetes.** *Secret* means the value belongs
in your secret manager and reaches the pod through the `stash-secrets`
Secret ([Secrets](../../operations/secrets.md)). *ConfigMap* means it is
plain configuration (`config:` in the Helm values, or the `stash-config`
ConfigMap in the Kustomize manifests).

## Core

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `APP_ENV` | `development` | no | ConfigMap | `development` turns on human-readable console logs; use `production` everywhere else (JSON logs). |
| `APP_BASE_URL` | `http://localhost:8080` | no | ConfigMap | Public address of Stash, for example `https://stash.example.org`. |
| `HTTP_ADDR` | `:8080` | no | ConfigMap | Address the API listens on inside the container. Keep `:8080`; the manifests and nginx configs expect it. |
| `DATABASE_URL` | none | **yes** | **Secret** | PostgreSQL connection URL, for example `postgres://stash:change-me@db:5432/stash?sslmode=require`. On the platform, Den shows it once when it creates the database. |
| `CORS_ALLOWED_ORIGINS` | `http://localhost:3000` | no | ConfigMap | Comma-separated origins allowed to call the API from a browser. Set it to Stash's own address. |
| `SHUTDOWN_TIMEOUT` | `15s` | no | ConfigMap | How long running requests may finish when the backend stops (Go duration). |

## Object storage

Stash stores photos and attachments in one S3-compatible bucket. It creates
the bucket on first start if it does not exist and the keys allow it.

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `S3_ENDPOINT` | none | **yes** | ConfigMap | S3 API address, for example `https://s3.eu-central-1.amazonaws.com` or `http://minio.conservices-data.svc.cluster.local:9000`. |
| `S3_BUCKET` | none | **yes** | ConfigMap | Bucket name. Platform: `stash-data`. |
| `S3_ACCESS_KEY_ID` | none | **yes** | **Secret** | Access key, ideally limited to this bucket. |
| `S3_SECRET_ACCESS_KEY` | none | **yes** | **Secret** | Secret key for it. |
| `S3_REGION` | `us-east-1` | no | ConfigMap | Bucket region. |
| `S3_USE_PATH_STYLE` | `true` | no | ConfigMap | `true` for MinIO and most self-hosted endpoints, `false` for AWS S3. |
| `S3_PUBLIC_BASE_URL` | none | no | ConfigMap | Replaces scheme and host in presigned download and upload links so browsers can reach them. Without it, a host containing `minio` is rewritten to `localhost` (local development). |

## Sign-in and access

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `AUTH_MODE` | `dev` | no | ConfigMap | `oidc` verifies bearer tokens from your identity provider. `dev` trusts an `X-Dev-User` header and must never be used outside local development. |
| `OIDC_ISSUER_URL` | none | with `oidc` | ConfigMap | Issuer of staff tokens, for example `https://auth.example.org/realms/conservices`. Must match the tokens' `iss` exactly. |
| `OIDC_CLIENT_ID` | none | with `oidc` | ConfigMap | Keycloak client of the web app (`stash-spa` on the platform). |
| `OIDC_AUDIENCE` | none | no | ConfigMap | Expected token audience if it differs from the client id. |
| `ACCESS_CONFIG_PATH` | none | with `oidc` | ConfigMap | Path to the access config TOML file (roles, permissions, group bindings), for example `/etc/stash/access-config.toml`. The file itself is mounted from a ConfigMap. See [Admin guide](admin-guide.md#who-can-do-what). |
| `OIDC_BINDINGS_PATH` | none | no | ConfigMap | Old name of `ACCESS_CONFIG_PATH`, still read when the new name is not set. |
| `DEV_DEFAULT_USER` | `dev-admin` | no | ConfigMap | User assumed in `dev` mode when no `X-Dev-User` header is sent. |

## Den and guest features

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `DEN_INTERNAL_URL` | none | no | ConfigMap | Replaces scheme and host of a pasted Den pairing URL, for when the backend reaches Den at a different address than browsers (platform: `http://den-backend.conservices-den.svc.cluster.local:8080`). Empty for standalone installs. |
| `PUBLIC_LOSTFOUND_CLAIM_ENABLED` | `false` | no | ConfigMap | Turns on the guest Lost & Found lookup (`/api/public/lostfound`, no sign-in). Leave off until guest kiosks are ready. Pair with `VITE_PUBLIC_CLAIM_ENABLED` on the frontend build. |

## Other variables

| Name | Where | What it does |
| --- | --- | --- |
| `SSL_CERT_DIR` | ConfigMap or pod env | Standard Go setting: directory of extra CA certificates, needed when the identity provider uses a private CA (local clusters). |
| `STASH_ACCESS_CONFIG` | `.env` for Compose only | Host path of the access config file mounted by `infra/docker-compose.local.yml`. Not read by Stash itself. |

## Frontend build settings

The web app reads these when the image is **built** (`docker build
--build-arg …`), not at run time. Rebuild after changing them.

| Build argument | Default | What it does |
| --- | --- | --- |
| `VITE_AUTH_MODE` | `dev` | `oidc` for real sign-in. The build fails if `oidc` is set without the next two. |
| `VITE_OIDC_AUTHORITY` | empty | Issuer URL; must equal the backend's `OIDC_ISSUER_URL`. |
| `VITE_OIDC_CLIENT_ID` | empty | Public client id, for example `stash-spa`. |
| `VITE_OIDC_SCOPE` | `openid profile email` | Requested scopes. |
| `VITE_PUBLIC_CLAIM_ENABLED` | `false` | Shows the guest claim page. |
| `STASH_VERSION` | `dev` | Version shown in the app. |
| `NGINX_CONF` | `nginx.conf` | Which file from `infra/` becomes the image's nginx config: `nginx.conf` (Compose, upstream `backend:8080`), `nginx.stack.conf` (root stack, `stash-backend:8080`), `nginx.k8s.conf` (Kubernetes). The Helm chart and Kustomize manifests mount their own config instead. |
| `VITE_API_BASE_URL` | empty | Only for the local dev server; leave empty when nginx serves the app and `/api` on one address. |

Example for your own domain:

```sh
docker build -f infra/Dockerfile.frontend \
  --build-arg VITE_AUTH_MODE=oidc \
  --build-arg VITE_OIDC_AUTHORITY=https://auth.example.org/realms/conservices \
  --build-arg VITE_OIDC_CLIENT_ID=stash-spa \
  --build-arg STASH_VERSION=1.0.0 \
  -t registry.example.org/stash-frontend:1.0.0-1 .
```

## Helm values

The chart in `deploy/charts/stash` maps its values onto the variables above:

| Value | Becomes |
| --- | --- |
| `config.*` | One entry each in the ConfigMap `<release>-config`. |
| `existingSecret` | Name of the Secret loaded with `envFrom` (`DATABASE_URL`, `S3_*` keys). |
| `accessConfig.existingConfigMap`, `mountPath`, `fileName` | The mounted access config and `ACCESS_CONFIG_PATH`. |
| `backend.extraEnv`, `extraVolumes`, `extraVolumeMounts` | Extra settings such as `SSL_CERT_DIR` with a CA volume. |
| `image.*.tag` | `MAJOR.MINOR.PATCH-BUILD`; required. |
