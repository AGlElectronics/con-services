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
| `DATABASE_URL` | none | **yes** | **Secret** | PostgreSQL URL. Also the only setting the `hr-migrate` image reads. On the platform it ends in `?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt`, because the platform's PostgreSQL accepts only TLS connections. |
| `CORS_ALLOWED_ORIGINS` | `http://localhost:3003` | no | ConfigMap | Comma-separated browser origins allowed to call the API. |
| `TRUSTED_PROXY_CIDRS` | `10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,127.0.0.0/8,::1/128,fc00::/7` | no | ConfigMap | Comma-separated CIDRs of the proxies in front of the API (Gateway, nginx, Caddy). `X-Forwarded-For` is only believed on connections from these addresses; the resulting client IP is what rate limits count. Add a proxy that sits outside the private ranges; `none` trusts no proxy. See [Client IP addresses](../../operations/production.md#client-ip-addresses). |
| `SHUTDOWN_TIMEOUT` | `15s` | no | ConfigMap | Grace period for running requests on stop. |

## Internal TLS

On Kubernetes, HR's backend serves HTTPS inside the cluster and checks the
certificates of the services it calls
([Internal TLS](../../operations/internal-tls.md)). The Helm chart sets
these three variables itself while `internalTLS.enabled` is `true` (the
default), so you normally do not add them to `config:`; the chart values
are listed in [Setup](setup.md#internal-tls). In Docker Compose
development all three stay empty and the backend serves plain HTTP.

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `TLS_CERT_FILE` | none | no | ConfigMap (set by the chart) | Path to the PEM certificate the backend serves HTTPS with; on Kubernetes `/etc/conservices-tls/tls.crt`. Set it together with `TLS_KEY_FILE`: setting only one stops the backend with `tls: TLS_CERT_FILE and TLS_KEY_FILE must be set together`. Both empty means plain HTTP. The backend re-reads the file every minute, so a certificate renewed by cert-manager is used without a restart. |
| `TLS_KEY_FILE` | none | no | ConfigMap (set by the chart) | Path to the matching PEM private key; on Kubernetes `/etc/conservices-tls/tls.key`. |
| `SSL_CERT_DIR` | none (system CAs only) | on Kubernetes | ConfigMap (set by the chart) | Standard Go setting: folders of extra CA certificates the backend trusts when it calls PostgreSQL, Keycloak, Den and the other modules. Separate several folders with `:`. On Kubernetes `/etc/conservices-internal-ca` (the platform's internal CA); the local example overlay uses `/etc/conservices-internal-ca:/etc/conservices-ca` to trust mkcert's root as well. Without it, calls fail with `x509: certificate signed by unknown authority`. |

With TLS on, the backend logs `tls enabled` at start, with the
certificate's expiry date in `not_after`. If a later re-read fails, it logs
`tls certificate reload failed; keeping the current one` and keeps serving
the old certificate. The minimum protocol version is TLS 1.2.

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
| `KEYCLOAK_BASE_URL` | none | for real accounts | ConfigMap | Keycloak address HR's backend can reach, on the platform `https://keycloak.conservices-identity.svc.cluster.local:8443`. |
| `KEYCLOAK_REALM` | `conservices` | no | ConfigMap | Realm the accounts live in. |
| `KEYCLOAK_CLIENT_ID` | `hr-provisioner` | no | ConfigMap | Service-account client used for the admin API. |
| `KEYCLOAK_CLIENT_SECRET` | none | for real accounts | **Secret** | Its secret. It can manage users: keep it in the secret manager. |
| `KEYCLOAK_SETUP_CLIENT_ID` | none | no | ConfigMap | Client the set-password email link returns to (platform: `den-spa`). |
| `KEYCLOAK_SETUP_REDIRECT_URI` | none | no | ConfigMap | Where people land after setting their password (platform: Den's address). |

## Other modules

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `ROLE_CATALOG_SOURCES` | none | no | ConfigMap | Comma-separated `slug=url` list of other modules' `GET /api/role-catalog`, for example `stash=https://stash-backend.conservices-stash.svc.cluster.local:8080/api/role-catalog,events=https://rally-backend.conservices-rally.svc.cluster.local:8080/api/role-catalog`. HR always includes its own catalog. |
| `QUALIFICATION_CATALOG_SOURCES` | none | no | ConfigMap | Same format, for qualification catalogs, for example `learn=https://learn-backend.conservices-learn.svc.cluster.local:8080/api/qualification-catalog`. |
| `LEARN_HOLDINGS_URL` | none | no | ConfigMap | Learn's `/api/internal/holdings`, for example `https://learn-backend.conservices-learn.svc.cluster.local:8080/api/internal/holdings`. With `LEARN_SERVICE_TOKEN`, turns on training requirements for roles. |
| `LEARN_SERVICE_TOKEN` | none | no | **Secret** | Shared with Learn. |
| `ROLE_GATE_INTERVAL` | `1m` | no | ConfigMap | How often roles waiting for training are re-checked. |
| `OFFBOARD_HOOKS` | none | no | **Secret** | Comma-separated `url|token` entries called when someone is offboarded, for example `https://wiki-backend.conservices-wiki.svc.cluster.local:8080/api/internal/offboarded|<WIKI_SERVICE_TOKEN>`. Failures become warnings. Secret because it contains tokens. |
| `DEPARTMENT_HOOKS` | none | no | **Secret** | Same format, called when a department is created or renamed, for example `https://tasks-backend.conservices-tasks.svc.cluster.local:8080/api/internal/departments|<TASKS_SERVICE_TOKEN>`. |

## Den

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `DEN_INTERNAL_URL` | none | no | ConfigMap | Replaces the host of a pasted Den pairing URL (platform: `https://den-backend.conservices-den.svc.cluster.local:8080`). Empty when standalone. |

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

## Web app settings (config.json)

The `hr-frontend` image names no domain, so one published image works for
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
| `oidcClientId` | `""` | The public client the web app signs in with: `hr-spa`. Required with `"oidc"`. |
| `oidcScope` | `"openid profile email"` | Scopes requested at sign-in. |
| `apiBaseUrl` | `""` | Address put in front of every API call (`/api/...`). Leave empty: nginx serves the app and forwards `/api/` on the same address. Only set it when the API lives on another origin, for example `https://api.example.org`. |

Keys you leave out keep their default; unknown keys are ignored. The image
ships a placeholder file with empty `oidcAuthority` and `oidcClientId`: the
web app then shows **Not configured yet** instead of a sign-in page.

Example for `hr.example.org`:

```json
{
  "authMode": "oidc",
  "oidcAuthority": "https://auth.example.org/realms/conservices",
  "oidcClientId": "hr-spa",
  "oidcScope": "openid profile email",
  "apiBaseUrl": ""
}
```

### How to set it

1. **Helm:** set `frontend.config` in your values. Keys you leave out are
   filled in from the chart's other values: `authMode` from `config.AUTH_MODE`, `oidcAuthority` from `config.OIDC_ISSUER_URL`, `oidcClientId` from `config.OIDC_CLIENT_ID` (else `hr-spa`),
   `oidcScope` `openid profile email` and `apiBaseUrl` empty. So with the
   usual `config.OIDC_ISSUER_URL` you often need nothing extra. The chart
   writes the file to the ConfigMap `<release>-frontend-config` and restarts
   the web app pods when it changes.

   ```yaml
   frontend:
     config:
       oidcAuthority: https://auth.example.org/realms/conservices
       oidcClientId: hr-spa
   ```

2. **Docker Compose:** the module's `infra/docker-compose.yml` mounts
   `infra/frontend-config/compose.json` (dev sign-in). For real sign-in, copy
   it, fill in the keys and set `FRONTEND_CONFIG` (a path relative to
   `infra/`) in `.env`. The full platform stack (root `docker-compose.yml`)
   mounts `infra/frontend-config/hr.json`.
3. **Plain Docker:** mount the file read-only:

   ```sh
   docker run --rm -p 3000:8080 \
     -v "$PWD/config.json:/etc/conservices/config.json:ro" \
     ghcr.io/aglelectronics/hr-frontend:1.0.0-1
   ```

Check what the browser gets:

```sh
curl -i https://hr.example.org/config.json
```

```text
HTTP/2 200
content-type: application/json
cache-control: no-store

{
  "authMode": "oidc",
  "oidcAuthority": "https://auth.example.org/realms/conservices",
  "oidcClientId": "hr-spa",
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
| `HR_VERSION` | `dev` | Version shown in the app. |
| `NGINX_CONF` | `nginx.conf` | Which file from `infra/` becomes the image's nginx config. The Helm chart (and the Kustomize manifests) mount their own. |

```sh
docker build -f infra/Dockerfile.frontend \
  --build-arg HR_VERSION=1.0.0 \
  -t registry.example.org/conservices/hr-frontend:1.0.0-1 .
```

The local dev server (`npm run dev`) has no `/config.json`; it uses
`VITE_AUTH_MODE`, `VITE_OIDC_AUTHORITY`, `VITE_OIDC_CLIENT_ID`, `VITE_OIDC_SCOPE`, `VITE_API_BASE_URL` (for example `http://localhost:8110`) from the environment or `.env` instead. Image builds
ignore these. `VITE_DEV_USER` (default `dev-hr-admin`) picks the user the
dev server signs in as in `dev` mode; production builds always use
`dev-hr-admin`, so the setting cannot be smuggled into an image.
