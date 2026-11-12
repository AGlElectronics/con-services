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
| `APP_ENV` | `production` | no | ConfigMap | `development` allows dev sign-in headers and dev-only secrets. Anything else, including empty, is production. Docker Compose sets `development`; the chart sets `production`. |
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
| `AUTH_MODE` | `oidc` | no | ConfigMap | `oidc` verifies access tokens. `dev` trusts `X-Dev-User` and `X-Dev-Groups` and is refused unless `APP_ENV=development`. |
| `OIDC_ISSUER_URL` | none | with `oidc` | ConfigMap | Token issuer, for example `https://auth.example.org/realms/conservices`. |
| `OIDC_CLIENT_ID` | none | with `oidc` | ConfigMap | Web app client (`hr-spa`). |
| `OIDC_AUDIENCE` | `hr-api` | no | ConfigMap | Audience an access token must carry. Keycloak adds it with an audience mapper on `hr-spa`. ID tokens are refused. |
| `OIDC_GROUPS_CLAIM` | `groups` | no | ConfigMap | The only token claim HR reads groups from. The `roles` claim is ignored. |
| `OIDC_GROUP_MATCH` | `full` | no | ConfigMap | `full` compares the whole group path; `last` compares only the last segment. |
| `OIDC_GROUP_PREFIX` | none | no | ConfigMap | Removed from group names that start with it before they are compared, for example `/con2026`. |
| `HR_ADMIN_GROUPS` | `hr-admin` | no | ConfigMap | Comma-separated IdP groups whose members are **HR admins** (everything, including settings, imports and the audit log). Compared with `OIDC_GROUP_MATCH` (a leading `/` and case do not matter). |
| `HR_VIEWER_GROUPS` | `hr-viewer` | no | ConfigMap | Groups whose members are **HR viewers**: read-only access to people, departments, onboardings and the audit log. |
| `HR_LEAD_GROUPS` | `hr-lead` | no | ConfigMap | Groups whose members are **department leads**: they see and onboard people only in the departments an admin made them lead of. Someone in none of the three groups gets 403 and can only use the self-service page. |
| `DEV_DEFAULT_USER` | `dev-hr-admin` | no | ConfigMap | Name used in `dev` mode without an `X-Dev-User` header. |

`HR_ACCESS_GROUPS` from earlier previews is no longer read: move its
value to `HR_ADMIN_GROUPS`. The [Admin guide](admin-guide.md#roles) lists
what each role may do.

## Account provisioning (Keycloak)

`IDP_PROVISIONER_MODE` says what HR does with accounts in the identity
provider (IdP):

- `manage` (default): HR creates accounts on onboarding, keeps their groups
  and attributes in step, and disables and deletes them on offboarding.
- `link`: HR never creates or deletes accounts. It finds the existing
  account (an account brokered from the convention's own SSO, or an IdP you
  already run) by email or username, links it to the person and sets only
  groups and attributes. Use it when accounts belong to another system.
- `off`: HR keeps records only and touches no accounts.

With `manage` or `link`, set both `KEYCLOAK_BASE_URL` and
`KEYCLOAK_CLIENT_SECRET`. In development, when neither is set, HR uses a
fake provisioner that creates nothing (logged as `using FakeIdP`); outside
`APP_ENV=development` HR refuses to start instead. Setting only one is an
error.

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `IDP_PROVISIONER_MODE` | `manage` | no | ConfigMap | `manage`, `link` or `off` (above). Any other value stops the backend at startup. |
| `KEYCLOAK_BASE_URL` | none | for real accounts | ConfigMap | Keycloak address HR's backend can reach, on the platform `https://keycloak.conservices-identity.svc.cluster.local:8443`. |
| `KEYCLOAK_REALM` | `conservices` | no | ConfigMap | Realm the accounts live in. |
| `KEYCLOAK_CLIENT_ID` | `hr-provisioner` | no | ConfigMap | Service-account client used for the admin API. |
| `KEYCLOAK_CLIENT_SECRET` | none | for real accounts | **Secret** | Its secret. It can manage users: keep it in the secret manager. |
| `KEYCLOAK_SETUP_CLIENT_ID` | none | no | ConfigMap | Client the set-password email link returns to (platform: `den-spa`). |
| `KEYCLOAK_SETUP_REDIRECT_URI` | none | no | ConfigMap | Where people land after setting their password (platform: Den's address). |
| `KEYCLOAK_SEND_PASSWORD_SETUP` | `true` | no | ConfigMap | Email new accounts a set-password link (needs SMTP on the realm). Set `false` when people sign in through the convention's SSO; HR then also skips the "resend password email" action for brokered accounts. |
| `KEYCLOAK_GROUP_PARENT` | none (top level) | no | ConfigMap | Parent group HR creates its groups under, for example `/conservices`. HR creates it if missing. |
| `KEYCLOAK_GROUP_PREFIX` | none | no | ConfigMap | Prefix for HR's group names. Parent `/conservices` and prefix `cs-` give `/conservices/cs-dept-security`. Change it only before the first department exists: existing groups are not renamed. |
| `KEYCLOAK_USER_ATTRIBUTES` | `hrPersonId,nickname,orgEmail` | no | ConfigMap | User attributes HR may write. Only attributes the realm's user profile declares are written. |

## Background work

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `JOB_INTERVAL` | `10s` | no | ConfigMap | How often the job worker picks up provisioning work (account creation, group changes, retries). |
| `MAINTENANCE_INTERVAL` | `1h` | no | ConfigMap | Housekeeping: personal-data retention, purges, stuck onboardings, Google Workspace clean-up. |
| `REVIEW_SCAN_INTERVAL` | `15m` | no | ConfigMap | How often HR looks for IdP accounts without an HR record and puts them in the **Review** queue. `0` turns the scan off. |

## Other modules

Once HR is paired with Den, it asks Den which modules are paired
(`GET /api/v1/integrations/modules`, with the pairing credential) and
reads each one's role catalog at the `role_catalog_url` Den returns.
Do not append `/api/role-catalog`: Den already built that address from
the module's internal URL, or from its public URL when it has no
internal URL. A module with an empty slug or no catalog URL is skipped.
When Den says HR is not paired, or the call fails, that attempt
discovers nothing and `ROLE_CATALOG_SOURCES` is the whole list; HR still
shows the last catalog it saved for a module. `ROLE_CATALOG_SOURCES`
replaces the URL of a slug Den listed and adds modules Den does not
know. A standalone HR uses only that list.

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `HR_SERVICE_TOKEN` | none | no | **Secret** | Bearer token HR sends when it reads another module's role catalog. At least 32 characters (`openssl rand -hex 32`). The same value on Wiki, Finance, Rally, Tasks, Stash, Learn and Desk. Without it those modules accept only a staff sign-in on their catalog. |
| `ROLE_CATALOG_SOURCES` | none | no | ConfigMap | Optional `slug=url` list. Replaces the URL Den reported for that slug and adds modules Den does not know. A standalone HR uses only this list. HR always includes its own catalog. |
| `QUALIFICATION_CATALOG_SOURCES` | none | no | ConfigMap | Same format, for qualification catalogs, for example `learn=https://learn-backend.conservices-learn.svc.cluster.local:8080/api/qualification-catalog`. |
| `LEARN_HOLDINGS_URL` | none | no | ConfigMap | Learn's `/api/internal/holdings`, for example `https://learn-backend.conservices-learn.svc.cluster.local:8080/api/internal/holdings`. With `LEARN_SERVICE_TOKEN`, turns on training requirements for roles. |
| `LEARN_SERVICE_TOKEN` | none | no | **Secret** | Shared with Learn. |
| `ROLE_GATE_INTERVAL` | `1m` | no | ConfigMap | How often roles waiting for training are re-checked. |
| `OFFBOARD_HOOKS` | none | no | **Secret** | Comma-separated `url|token` entries called when someone is offboarded, for example `https://wiki-backend.conservices-wiki.svc.cluster.local:8080/api/internal/offboarded|<WIKI_SERVICE_TOKEN>`. Failures become warnings. Secret because it contains tokens. Payload: [Offboarding hook](api.md#offboarding-hook). |
| `DEPARTMENT_HOOKS` | none | no | **Secret** | Same format, called when a department is created, renamed or archived, for example `https://tasks-backend.conservices-tasks.svc.cluster.local:8080/api/internal/departments|<TASKS_SERVICE_TOKEN>`. |
| `HR_DIRECTORY_TOKEN` | none (endpoint off) | no | **Secret** | Bearer token other modules (the Wiki) send to [`GET /api/internal/directory/groups`](api.md#get-apiinternaldirectorygroups). At least 16 characters. Set the same value as the Wiki's `HR_DIRECTORY_TOKEN`. |
| `OUTBOUND_ALLOWED_HOSTS` | none | no | ConfigMap | Hosts or CIDRs the address lookup may reach although they are internal (for example a self-hosted Photon: `photon.internal,10.20.0.0/16`). Every private address is refused otherwise. |

## Google Workspace

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `GOOGLE_WORKSPACE_CREDENTIALS_FILE` | none | no | ConfigMap (the chart sets it with `googleWorkspace.enabled`) | Path to the service-account key (JSON). When set, the Google Workspace connector is available and an admin can turn it on in Settings. Empty: the connector stays unavailable and HR works without it. The domain and the admin address are settings on that page, not environment variables. See [Google Workspace](google-workspace.md). |

## Den

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `DEN_INTERNAL_URL` | none | no | ConfigMap | Replaces the host of a pasted Den pairing URL (platform: `https://den-backend.conservices-den.svc.cluster.local:8080`). Empty when standalone. |
| `DEN_ALLOWED_HOSTS` | none | when `DEN_INTERNAL_URL` is empty | ConfigMap | Comma-separated hosts a pasted pairing URL may point at, for example `den.example.org` or `*.example.org`. Not needed while `DEN_INTERNAL_URL` is set. With `APP_ENV=development`, `localhost`, `127.0.0.1`, `::1` and `*.conservices.test` are always allowed. Outside development the URL must also use `https://`. |
| `DEN_MODE` | `standalone` | no | ConfigMap | `required`: until the module is paired with Den, its API answers `503 den_pairing_required` and the web app shows *Waiting for Den* (admins: *Connect this module to Den*). `standalone`: the module works without Den; pairing is optional. Kubernetes sets `required` (Helm: `den.mode`); Docker Compose sets `standalone`. See [Required or standalone](../../concepts/pairing.md#required-or-standalone). |
| `DEN_LINK_ENCRYPTION_KEY` | none | outside development | **Secret** | Base64 of 32 random bytes (`openssl rand -base64 32`). Encrypts the Den credential HR stores. One key per module. Required unless `APP_ENV=development`. |
| `DEN_LINK_ENCRYPTION_KEY_PREVIOUS` | none | no | **Secret** | The previous key, only while rotating `DEN_LINK_ENCRYPTION_KEY`. Remove it after the restart that re-encrypts the credential. |

## Email (HR's own notices)

HR emails people when their account is deleted, and HR admins about
retention and Google Workspace deadlines. When Den sets `smtp.host`,
that server is used. When Den also sets `password_set`, HR fetches the
password from Den at send time
([Fetching the SMTP password](../../concepts/module-settings.md#fetching-the-smtp-password));
it is kept in memory for at most a minute and is never written to HR's
database. `SMTP_PASSWORD` is used only when Den sets no mail server.
With neither a Den server nor `SMTP_HOST`, HR shows a warning instead of
sending. Password-setup emails are sent by Keycloak, not by these settings.

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `SMTP_HOST` | none | no | ConfigMap | Mail server, used when Den sets no `smtp.host`. |
| `SMTP_PORT` | `587` | no | ConfigMap | Port, used with `SMTP_HOST`. |
| `SMTP_USERNAME` | none | no | ConfigMap | Login, used with `SMTP_HOST`. |
| `SMTP_PASSWORD` | none | no | **Secret** | Password, used only when Den sets no mail server. |
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
