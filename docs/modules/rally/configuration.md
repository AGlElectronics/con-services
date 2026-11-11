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
| `APP_ENV` | `production` | no | ConfigMap | Only `development` relaxes the rules for local work: it allows `AUTH_MODE=dev`, an unencrypted Den credential and `http://` pairing URLs, and gives console logs. Anything else counts as production. Docker Compose sets `development` explicitly. |
| `APP_BASE_URL` | `http://localhost:8080` | no | ConfigMap | Rally's public staff address. |
| `HTTP_ADDR` | `:8080` | no | ConfigMap | Listen address inside the container. Keep `:8080`. |
| `DATABASE_URL` | none | **yes** | **Secret** | PostgreSQL URL. Also the only setting the `rally-migrate` image reads. On the platform it ends in `?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt`, because the platform's PostgreSQL accepts only TLS connections. |
| `CORS_ALLOWED_ORIGINS` | `http://localhost:3002` | no | ConfigMap | Comma-separated browser origins allowed to call the API. Include the submission site when it runs on its own host. |
| `TRUSTED_PROXY_CIDRS` | `10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,127.0.0.0/8,::1/128,fc00::/7` | no | ConfigMap | Comma-separated CIDRs of the proxies in front of the API (Gateway, nginx, Caddy). `X-Forwarded-For` is only believed on connections from these addresses; the resulting client IP is what rate limits count. Add a proxy that sits outside the private ranges; `none` trusts no proxy. See [Client IP addresses](../../operations/production.md#client-ip-addresses). |
| `SHUTDOWN_TIMEOUT` | `15s` | no | ConfigMap | Grace period for running requests on stop. |

## Rate limits

Rally limits how fast one client can call the submission site's API, so a
script cannot flood it with drafts, invitations or guesses at invite codes.
Limits are counted **per backend replica**, in memory: with two replicas a
client gets up to twice the rate. A client over its limit gets
`429 rate_limited` with a `Retry-After` header (see
[API reference](api.md#requests-responses-and-errors)).

A rate is written `N/s`, `N/m` or `N/h` (requests per second, minute or
hour); `off` switches the limiter off. The burst is how many requests a
client may make at once before the rate applies.

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `PUBLIC_RATE_LIMIT` | `120/m` | no | ConfigMap | Every request under `/api/public/v1` (open calls, the public schedule API, the submission site), per client IP. The client IP comes from `TRUSTED_PROXY_CIDRS`. |
| `PUBLIC_RATE_BURST` | `30` | no | ConfigMap | Burst for `PUBLIC_RATE_LIMIT`. |
| `SUBMISSION_RATE_LIMIT` | `20/m` | no | ConfigMap | Creating a submission (both APIs), submitting it, inviting or re-inviting a co-presenter, opening, accepting or declining an invite code, and starting an upload, per signed-in person (per client IP without one). Counted in addition to `PUBLIC_RATE_LIMIT`. |
| `SUBMISSION_RATE_BURST` | `10` | no | ConfigMap | Burst for `SUBMISSION_RATE_LIMIT`. |

A wrong value stops the backend, for example
`invalid config: PUBLIC_RATE_LIMIT: rate "fast" must look like 10/s, 60/m or 1000/h (or off)`.

Request bodies are limited to 1 MiB; a larger JSON body gets
`413 request_too_large`. Files never pass through the API (browsers upload
straight to S3), so no form comes near the limit.

## Internal TLS

On Kubernetes, Rally's backend serves HTTPS inside the cluster and checks
the certificates of the services it calls
([Internal TLS](../../operations/internal-tls.md)). The Helm chart sets
these three variables itself while `internalTLS.enabled` is `true` (the
default), so you normally do not add them to `config:`; see
[Helm values](#helm-values). In Docker Compose development all three stay
empty and the backend serves plain HTTP.

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `TLS_CERT_FILE` | none | no | ConfigMap (set by the chart) | Path to the PEM certificate the backend serves HTTPS with; on Kubernetes `/etc/conservices-tls/tls.crt`. Set it together with `TLS_KEY_FILE`: setting only one stops the backend with `tls: TLS_CERT_FILE and TLS_KEY_FILE must be set together`. Both empty means plain HTTP. The backend re-reads the file every minute, so a certificate renewed by cert-manager is used without a restart. |
| `TLS_KEY_FILE` | none | no | ConfigMap (set by the chart) | Path to the matching PEM private key; on Kubernetes `/etc/conservices-tls/tls.key`. |
| `SSL_CERT_DIR` | none (system CAs only) | on Kubernetes | ConfigMap (set by the chart) | Standard Go setting: folders of extra CA certificates the backend trusts when it calls PostgreSQL, S3, Den and the identity provider. Separate several folders with `:`. On Kubernetes `/etc/conservices-internal-ca` (the platform's internal CA); the local example overlay uses `/etc/conservices-internal-ca:/etc/conservices-ca` to trust mkcert's root as well, and the local Docker stack points it at Caddy's CA so Rally trusts `auth.conservices.test`. Without it, calls fail with `x509: certificate signed by unknown authority`. |

With TLS on, the backend logs `tls enabled` at start, with the
certificate's expiry date in `not_after`. If a later re-read fails, it logs
`tls certificate reload failed; keeping the current one` and keeps serving
the old certificate. The minimum protocol version is TLS 1.2.

## Object storage

Submission attachments live in S3. Browsers upload and download them
**directly** with short-lived signed links; the backend only signs and
checks.

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `S3_ENABLED` | `true` | no | ConfigMap | `false` skips storage (uploads then fail). Only for tests. |
| `S3_ENDPOINT` | none | while enabled | ConfigMap | S3 API address the backend uses, on the platform `https://s3.conservices-data.svc.cluster.local:9000`. |
| `S3_BUCKET` | none | while enabled | ConfigMap | Bucket, platform: `events-data`. Created on start if missing. |
| `S3_ACCESS_KEY_ID` | none | while enabled | **Secret** | Access key. |
| `S3_SECRET_ACCESS_KEY` | none | while enabled | **Secret** | Secret key. |
| `S3_REGION` | `us-east-1` | no | ConfigMap | Region. |
| `S3_USE_PATH_STYLE` | `true` | no | ConfigMap | `false` for AWS S3. |
| `S3_PUBLIC_BASE_URL` | none | when `S3_ENDPOINT` is internal | ConfigMap | Address **browsers** reach S3 at, for example `https://s3.example.org`. Rally rewrites signed links to it. |

## Sign-in

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `AUTH_MODE` | `oidc` | no | ConfigMap | `oidc` verifies bearer access tokens. `dev` trusts `X-Dev-User` and is **refused unless `APP_ENV=development`**: the backend stops with `AUTH_MODE=dev lets anyone sign in as anyone and is only allowed with APP_ENV=development (got APP_ENV="production")`. In dev mode the API also accepts the `X-Dev-User` and `X-Dev-Groups` headers through CORS; in OIDC mode it deletes them from every request. See [Defaults: AUTH_MODE and APP_ENV](../../concepts/authentication.md#defaults-auth_mode-and-app_env). |
| `OIDC_ISSUER_URL` | none | with `oidc` | ConfigMap | Staff issuer, for example `https://auth.example.org/realms/conservices`. Write it exactly as the identity provider publishes it (Keycloak: no trailing slash). |
| `OIDC_CLIENT_ID` | none | with `oidc` | ConfigMap | Staff web app client (`events-spa`). |
| `OIDC_AUDIENCE` | `events-api` | no | ConfigMap | The audience (`aud`) the staff app's **access tokens** must carry. Keycloak adds it with an audience mapper on `events-spa` ([Set up Rally](setup.md#2-prepare-keycloak)). ID tokens are refused whatever their audience, and so is a token for another module's API. |
| `OIDC_GROUPS_CLAIM` | `groups` | no | ConfigMap | The token claim that holds a staff member's groups. The `roles` claim is **never** read in addition. A dotted name such as `realm_access.roles` is followed into nested objects. |
| `OIDC_GROUP_MATCH` | `full` | no | ConfigMap | How a group in the token is compared with a binding in the access configuration: `full` compares the whole path, `last` only the last segment. See [How groups are matched](../../concepts/authentication.md#how-groups-are-matched). |
| `OIDC_GROUP_PREFIX` | none | no | ConfigMap | A parent group such as `/con2026` removed from group names before comparing, for an identity provider that keeps each convention year under its own parent. |
| `ACCESS_CONFIG_PATH` | none | in production | ConfigMap | Path of `access-config.toml` (roles and group bindings). The chart sets `/etc/rally/access-config.toml`. A wrong path or unknown permission stops startup (`load access config: …`). Without it the built-in roles apply but no group grants anything. |
| `DEV_DEFAULT_USER` | `dev-admin` | no | ConfigMap | Name used in `dev` mode without an `X-Dev-User` header. |
| `ATTENDEE_OIDC_ISSUER_URL` | none | for attendee sign-in | ConfigMap | Issuer of the **attendee** realm, for example `https://auth.example.org/realms/attendees`. Must be another realm than `OIDC_ISSUER_URL`, compared without regard to case, default port or a trailing slash; the backend also refuses to start when both realms' discovery documents name the same issuer. Empty: the submission site only lists open calls. |
| `ATTENDEE_OIDC_CLIENT_ID` | none | with the issuer | ConfigMap | Submission site client (`rally-submit`). |
| `ATTENDEE_OIDC_AUDIENCE` | `events-public-api` | no | ConfigMap | The audience the submission site's access tokens must carry (an audience mapper on `rally-submit`). Must differ from `OIDC_AUDIENCE`. |

**Staff and attendees never mix.** Staff tokens are accepted only on
`/api/v1/...` and the role catalog, attendee tokens only on
`/api/public/v1/...`. A token from the other realm is refused before
anything else is checked, with `401` and a message saying which kind of
account is needed. Attendee tokens never carry groups, so they can never
grant a staff role. People are stored by issuer and subject, so the same
subject in both realms is two different people.

## Den and branding

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `DEN_INTERNAL_URL` | none | on Kubernetes | ConfigMap | Replaces scheme and host of a pasted Den pairing URL (platform: `https://den-backend.conservices-den.svc.cluster.local:8080`); the pasted host is then never contacted. |
| `DEN_ALLOWED_HOSTS` | none | when `DEN_INTERNAL_URL` is empty | ConfigMap | Comma-separated hosts a pasted pairing URL may point at, for example `den.example.org` or `*.example.org`. Outside `APP_ENV=development` the URL must also use `https://`; in development `localhost`, `127.0.0.1`, `::1` and `*.conservices.test` are always allowed. |
| `DEN_LINK_ENCRYPTION_KEY` | none | **yes**, unless `APP_ENV=development` | **Secret** | 32 random bytes, base64 (`openssl rand -base64 32`). Encrypts the Den credential Rally stores in its database (AES-256-GCM). Without it outside development the backend stops with `DEN_LINK_ENCRYPTION_KEY is required unless APP_ENV=development`. A credential stored before the key was set is encrypted on the next read, so no re-pairing is needed. One key per module, never shared; see [Den link encryption key](../../operations/secrets.md#den-link-encryption-key). |
| `DEN_LINK_ENCRYPTION_KEY_PREVIOUS` | none | no | **Secret** | The old key during a [rotation](../../operations/secrets.md#den-link-encryption-key). |
| `DEN_MODE` | `standalone` | no | ConfigMap | `required`: until the module is paired with Den, its API answers `503 den_pairing_required` and the web app shows *Waiting for Den* (admins: *Connect this module to Den*). `standalone`: the module works without Den; pairing is optional. Kubernetes sets `required` (Helm: `den.mode`); Docker Compose sets `standalone`. See [Required or standalone](../../concepts/pairing.md#required-or-standalone). |
| `BRAND_LOCAL_PATH` | none | no | ConfigMap | Optional `brand.json` for standalone use; Den's brand replaces it once paired. |

## Role catalog

HR reads Rally's roles from [`GET /api/role-catalog`](api.md#get-apirole-catalog)
to offer them in its access picker.

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `HR_SERVICE_TOKEN` | none | for HR's access picker | **Secret** | The token HR's backend sends to read the catalog; the same value as HR's `HR_SERVICE_TOKEN`, at least 32 characters (`openssl rand -hex 32`). It allows nothing but reading the catalog and is compared in constant time. Empty: only staff sign-ins can read the catalog, so HR cannot. See [Secrets](../../operations/secrets.md#inventory). |

## Public schedule

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `PUBLIC_SCHEDULE_ENABLED` | `false` | no | ConfigMap | Serves the published schedule under `/api/public/v1/schedules`. When paired and set, Den's `events_public_schedule` setting wins. |
| `PUBLIC_API_BUILTIN_KEY` | none | no | ConfigMap | The "programme-page" API key the submission site sends. The Helm chart hands it to the site as `publicScheduleKey` in its `/config.json`; elsewhere set both to the same value. It ships to every browser, so it is **not a secret**; changing it rotates the key, empty removes it. |

## Live-day announcements

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `TELEGRAM_BOT_TOKEN` | none | no | **Secret** | Bot token. Empty: sending an announcement is a recorded dry run. |
| `TELEGRAM_API_URL` | `https://api.telegram.org` | no | ConfigMap | Telegram API address (change only for testing). |

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

## Web app settings (config.json)

The `rally-frontend` image names no domain, so one published image works for
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
| `oidcClientId` | `""` | The public client the web app signs in with: `events-spa`. Required with `"oidc"`. |
| `oidcScope` | `"openid profile email"` | Scopes requested at sign-in. |
| `apiBaseUrl` | `""` | Address put in front of every API call (`/api/...`). Leave empty: nginx serves the app and forwards `/api/` on the same address. Only set it when the API lives on another origin, for example `https://api.example.org`. |
| `productName` | `""` (shows `Rally`) | Name shown until Den's brand has loaded. |
| `productName` | `""` (shows `Rally`, or `Event submissions` on the submission site) | Name shown in the app. |
| `publicScheduleKey` | `""` | Submission site only: the key its Programme page sends to the public schedule API. Must equal the backend's `PUBLIC_API_BUILTIN_KEY`. Every visitor can read it, so it is not a secret. |

Keys you leave out keep their default; unknown keys are ignored. The image
ships a placeholder file with empty `oidcAuthority` and `oidcClientId`: the
web app then shows **Not configured yet** instead of a sign-in page.

Rally has two web apps, and each gets its own file: the staff app
(`rally-frontend`, client `events-spa`, staff realm) and the public
submission site (`rally-submit`, client `rally-submit`, attendee realm
`https://auth.example.org/realms/attendees`).

Example for `events.example.org`:

```json
{
  "authMode": "oidc",
  "oidcAuthority": "https://auth.example.org/realms/conservices",
  "oidcClientId": "events-spa",
  "oidcScope": "openid profile email",
  "apiBaseUrl": "",
  "productName": "Rally"
}
```

And for the submission site:

```json
{
  "authMode": "oidc",
  "oidcAuthority": "https://auth.example.org/realms/attendees",
  "oidcClientId": "rally-submit",
  "productName": "Event submissions",
  "publicScheduleKey": "change-me-programme-key"
}
```

### How to set it

1. **Helm:** set `frontend.config` in your values. Keys you leave out are
   filled in from the chart's other values: `authMode` from `config.AUTH_MODE`, `oidcAuthority` from `config.OIDC_ISSUER_URL`, `oidcClientId` from `config.OIDC_CLIENT_ID` (else `events-spa`), `productName` `Rally`, `productName` `Rally`,
   `oidcScope` `openid profile email` and `apiBaseUrl` empty. So with the
   usual `config.OIDC_ISSUER_URL` you often need nothing extra. The chart
   writes the file to the ConfigMap `<release>-frontend-config` and restarts
   the web app pods when it changes.

   ```yaml
   frontend:
     config:
       oidcAuthority: https://auth.example.org/realms/conservices
       oidcClientId: events-spa
   ```

   The submission site uses `submit.config` (ConfigMap
   `<release>-submit-config`), filled in from
   `config.ATTENDEE_OIDC_ISSUER_URL`, `config.ATTENDEE_OIDC_CLIENT_ID` and
   `config.PUBLIC_API_BUILTIN_KEY`.

2. **Docker Compose:** the module's `infra/docker-compose.yml` mounts
   `infra/frontend-config/compose.json` (dev sign-in). For real sign-in, copy
   it, fill in the keys and set `FRONTEND_CONFIG` (a path relative to
   `infra/`) in `.env`. The full platform stack (root `docker-compose.yml`)
   mounts `infra/frontend-config/rally.json` and `rally-submit.json`.
3. **Plain Docker:** mount the file read-only:

   ```sh
   docker run --rm -p 3000:8080 \
     -v "$PWD/config.json:/etc/conservices/config.json:ro" \
     ghcr.io/aglelectronics/rally-frontend:1.0.0-1
   ```

Check what the browser gets:

```sh
curl -i https://events.example.org/config.json
```

```text
HTTP/2 200
content-type: application/json
cache-control: no-store

{
  "authMode": "oidc",
  "oidcAuthority": "https://auth.example.org/realms/conservices",
  "oidcClientId": "events-spa",
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

### Tokens and sessions

Both web apps follow the platform's
[token contract](../../concepts/authentication.md#tokens-the-10-contract):

- They send the **access token** to the API, never the ID token. Its
  audience must be `OIDC_AUDIENCE` (staff app) or `ATTENDEE_OIDC_AUDIENCE`
  (submission site); see [Set up Rally](setup.md#2-prepare-keycloak) for
  the audience mappers.
- They keep tokens **in memory only**, never in `localStorage` or
  `sessionStorage`. After a reload the app signs in again silently through
  the Keycloak session (a hidden frame to Keycloak), so nobody types a
  password; only when the Keycloak session has ended does the sign-in page
  appear. Each tab holds its own tokens and follows the Keycloak session:
  signing out in one tab or app signs out the others within seconds.
- The submission site remembers only *that* the browser signed in before (a
  `rally.oidc.signedIn` flag, not a token), so it does not contact Keycloak
  for visitors who never had an account.

## Web app security headers

nginx in both web app images sends a Content Security Policy and the other
browser security headers on every page (not on `/api/`, where the backend
sets its own). The policy allows scripts, styles and fonts only from the app
itself, and connections only to the app, the sign-in server and the S3
upload address. The image fills in those two addresses when the container
starts, from these environment variables of the **web app** container:

| Name | Default | What it does |
| --- | --- | --- |
| `KEYCLOAK_ORIGIN` | none | The sign-in server's origin (scheme and host, no path), for example `https://auth.example.org`. On the submission site: the attendee realm's server. Empty: allowed only with dev sign-in. |
| `S3_ORIGIN` | none | The origin browsers upload attachments to: the scheme and host of the backend's `S3_PUBLIC_BASE_URL`, for example `https://s3.example.org`. Empty: uploads fail with a CSP error in the browser console. |

The Helm chart fills both in from `config.OIDC_ISSUER_URL` (or
`config.ATTENDEE_OIDC_ISSUER_URL` for the submission site) and
`config.S3_PUBLIC_BASE_URL`; see [Helm values](#helm-values). Check the
result:

```sh
curl -sI https://events.example.org/ | grep -i -E 'content-security|x-frame|referrer|permissions|nosniff'
```

```text
content-security-policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' https://auth.example.org https://s3.example.org; frame-src 'self' https://auth.example.org; frame-ancestors 'none'; form-action 'self' https://auth.example.org; base-uri 'self'; object-src 'none'
x-frame-options: DENY
x-content-type-options: nosniff
referrer-policy: strict-origin-when-cross-origin
permissions-policy: camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()
```

**Troubleshooting**

- **Sign-in hangs or the browser console shows `Refused to connect to
  'https://auth…' because it violates the … Content Security Policy`**:
  `KEYCLOAK_ORIGIN` is empty or wrong. On the submission site it must be
  the attendee realm's server.
- **Uploads fail with `Refused to connect to 'https://s3…'`**: set
  `S3_ORIGIN` to the scheme and host of `S3_PUBLIC_BASE_URL`.
- **The container logs `20-envsubst-on-templates.sh: ERROR: … is not
  writable`**: the root file system is read-only and nothing mounted the
  headers file; the image then uses its built-in copy without outside
  origins. The Helm chart mounts its own file and switches this step off.

## Frontend build settings

Docker build arguments of `infra/Dockerfile.frontend`. None of them is
installation-specific; the sign-in settings live in `/config.json` (above).

| Build argument | Default | What it does |
| --- | --- | --- |
| `RALLY_APP` | `staff` | `staff` builds the staff app (`rally-frontend`), `submit` the public submission site (`rally-submit`). |
| `RALLY_VERSION` | `dev` | Version shown in the app. |
| `NGINX_CONF` | `nginx.conf` | Which file from `infra/` becomes the image's nginx config. The Helm chart (and the Kustomize manifests) mount their own. Every one includes `/etc/nginx/snippets/security-headers.conf` ([Web app security headers](#web-app-security-headers)). |

```sh
docker build -f infra/Dockerfile.frontend \
  --build-arg RALLY_APP=staff \
  --build-arg RALLY_VERSION=1.0.0 \
  -t registry.example.org/conservices/rally-frontend:1.0.0-1 .
```

The local dev server (`npm run dev`) has no `/config.json`; it uses
`VITE_AUTH_MODE`, `VITE_OIDC_AUTHORITY`, `VITE_OIDC_CLIENT_ID`, `VITE_OIDC_SCOPE`, `VITE_API_BASE_URL` (for example `http://localhost:8100`), `VITE_PRODUCT_NAME`, `VITE_PUBLIC_SCHEDULE_KEY` from the environment or `.env` instead. Image builds
ignore these.


## Helm values

The chart [`deploy/charts/rally`](https://github.com/AGlElectronics/con-services/tree/main/deploy/charts/rally)
maps these settings as follows:

| Values key | Becomes |
| --- | --- |
| `config.*` | ConfigMap `<release>-config`, loaded into the backend with `envFrom`. Every non-secret variable above. |
| `existingSecret` (default `rally-secrets`) | Loaded with `envFrom`; must hold `DATABASE_URL`, `DEN_LINK_ENCRYPTION_KEY` and the S3 keys, optionally `HR_SERVICE_TOKEN`, `TELEGRAM_BOT_TOKEN` and, during a rotation, `DEN_LINK_ENCRYPTION_KEY_PREVIOUS`. The chart never creates it. |
| `frontend.cspConnectSrc` (default `[]`) | Extra origins added to the web apps' `connect-src` and `frame-src`, for example an attendee identity provider whose token endpoint lives on another host. The sign-in server and S3 origins are derived from `config` ([Web app security headers](#web-app-security-headers)). |
| `accessConfig.existingConfigMap` (default `rally-access-config`) | Mounted at `accessConfig.mountPath` (`/etc/rally`); `ACCESS_CONFIG_PATH` is set to it. |
| `image.backend`, `image.migrate`, `image.frontend` | Images; `tag` is required. |
| `submit.enabled`, `submit.image`, `submit.host` | Optional submission site Deployment, Service, and the host of its HTTPRoute (or Ingress). `submit.image.repository` defaults to `ghcr.io/aglelectronics/rally-submit`, an empty `submit.image.tag` to `image.frontend.tag`. |
| `frontend.config` (default `{}`) | The staff app's `/config.json` ([Web app settings](#web-app-settings-configjson)), as the ConfigMap `<release>-frontend-config`. Keys left out come from `config.AUTH_MODE`, `config.OIDC_ISSUER_URL` and `config.OIDC_CLIENT_ID`. |
| `submit.config` (default `{}`) | The submission site's `/config.json`, as the ConfigMap `<release>-submit-config`. Keys left out come from `config.AUTH_MODE`, `config.ATTENDEE_OIDC_ISSUER_URL`, `config.ATTENDEE_OIDC_CLIENT_ID` and `config.PUBLIC_API_BUILTIN_KEY`. |
| `backend.extraEnv`, `extraVolumes`, `extraVolumeMounts`, `hostAliases` | Extra settings for special cases (CA bundles, local DNS). |
| `networkPolicy.*` | NetworkPolicies; see [Setup](setup.md). `extraEgress` for Telegram or a standalone database. |
| `internalTLS.enabled` (default `true`) | HTTPS inside the cluster: sets `TLS_CERT_FILE`, `TLS_KEY_FILE` and `SSL_CERT_DIR`, mounts the certificate at `/etc/conservices-tls` and the CA at `/etc/conservices-internal-ca`, and makes nginx serve HTTPS and check the backend. `false` turns all of it off; change the `https://` URLs in `config:` back to `http://`. |
| `internalTLS.createCertificates` (default `true`) | Asks cert-manager for `rally-backend-tls` and `rally-frontend-tls`. `false`: create those Secrets yourself (keys `tls.crt`, `tls.key`, `ca.crt`). |
| `internalTLS.issuerRef` (default ClusterIssuer `conservices-internal-ca`) | The cert-manager issuer that signs them. |
| `internalTLS.duration`, `internalTLS.renewBefore` (default `2160h`, `720h`) | Certificate lifetime (90 days) and how long before expiry cert-manager renews it (30 days). |
| `internalTLS.caConfigMap` (default `conservices-internal-ca`) | ConfigMap (key `ca.crt`) with the internal CA, copied into the namespace by trust-manager. |
| `internalTLS.ingressNginxAnnotations` (default `false`) | Legacy, only with `ingress.enabled: true`: adds the ingress-nginx annotations that make the controller talk HTTPS to the web app and check its certificate. The Gateway API route uses a `BackendTLSPolicy` instead. ingress-nginx is no longer maintained; do not use it. |
| `route.*` (default on: host `events.conservices.test`, Gateway `public` in `conservices-gateway`, timeout `60s`) | Gateway API `HTTPRoute` and, with internal TLS, a `BackendTLSPolicy`. Rally renders one `HTTPRoute` and one `BackendTLSPolicy` per web app: the staff app on `route.host`, the submission site on `submit.host`. See [Exposing the web app](../../operations/helm.md#exposing-the-web-app-gateway-api). |
| `ingress.*` (default off) | Plain `Ingress` for another controller. |
| `frontend.clientMaxBodySize` (default `50m`) | Upload limit in the web app's nginx; the gateway has no limit of its own. |
| `ha.podDisruptionBudget`, `ha.topologySpread`, `priorityClassName` | PodDisruptionBudget and spreading over nodes for the web apps; see [High availability](../../operations/helm.md#high-availability). |
| `imagePullSecrets` (default `[]`) | Pull Secrets for private images on every pod (frontend, submission site, backend), for example `[{name: ghcr-pull}]`; see [Private images](../../operations/helm.md#private-images). |
| `networkPolicy.data.s3.external.fqdns`, `.cidrs`, `.port` (default `[]`, `[]`, `443`) | Egress to an external S3 such as Hetzner Object Storage: host names with Cilium, address ranges otherwise; see [External S3](../../operations/helm.md#external-s3-hetzner-object-storage). |
