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
| Secret `learn-secrets` (`existingSecret`, from your secret manager) | `DATABASE_URL`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `KEYCLOAK_CLIENT_SECRET`, `LEARN_SERVICE_TOKEN`, `LEARN_FEEDBACK_PEPPER`, `SMTP_PASSWORD`, `TELEGRAM_BOT_TOKEN`. See [Secrets](../../operations/secrets.md). |
| ConfigMap `learn-access-config` | The access config file. |
| Secrets `learn-backend-tls`, `learn-frontend-tls` (from cert-manager) | The pods' internal TLS certificates (`tls.crt`, `tls.key`, `ca.crt`), mounted at `/etc/conservices-tls`. See [Internal TLS](#internal-tls). |
| ConfigMap `conservices-internal-ca` (from trust-manager) | The platform's internal CA (`ca.crt`), mounted at `/etc/conservices-internal-ca`. |

## Backend

### Core, sign-in and Den

| Variable | Default | Required | Secret | What it does |
| --- | --- | --- | --- | --- |
| `APP_ENV` | `development` | no | no | `production` on real installations. Anything but `development` turns on the secret checks: `LEARN_FEEDBACK_PEPPER` is required, and it and `LEARN_SERVICE_TOKEN` must look like real secrets. |
| `APP_BASE_URL` | `http://localhost:8080` | no | no | Public address. |
| `HTTP_ADDR` | `:8080` | no | no | Listen address inside the container. |
| `DATABASE_URL` | none | **yes** | **yes** | PostgreSQL URL. Also read by the migrate step. On the platform it ends in `?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt`, because the platform's PostgreSQL accepts only TLS connections. |
| `SHUTDOWN_TIMEOUT` | `15s` | no | no | How long a stopping backend waits for requests. |
| `CORS_ALLOWED_ORIGINS` | `http://localhost:3005` | no | no | Comma-separated browser origins. **Include Den's address**, because Den's web app calls Learn. |
| `TRUSTED_PROXY_CIDRS` | `10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,127.0.0.0/8,::1/128,fc00::/7` | no | no | Comma-separated CIDRs of the proxies in front of the API (Gateway, nginx, Caddy). `X-Forwarded-For` is only believed on connections from these addresses; the resulting client IP is what rate limits count. Add a proxy that sits outside the private ranges; `none` trusts no proxy. See [Client IP addresses](../../operations/production.md#client-ip-addresses). |
| `PUBLIC_BASE_URL` | none | recommended | no | Browser-facing Learn address used in emails, certificates, QR codes and portal to-do links. |
| `AUTH_MODE` | `dev` | no | no | `oidc` for real sign-in; `dev` trusts `X-Dev-User`/`X-Dev-Groups` headers (local only). |
| `OIDC_ISSUER_URL` | none | with `oidc` | no | Issuer URL. |
| `OIDC_CLIENT_ID` | none | with `oidc` | no | `learn-spa`. |
| `OIDC_AUDIENCE` | none | no | no | Normally `learn-spa`. |
| `OIDC_EXTRA_AUDIENCES` | none | no | no | Comma-separated extra token audiences accepted, for example `den-spa` so Den's web app can show Learn to-dos. |
| `ACCESS_CONFIG_PATH` | none | in production | no | Path of the [access config file](#access-config-file). |
| `DEV_DEFAULT_USER` | `dev-admin` | no | no | `dev` mode only. |
| `DEV_DEFAULT_GROUPS` | `learn-admin` | no | no | `dev` mode only. |
| `DEN_INTERNAL_URL` | none | no | no | Den's in-cluster address for pairing (platform: `https://den-backend.conservices-den.svc.cluster.local:8080`). |
| `DEN_MODE` | `standalone` | no | no | `required`: until the module is paired with Den, its API answers `503 den_pairing_required` and the web app shows *Waiting for Den* (admins: *Connect this module to Den*). `standalone`: the module works without Den; pairing is optional. Kubernetes sets `required` (Helm: `den.mode`); Docker Compose sets `standalone`. See [Required or standalone](../../concepts/pairing.md#required-or-standalone). |
| `BRAND_LOCAL_PATH` | none | no | no | Optional `brand.json` while not paired. |

### Storage

| Variable | Default | Required | Secret | What it does |
| --- | --- | --- | --- | --- |
| `S3_ENDPOINT` | none | no | no | S3 address for course media, on the platform `https://s3.conservices-data.svc.cluster.local:9000`. **Empty turns uploads off** (`503`). |
| `S3_BUCKET` | `learn-data-dev` | no | no | Media bucket. Add it to the Den operator's `FILES_S3_BUCKETS`. |
| `S3_ACCESS_KEY_ID` | none | with S3 | **yes** | Key for the bucket. |
| `S3_SECRET_ACCESS_KEY` | none | with S3 | **yes** | Secret for the key. |
| `S3_REGION` | `us-east-1` | no | no | Region. |
| `S3_USE_PATH_STYLE` | `true` | no | no | `true` for the local S3 server (SeaweedFS) and most self-hosted S3. |
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
| `KEYCLOAK_BASE_URL` | none | for group sync | no | Keycloak address for read-only admin API calls, on the platform `https://keycloak.conservices-identity.svc.cluster.local:8443`. Group sync runs only when all four `KEYCLOAK_*` are set and `GROUP_DIRECTORY` is `keycloak`. |
| `KEYCLOAK_REALM` | none | for group sync | no | `conservices`. |
| `KEYCLOAK_CLIENT_ID` | none | for group sync | no | `learn-provisioner`. |
| `KEYCLOAK_CLIENT_SECRET` | none | for group sync | **yes** | That client's secret. Regenerate the public development value before production. |
| `GROUP_DIRECTORY` | `keycloak` | no | no | Where Learn reads groups and people from. `keycloak`: the Keycloak Admin API above (group picker, group sync, people who never signed in). `off`: never, whatever `KEYCLOAK_*` says; use it with an identity provider that has no such API. With `off`, group links only match the groups people sign in with, and the group-link panels show a warning. The suite's install template sets it from the identity mode. Any other value stops the backend. |
| `LEARN_LINKABLE_GROUPS` | `/learn/*` | no | no | Comma-separated full group paths trainers may see and link to courses. `/learn/*` is every group below `/learn` (not `/learn` itself), `/teams/red` exactly that group, `*` every group. Holders of `course.manage` may link any group. Case and the leading `/` don't matter. |
| `LEARN_SERVICE_TOKEN` | none | for HR | **yes** | Bearer token HR uses for `GET /api/internal/holdings`. **Empty turns that endpoint off** (`404`). Same value on HR. Outside `APP_ENV=development` the backend refuses to start when it is shorter than 32 characters, has fewer than 10 different characters or contains a placeholder such as `dev-token` or `change-me`; generate one with `openssl rand -hex 32`. |
| `LEARN_FEEDBACK_PEPPER` | dev-only value in `development`, else none | **yes**, outside development | **yes** | Secret key of the hash that stops a person giving anonymous feedback twice without storing who they are. Same strength rules as `LEARN_SERVICE_TOKEN`. Changing it lets everyone give anonymous feedback on each course once more. |
| `TELEGRAM_BOT_TOKEN` | none | no | **yes** | Bot token from @BotFather. Turns Telegram reminders on; admins switch delivery off and on in **Settings** without removing it. Empty turns Telegram off. On Kubernetes the backend needs egress to `api.telegram.org` (Helm: `networkPolicy.telegram`). |
| `TELEGRAM_API_URL` | `https://api.telegram.org` | no | no | Bot API origin. Change it only for an outbound proxy or a test server. |

### Internal TLS

On Kubernetes, Learn's backend serves HTTPS inside the cluster and checks
the certificates of the services it calls
([Internal TLS](../../operations/internal-tls.md)). The Helm chart sets
these three variables itself while `internalTLS.enabled` is `true` (the
default), so you normally do not add them to `config:`; the chart values
are listed in [Setup](setup.md#internal-tls). In Docker Compose
development all three stay empty and the backend serves plain HTTP.

| Variable | Default | Required | Secret | What it does |
| --- | --- | --- | --- | --- |
| `TLS_CERT_FILE` | none | no | no | Path to the PEM certificate the backend serves HTTPS with; on Kubernetes `/etc/conservices-tls/tls.crt` (set by the chart). Set it together with `TLS_KEY_FILE`: setting only one stops the backend with `tls: TLS_CERT_FILE and TLS_KEY_FILE must be set together`. Both empty means plain HTTP. The backend re-reads the file every minute, so a certificate renewed by cert-manager is used without a restart. |
| `TLS_KEY_FILE` | none | no | no | Path to the matching PEM private key; on Kubernetes `/etc/conservices-tls/tls.key` (set by the chart). |
| `SSL_CERT_DIR` | none (system CAs only) | on Kubernetes | no | Standard Go setting: folders of extra CA certificates the backend trusts when it calls PostgreSQL, S3, Keycloak, Den and the identity provider. Separate several folders with `:`. On Kubernetes `/etc/conservices-internal-ca` (the platform's internal CA, set by the chart); the local example overlay uses `/etc/conservices-internal-ca:/etc/conservices-ca` to trust mkcert's root as well. Without it, calls fail with `x509: certificate signed by unknown authority`. |

With TLS on, the backend logs `tls enabled` at start, with the
certificate's expiry date in `not_after`. If a later re-read fails, it logs
`tls certificate reload failed; keeping the current one` and keeps serving
the old certificate. The minimum protocol version is TLS 1.2.

## Web app settings (config.json)

The `learn-frontend` image names no domain, so one published image works for
every installation. When the web app starts in the browser it first loads
`/config.json` from its own address, before it shows anything or contacts
Keycloak. nginx serves that file from `/etc/conservices/config.json`, which
you mount into the container (a ConfigMap on Kubernetes, a file with Docker
Compose). nginx sends it with `Cache-Control: no-store`, so a change shows
up on the next page load without rebuilding or restarting anything.

| Key | Default | What it does |
| --- | --- | --- |
| `authMode` | `"oidc"` | `"oidc"` signs people in through Keycloak. `"dev"` skips sign-in and only works against a backend that also runs with `AUTH_MODE=dev`; never use it on a reachable installation. |
| `oidcAuthority` | `""` | The issuer URL (realm address), for example `https://auth.example.org/realms/conservices`. Must equal the backend's `OIDC_ISSUER_URL`. Required with `"oidc"`. |
| `oidcClientId` | `""` | The public client the web app signs in with: `learn-spa`. Required with `"oidc"`. |
| `oidcScope` | `"openid profile email"` | Scopes requested at sign-in. |
| `apiBaseUrl` | `""` | Address put in front of every API call (`/api/...`). Leave empty: nginx serves the app and forwards `/api/` on the same address. Only set it when the API lives on another origin, for example `https://api.example.org`. |
| `productName` | `""` (shows `Learn`) | Name shown until Den's brand has loaded. |
| `monitorSession` | `true` | Watches the sign-in session at the identity provider in a hidden frame and signs the web app out when it ends there (OIDC session management). Set `false` for an identity provider without `check_session_iframe`, or when browsers block its third-party cookies and people are signed out at random. Must be `true` or `false`, not a string. |

Keys you leave out keep their default; unknown keys are ignored. The image
ships a placeholder file with empty `oidcAuthority` and `oidcClientId`: the
web app then shows **Not configured yet** instead of a sign-in page.

Example for `learn.example.org`:

```json
{
  "authMode": "oidc",
  "oidcAuthority": "https://auth.example.org/realms/conservices",
  "oidcClientId": "learn-spa",
  "oidcScope": "openid profile email",
  "apiBaseUrl": "",
  "productName": "Learn"
}
```

### How to set it

1. **Helm:** set `frontend.config` in your values. Keys you leave out are
   filled in from the chart's other values: `authMode` from `config.AUTH_MODE`, `oidcAuthority` from `config.OIDC_ISSUER_URL`, `oidcClientId` from `config.OIDC_CLIENT_ID` (else `learn-spa`), `productName` `Learn`,
   `oidcScope` `openid profile email` and `apiBaseUrl` empty. So with the
   usual `config.OIDC_ISSUER_URL` you often need nothing extra. The chart
   writes the file to the ConfigMap `<release>-frontend-config` and restarts
   the web app pods when it changes.

   ```yaml
   frontend:
     config:
       oidcAuthority: https://auth.example.org/realms/conservices
       oidcClientId: learn-spa
   ```

2. **Docker Compose:** the module's `infra/docker-compose.yml` mounts
   `infra/frontend-config/compose.json` (dev sign-in). For real sign-in, copy
   it, fill in the keys and set `FRONTEND_CONFIG` (a path relative to
   `infra/`) in `.env`. The full platform stack (root `docker-compose.yml`)
   mounts `infra/frontend-config/learn.json`.
3. **Plain Docker:** mount the file read-only:

   ```sh
   docker run --rm -p 3000:8080 \
     -v "$PWD/config.json:/etc/conservices/config.json:ro" \
     ghcr.io/aglelectronics/learn-frontend:1.0.0-1
   ```

Check what the browser gets:

```sh
curl -i https://learn.example.org/config.json
```

```text
HTTP/2 200
content-type: application/json
cache-control: no-store

{
  "authMode": "oidc",
  "oidcAuthority": "https://auth.example.org/realms/conservices",
  "oidcClientId": "learn-spa",
  ...
}
```

### Troubleshooting

- **"Not configured yet"**: `oidcAuthority` or `oidcClientId` is empty, so
  the image's placeholder file is served. Check that the file is mounted at
  `/etc/conservices/config.json` (Helm: `kubectl get configmap
  <release>-frontend-config -o yaml`).
- **"Invalid settings in /config.json"**: the file is not valid JSON, or a key
  has the wrong type (for example `"publicClaimEnabled": "yes"` instead of
  `true`). The message names the key.
- **"Could not load the settings"**: the browser could not reach
  `/config.json` at all, usually because the network dropped. Reload.
- **Sign-in fails with "invalid redirect_uri" or "client not found"**:
  `oidcClientId` does not exist in the realm `oidcAuthority` points at.
- **An old value still shows**: something in front of nginx caches the file.
  Make your proxy or CDN respect `Cache-Control: no-store` for
  `/config.json`.

## Frontend build settings

Docker build arguments of `infra/Dockerfile.frontend`. None of them is
installation-specific; the sign-in settings live in `/config.json` (above).

| Build argument | Default | What it does |
| --- | --- | --- |
| `LEARN_VERSION` | `dev` | Version shown in the app. |
| `NGINX_CONF` | `nginx.conf` | Which file from `infra/` becomes the image's nginx config. The Helm chart (and the Kustomize manifests) mount their own. |

```sh
docker build -f infra/Dockerfile.frontend \
  --build-arg LEARN_VERSION=1.0.0 \
  -t registry.example.org/conservices/learn-frontend:1.0.0-1 .
```

The local dev server (`npm run dev`) has no `/config.json`; it uses
`VITE_AUTH_MODE`, `VITE_OIDC_AUTHORITY`, `VITE_OIDC_CLIENT_ID`, `VITE_OIDC_SCOPE`, `VITE_API_BASE_URL` (for example `http://localhost:8120`), `VITE_PRODUCT_NAME` and `VITE_OIDC_MONITOR_SESSION` (`false` turns session monitoring off) from the environment or `.env` instead. Image builds
ignore these.


## Access config file

The access config (`infra/access-config.toml`, mounted from the ConfigMap
`learn-access-config`) maps Keycloak groups to roles. The shipped file:

| Keycloak group | Role | Permissions |
| --- | --- | --- |
| `learn-admin` | `organization_admin` | every permission below |
| `learn-trainer` | `trainer` | `course.teach`, `enrol.manage` |
| `learn-manager` | `training_manager` | `staff.manage` |
| `learn-coordinator` | `coordinator` | `report.view`, `qualification.manage` |

| Permission | Allows |
| --- | --- |
| `course.manage` | Every course: edit, publish, archive, enrol, reset quizzes, link any group. Sees email addresses. |
| `course.teach` | Create courses; edit and run the courses you staff (where you are a trainer). |
| `enrol.manage` | Add and remove **learners** on courses you may edit. Never trainers. |
| `staff.manage` | Add and remove **trainers** on every course (the **Course roles** page). The last trainer of a course always stays. Sees email addresses. |
| `qualification.manage` | Create, edit and delete qualifications, see every certificate, revoke certificates (the **Qualifications** page). |
| `report.view` | Completion and qualification reports for all courses. |
| `settings.manage` | Module settings (Den connection, Telegram, retention, erasure), the audit log, running reminders by hand. |

Reading a published course needs an **enrolment**, not a role. The
top-level `organization` in the file is everyone's home organization: the
people picker only finds people of the caller's organizations.

## Module settings (in the app)

Some settings are changed by admins in **Settings** and stored in Learn's
database, not in environment variables (`GET|PUT /api/v1/settings`, see the
[API reference](api.md#module-settings)):

| Setting | Default | What it does |
| --- | --- | --- |
| Telegram on/off | on | Off stops Telegram delivery while keeping `TELEGRAM_BOT_TOKEN`. Has no effect without the token. |
| Anonymise people inactive for (months) | `36` | People who have neither signed in nor been in a synced group for this long are anonymised; `0` never. |
| Delete audit entries after (months) | `24` | `0` never. |

The retention defaults are **pending legal review**: check them against
your organisation's retention duties. While Learn is paired with Den, Den's
module settings for Learn decide retention (Den sends
`settings.data.retention` with `inactive_user_months` and
`audit_log_months`) and the fields are read-only in Learn.
