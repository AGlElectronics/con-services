# Rally configuration

Rally's backend reads its settings from **environment variables** when it
starts (plus a `.env` file in the working directory, for local
development). Restart after a change. Missing or inconsistent values stop
it with one message listing every problem:

```text
invalid config: DATABASE_URL is required; S3_ENDPOINT is required when S3_ENABLED=true
```

Source of truth:
[`backend/internal/config/config.go`](https://github.com/AGlElectronics/rally/blob/main/backend/internal/config/config.go).
Example file: [`.env.example`](https://github.com/AGlElectronics/rally/blob/main/.env.example).

**Where each value goes on Kubernetes:** *Secret* = your secret manager,
delivered as the `rally-secrets` Secret ([Secrets](../../operations/secrets.md));
*ConfigMap* = `config:` in the Helm values.

## Core

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `APP_ENV` | `development` | no | ConfigMap | `development` gives console logs; use `production` otherwise. |
| `APP_BASE_URL` | `http://localhost:8080` | no | ConfigMap | Rally's public staff address. |
| `HTTP_ADDR` | `:8080` | no | ConfigMap | Listen address inside the container. Keep `:8080`. |
| `DATABASE_URL` | none | **yes** | **Secret** | PostgreSQL URL. Also the only setting the `rally-migrate` image reads. |
| `CORS_ALLOWED_ORIGINS` | `http://localhost:3002` | no | ConfigMap | Comma-separated browser origins allowed to call the API. Include the submission site when it runs on its own host. |
| `SHUTDOWN_TIMEOUT` | `15s` | no | ConfigMap | Grace period for running requests on stop. |

## Object storage

Submission attachments live in S3. Browsers upload and download them
**directly** with short-lived signed links; the backend only signs and
checks.

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `S3_ENABLED` | `true` | no | ConfigMap | `false` skips storage (uploads then fail). Only for tests. |
| `S3_ENDPOINT` | none | while enabled | ConfigMap | S3 API address the backend uses, for example `http://minio.conservices-data.svc.cluster.local:9000`. |
| `S3_BUCKET` | none | while enabled | ConfigMap | Bucket, platform: `events-data`. Created on start if missing. |
| `S3_ACCESS_KEY_ID` | none | while enabled | **Secret** | Access key. |
| `S3_SECRET_ACCESS_KEY` | none | while enabled | **Secret** | Secret key. |
| `S3_REGION` | `us-east-1` | no | ConfigMap | Region. |
| `S3_USE_PATH_STYLE` | `true` | no | ConfigMap | `false` for AWS S3. |
| `S3_PUBLIC_BASE_URL` | none | when `S3_ENDPOINT` is internal | ConfigMap | Address **browsers** reach S3 at, for example `https://s3.example.org`. Rally rewrites signed links to it. |

## Sign-in

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `AUTH_MODE` | `dev` | no | ConfigMap | `oidc` verifies bearer tokens. `dev` trusts `X-Dev-User`: local only. |
| `OIDC_ISSUER_URL` | none | with `oidc` | ConfigMap | Staff issuer, for example `https://auth.example.org/realms/conservices`. |
| `OIDC_CLIENT_ID` | none | with `oidc` | ConfigMap | Staff web app client (`events-spa`). |
| `OIDC_AUDIENCE` | none | no | ConfigMap | Expected audience if different from the client id. |
| `ACCESS_CONFIG_PATH` | none | in production | ConfigMap | Path of `access-config.toml` (roles and group bindings). The chart sets `/etc/rally/access-config.toml`. A wrong path or unknown permission stops startup (`load access config: …`). Without it the built-in roles apply but no group grants anything. |
| `DEV_DEFAULT_USER` | `dev-admin` | no | ConfigMap | Name used in `dev` mode without an `X-Dev-User` header. |
| `ATTENDEE_OIDC_ISSUER_URL` | none | for attendee sign-in | ConfigMap | Issuer of the **attendee** realm, for example `https://auth.example.org/realms/attendees`. Must differ from `OIDC_ISSUER_URL`. Empty: the submission site only lists open calls. |
| `ATTENDEE_OIDC_CLIENT_ID` | none | with the issuer | ConfigMap | Submission site client (`rally-submit`). |

## Den and branding

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `DEN_INTERNAL_URL` | none | no | ConfigMap | Replaces the host of a pasted Den pairing URL (platform: `http://den-backend.conservices-den.svc.cluster.local:8080`). Empty when standalone. |
| `BRAND_LOCAL_PATH` | none | no | ConfigMap | Optional `brand.json` for standalone use; Den's brand replaces it once paired. |

## Public schedule

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `PUBLIC_SCHEDULE_ENABLED` | `false` | no | ConfigMap | Serves the published schedule under `/api/public/v1/schedules`. When paired and set, Den's `events_public_schedule` setting wins. |
| `PUBLIC_API_BUILTIN_KEY` | none | no | ConfigMap | The "programme-page" API key the submission site sends. Must equal the submit build's `VITE_PUBLIC_SCHEDULE_KEY`. It ships to every browser, so it is **not a secret**; changing it rotates the key, empty removes it. |

## Live-day announcements

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `TELEGRAM_BOT_TOKEN` | none | no | **Secret** | Bot token. Empty: sending an announcement is a recorded dry run. |
| `TELEGRAM_API_URL` | `https://api.telegram.org` | no | ConfigMap | Telegram API address (change only for testing). |

## Other

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `SSL_CERT_DIR` | system | no | ConfigMap | Extra CA certificates (the local stack points it at Caddy's CA so Rally trusts `auth.conservices.test`). |

## Migrations

The `rally-migrate` image runs `/migrate`, which reads `DATABASE_URL` (or
`-dsn`) and takes one command:

| Command | What it does |
| --- | --- |
| `up` (default) | Apply all pending migrations; logs `migrations applied`. |
| `status` | Show which migrations are applied. |
| `version` | Print the current version. |
| `down` | Roll back the latest migration. Development only; restore from backup instead. |

```sh
docker run --rm -e DATABASE_URL='postgres://events:change-me@db.example.org:5432/events' \
  ghcr.io/aglelectronics/rally-migrate:1.0.0-1 status
```

## Frontend build settings

Read when the web app image is **built**:

| Build argument | Default | What it does |
| --- | --- | --- |
| `RALLY_APP` | `staff` | `staff` builds the staff app, `submit` the public submission site. |
| `VITE_AUTH_MODE` | `dev` | `oidc` for real sign-in. The build fails when `oidc` is set without authority and client id. |
| `VITE_OIDC_AUTHORITY` | empty | Staff app: equal to `OIDC_ISSUER_URL`. Submission site: equal to `ATTENDEE_OIDC_ISSUER_URL`. |
| `VITE_OIDC_CLIENT_ID` | empty | `events-spa` or `rally-submit`. |
| `VITE_OIDC_SCOPE` | `openid profile email` | Scopes. |
| `VITE_PRODUCT_NAME` | `Rally` | Name shown in the app (for example `Event submissions` on the public site). |
| `VITE_PUBLIC_SCHEDULE_KEY` | empty | Submission site: the key its Programme page sends; equal to `PUBLIC_API_BUILTIN_KEY`. |
| `VITE_API_BASE_URL` | empty | Only for a frontend served from another origin; normally empty. |
| `RALLY_VERSION` | `dev` | Version shown in the app. |
| `NGINX_CONF` | `nginx.conf` | `nginx.conf` (upstream `backend:8080`), `nginx.stack.conf` (`events-backend:8080`) or `nginx.k8s.conf`. The Helm chart mounts its own. |

## Helm values

The chart [`deploy/charts/rally`](https://github.com/AGlElectronics/con-services/tree/main/deploy/charts/rally)
maps these settings as follows:

| Values key | Becomes |
| --- | --- |
| `config.*` | ConfigMap `<release>-config`, loaded into the backend with `envFrom`. Every non-secret variable above. |
| `existingSecret` (default `rally-secrets`) | Loaded with `envFrom`; must hold `DATABASE_URL` and the S3 keys, optionally `TELEGRAM_BOT_TOKEN`. The chart never creates it. |
| `accessConfig.existingConfigMap` (default `rally-access-config`) | Mounted at `accessConfig.mountPath` (`/etc/rally`); `ACCESS_CONFIG_PATH` is set to it. |
| `image.backend`, `image.migrate`, `image.frontend` | Images; `tag` is required. |
| `submit.enabled`, `submit.image`, `submit.host` | Optional submission site Deployment, Service and Ingress host. |
| `backend.extraEnv`, `extraVolumes`, `extraVolumeMounts`, `hostAliases` | Extra settings for special cases (CA bundles, local DNS). |
| `networkPolicy.*` | NetworkPolicies; see [Setup](setup.md). `extraEgress` for Telegram or a standalone database. |
