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
| Secret `tasks-secrets` (`existingSecret`, from your secret manager) | `DATABASE_URL`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `TASKS_SERVICE_TOKEN`, `DEN_LINK_ENCRYPTION_KEY` (the backend pod does not start without it), and optionally `HR_SERVICE_TOKEN`, `DEN_LINK_ENCRYPTION_KEY_PREVIOUS`, and `SMTP_USERNAME`, `SMTP_PASSWORD` when Tasks uses its own mail server. |
| ConfigMap `tasks-access-config` | The access config file. |
| Secrets `tasks-backend-tls`, `tasks-frontend-tls` (from cert-manager) | The pods' internal TLS certificates (`tls.crt`, `tls.key`, `ca.crt`), mounted at `/etc/conservices-tls`. See [Internal TLS](#internal-tls). |
| ConfigMap `conservices-internal-ca` (from trust-manager) | The platform's internal CA (`ca.crt`), mounted at `/etc/conservices-internal-ca`. |

After changing the Secret: `kubectl rollout restart -n conservices-tasks deploy/tasks-backend`.

## Backend

| Variable | Default | Required | Secret | What it does |
| --- | --- | --- | --- | --- |
| `APP_ENV` | `production` | no | no | `development` only on a developer machine; together with `AUTH_MODE=dev`. |
| `APP_BASE_URL` | `http://localhost:8080` | no | no | Public address, for example `https://tasks.example.org`. |
| `HTTP_ADDR` | `:8080` | no | no | Listen address inside the container. Keep `:8080`. |
| `DATABASE_URL` | none | **yes** | **yes** | PostgreSQL URL, for example `postgres://tasks:change-me@db.example.org:5432/tasks?sslmode=require`. Also read by the migrate step. On the platform it ends in `?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt`, because the platform's PostgreSQL accepts only TLS connections. |
| `SHUTDOWN_TIMEOUT` | `15s` | no | no | How long a stopping backend waits for requests to finish. |
| `CORS_ALLOWED_ORIGINS` | `http://localhost:3009` | no | no | Comma-separated browser origins allowed to call the API. |
| `TRUSTED_PROXY_CIDRS` | `10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,127.0.0.0/8,::1/128,fc00::/7` | no | no | Comma-separated CIDRs of the proxies in front of the API (Gateway, nginx, Caddy). `X-Forwarded-For` is only believed on connections from these addresses; the resulting client IP is what rate limits count. Add a proxy that sits outside the private ranges; `none` trusts no proxy. See [Client IP addresses](../../operations/production.md#client-ip-addresses). |
| `AUTH_MODE` | `oidc` | no | no | `oidc` signs people in through the identity provider (then `OIDC_ISSUER_URL` is required). `dev` trusts `X-Dev-User`/`X-Dev-Groups` headers: **local development only**, and only accepted with `APP_ENV=development`; anywhere else the backend refuses to start. Outside dev mode the backend drops both headers from every request and leaves them out of CORS. With neither variable set the backend is production with OIDC and refuses to start until OIDC is configured (it fails closed). |
| `OIDC_ISSUER_URL` | none | with `oidc` | no | Issuer, for example `https://auth.example.org/realms/conservices`. |
| `OIDC_AUDIENCE` | `tasks-api` | no | no | The audience (`aud`) every access token must carry. The Keycloak audience mapper on the `tasks-spa` client adds `tasks-api` to access tokens; ID tokens are refused. See [Token contract](../../concepts/authentication.md). The backend no longer reads `OIDC_CLIENT_ID`. |
| `OIDC_GROUPS_CLAIM` | `groups` | no | no | The token claim that holds the person's groups. Groups come only from this claim; Keycloak realm roles are not merged in. |
| `OIDC_GROUP_MATCH` | `full` | no | no | How groups match access-config bindings and group grants: `full` (the whole path, `/departments/ops` matches `departments/ops` but not `ops`) or `last` (only the last path segment). See [How groups are matched](../../concepts/authentication.md#how-groups-are-matched). |
| `OIDC_GROUP_PREFIX` | none | no | no | A parent group removed before matching, for example `/con2026`, so `/con2026/departments/ops` matches a grant to `departments/ops`. Stored grants do not change when you set it. |
| `HR_SERVICE_TOKEN` | none | for HR | **yes** | Bearer token HR's backend sends to read [`GET /api/role-catalog`](api.md#role-catalog); one value per installation, the same in HR and every module. Empty: only signed-in people can read the catalog. Generate with `openssl rand -hex 32`. See [Secrets](../../operations/secrets.md). |
| `ACCESS_CONFIG_PATH` | none | in production | no | Path of the [access config file](#access-config-file). Without it the built-in catalog is used. |
| `DEV_DEFAULT_USER` | `dev-admin` | no | no | `dev` mode only: user when no header is sent. |
| `DEV_DEFAULT_GROUPS` | `tasks-admin` | no | no | `dev` mode only: groups when no header is sent. |
| `DEN_INTERNAL_URL` | none | no | no | Den's in-cluster address, on the platform `https://den-backend.conservices-den.svc.cluster.local:8080`; replaces the host of pasted pairing URLs. Empty without Den. |
| `DEN_ALLOWED_HOSTS` | none | no | no | Comma-separated hosts a pasted pairing URL may point at (`den.example.org`, `*.example.org`). Not needed while `DEN_INTERNAL_URL` is set. With neither set, pairing is refused outside development; in development `localhost`, `127.0.0.1`, `::1` and `*.conservices.test` are always allowed. |
| `DEN_LINK_ENCRYPTION_KEY` | none | **yes**, unless `APP_ENV=development` | **yes** | Encrypts the credential Den issues to Tasks before it is stored in the database: base64 of 32 random bytes (`openssl rand -base64 32`). Without it the backend refuses to start outside development. Losing it means pairing again. See [Secrets](../../operations/secrets.md). |
| `DEN_LINK_ENCRYPTION_KEY_PREVIOUS` | none | no | **yes** | The old key during a rotation: Tasks still reads a credential sealed with it and re-seals it with `DEN_LINK_ENCRYPTION_KEY` the first time it uses the link. Remove it once the backend log shows `den link: re-encrypted the stored credential with the current key`. A credential stored before encryption existed is re-sealed the same way. |
| `DEN_MODE` | `standalone` | no | no | `required`: until the module is paired with Den, its API answers `503 den_pairing_required` and the web app shows *Waiting for Den* (admins: *Connect this module to Den*). `standalone`: the module works without Den; pairing is optional. Kubernetes sets `required` (Helm: `den.mode`); Docker Compose sets `standalone`. See [Required or standalone](../../concepts/pairing.md#required-or-standalone). |
| `BRAND_LOCAL_PATH` | none | no | no | Optional `brand.json` while not paired. |
| `TASKS_SERVICE_TOKEN` | none | for HR | **yes** | Bearer token HR uses for `POST /api/internal/departments`. **Empty turns the endpoint off** (`404`). Must equal the token in HR's `DEPARTMENT_HOOKS`. Generate with `openssl rand -hex 32`. |
| `S3_ENDPOINT` | none | no | no | S3 address for attachments, on the platform `https://s3.conservices-data.svc.cluster.local:9000`. **Empty turns attachments off** (`503`). |
| `S3_BUCKET` | `tasks-data-dev` | no | no | Bucket for attachments. Add it to the Den operator's `FILES_S3_BUCKETS`. |
| `S3_ACCESS_KEY_ID` | none | with S3 | **yes** | Key for the bucket. |
| `S3_SECRET_ACCESS_KEY` | none | with S3 | **yes** | Secret for the key. |
| `S3_REGION` | `us-east-1` | no | no | Region of the bucket. |
| `S3_USE_PATH_STYLE` | `true` | no | no | `true` for the local S3 server (SeaweedFS) and most self-hosted S3. |
| `TASKS_PUBLIC_URL` | none | no | no | The web app's address, for example `https://tasks.example.org`; links in notification emails point there. Empty: emails name the task key without a link. |
| `SMTP_HOST` | none | no | no | Mail server for [email notifications](#email) when Den sends none. Empty: no email unless Den provides SMTP. |
| `SMTP_PORT` | `587` (`465` with `tls`) | no | no | Port of the mail server. |
| `SMTP_USERNAME` | none | no | **yes** | Login, if the server needs one. |
| `SMTP_PASSWORD` | none | no | **yes** | Password for `SMTP_USERNAME`. See [Secrets](../../operations/secrets.md). |
| `SMTP_FROM` | none | with `SMTP_HOST` | no | Sender address, for example `tasks@example.org`. |
| `SMTP_FROM_NAME` | `Tasks` | no | no | Sender name. |
| `SMTP_SECURITY` | `starttls` | no | no | `starttls` (upgrade a plain connection; refuses servers without STARTTLS), `tls` (TLS from the start, usually port 465), or `none` (plain; **only** for a local mail catcher such as Mailpit). Anything else stops the backend. |

## Email

Tasks emails people about their Inbox notifications, if they want it
(*Inbox → Email settings*; by default for assignments, mentions and
due-soon reminders). Notifications wait two minutes and go out bundled,
one email per person with up to 20 notifications; anything read in the
app meanwhile is not emailed.

**Which mail server is used:**

1. When Tasks is paired with Den and Den's integration bundle contains
   SMTP settings, those (see [Settings from Den](#settings-from-den)).
2. Otherwise the `SMTP_*` variables above.
3. Otherwise no email; notifications stay in the Inbox.

To set up Tasks' own server:

1. Put the login in your secret manager and expose it as `SMTP_USERNAME`
   and `SMTP_PASSWORD` in the Secret `tasks-secrets`.
2. Set the rest in Helm values:

    ```yaml
    config:
      SMTP_HOST: smtp.example.org
      SMTP_PORT: "587"
      SMTP_FROM: tasks@example.org
      SMTP_SECURITY: starttls
      TASKS_PUBLIC_URL: https://tasks.example.org
    networkPolicy:
      smtp:
        cidrs: ["203.0.113.25/32"]   # the mail server's address
        port: 587
    ```

3. Restart the backend. It logs `own SMTP configured`.
4. Sign in as a Tasks admin, open *Settings*, and press **Send a test email
   to me**. You should get "[Tasks] Test email" within a minute.

For local development, run Mailpit and set `SMTP_HOST=mailpit` (or
`host.docker.internal`), `SMTP_PORT=1025`, `SMTP_SECURITY=none`; mails show
in Mailpit's web UI.

### Troubleshooting email

- **Test email: `409 email is not configured`.** Neither Den nor `SMTP_HOST`
  provides a server. Check `GET /api/v1/settings` → `email.source`.
- **Test email: `503 … smtp dial … i/o timeout`.** The NetworkPolicy blocks
  the mail server: set `networkPolicy.smtp.cidrs`.
- **`smtp: the server does not offer STARTTLS`.** Use `SMTP_SECURITY=tls`
  with port 465, or ask the provider for a STARTTLS port.
- **`smtp auth: 535`.** Wrong `SMTP_USERNAME` or `SMTP_PASSWORD`.
- **Test works, people get nothing.** They have no address in their
  sign-in token (`has_address: false` in `GET /api/v1/me/notifications`),
  switched email off, or read the notification in the app within two
  minutes.

## Settings from Den

Retention and reminders are module settings. An admin changes them on
*Settings* in Tasks (stored in Tasks' database, audit-logged), or, when
Tasks is paired, in Den's module settings. **A value Den sends wins** and
is shown as "set in Den" (read-only in Tasks).

| Setting | Default | What it does (`0` = keep forever / off) |
| --- | --- | --- |
| `retention.trash_days` | 30 | Deleted tasks stay in the trash this long, then are purged with their attachment files. |
| `retention.notification_days` | 90 | Read Inbox notifications are kept this long. |
| `retention.audit_days` | 730 | Audit log entries are kept this long. |
| `retention.automation_run_days` | 90 | Automation run history is kept this long. |
| `reminders.due_soon_days` | 1 | Assignees are reminded this many days before a due date and on the day. |

!!! warning "Pending legal review"
    The retention defaults are placeholders, not legal advice. Set what your
    organisation's data-protection rules require.

What Tasks reads from Den's integration bundle (`GET
/api/v1/integrations/bundle`, synced every minute while paired):

```json
{
  "brand": {"…": "…"},
  "settings": {"data": {"…": "…"}},
  "module_settings": {
    "retention": {"trash_days": 30, "notification_days": 90, "audit_days": 730, "automation_run_days": 90},
    "reminders": {"due_soon_days": 1}
  },
  "smtp": {"host": "smtp.example.org", "port": 587, "username": "tasks", "password": "change-me",
           "from": "tasks@example.org", "from_name": "Tasks", "security": "starttls"}
}
```

Missing keys fall back to Tasks' own values; values outside a setting's
range are ignored. The retention job runs every hour, reminders every 15
minutes, the email outbox every minute (one backend replica runs them all;
see [ADR 0001](https://github.com/AGlElectronics/tasks/blob/main/docs/adr/0001-single-backend-replica.md)).

## Internal TLS

On Kubernetes, Tasks' backend serves HTTPS inside the cluster and checks
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
| `SSL_CERT_DIR` | none (system CAs only) | on Kubernetes | no | Standard Go setting: folders of extra CA certificates the backend trusts when it calls PostgreSQL, S3, Den and the identity provider. Separate several folders with `:`. On Kubernetes `/etc/conservices-internal-ca` (the platform's internal CA, set by the chart); the local example overlay uses `/etc/conservices-internal-ca:/etc/conservices-ca` to trust mkcert's root as well. Without it, calls fail with `x509: certificate signed by unknown authority`. |

With TLS on, the backend logs `tls enabled` at start, with the
certificate's expiry date in `not_after`. If a later re-read fails, it logs
`tls certificate reload failed; keeping the current one` and keeps serving
the old certificate. The minimum protocol version is TLS 1.2.

## Web app settings (config.json)

The `tasks-frontend` image names no domain, so one published image works for
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
| `oidcClientId` | `""` | The public client the web app signs in with: `tasks-spa`. Required with `"oidc"`. |
| `oidcScope` | `"openid profile email"` | Scopes requested at sign-in. |
| `apiBaseUrl` | `""` | Address put in front of every API call (`/api/...`). Leave empty: nginx serves the app and forwards `/api/` on the same address. Only set it when the API lives on another origin, for example `https://api.example.org`. |
| `productName` | `""` (shows `Tasks`) | Name shown until Den's brand has loaded. |

Keys you leave out keep their default; unknown keys are ignored. The image
ships a placeholder file with empty `oidcAuthority` and `oidcClientId`: the
web app then shows **Not configured yet** instead of a sign-in page.

Example for `tasks.example.org`:

```json
{
  "authMode": "oidc",
  "oidcAuthority": "https://auth.example.org/realms/conservices",
  "oidcClientId": "tasks-spa",
  "oidcScope": "openid profile email",
  "apiBaseUrl": "",
  "productName": "Tasks"
}
```

### How to set it

1. **Helm:** set `frontend.config` in your values. Keys you leave out are
   filled in from the chart's other values: `authMode` from `config.AUTH_MODE`, `oidcAuthority` from `config.OIDC_ISSUER_URL`, `oidcClientId` from `config.OIDC_CLIENT_ID` (else `tasks-spa`), `productName` `Tasks`,
   `oidcScope` `openid profile email` and `apiBaseUrl` empty. So with the
   usual `config.OIDC_ISSUER_URL` you often need nothing extra. The chart
   writes the file to the ConfigMap `<release>-frontend-config` and restarts
   the web app pods when it changes.

   ```yaml
   frontend:
     config:
       oidcAuthority: https://auth.example.org/realms/conservices
       oidcClientId: tasks-spa
   ```

2. **Docker Compose:** the module's `infra/docker-compose.yml` mounts
   `infra/frontend-config/compose.json` (dev sign-in). For real sign-in, copy
   it, fill in the keys and set `FRONTEND_CONFIG` (a path relative to
   `infra/`) in `.env`. The full platform stack (root `docker-compose.yml`)
   mounts `infra/frontend-config/tasks.json`.
3. **Plain Docker:** mount the file read-only:

   ```sh
   docker run --rm -p 3000:8080 \
     -v "$PWD/config.json:/etc/conservices/config.json:ro" \
     ghcr.io/aglelectronics/tasks-frontend:1.0.0-1
   ```

Check what the browser gets:

```sh
curl -i https://tasks.example.org/config.json
```

```text
HTTP/2 200
content-type: application/json
cache-control: no-store

{
  "authMode": "oidc",
  "oidcAuthority": "https://auth.example.org/realms/conservices",
  "oidcClientId": "tasks-spa",
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

### Sign-in tokens

The web app keeps its tokens **in memory only** (the
[token contract](../../concepts/authentication.md)): nothing is written to
`localStorage` or `sessionStorage`. After a reload or in a new tab it signs
in again silently through the Keycloak session, in a hidden frame
(`/silent-callback.html`), so people are not asked to log in again while
their Keycloak session lasts. It sends the **access token** to the API;
the backend accepts it only with the audience `tasks-api`. Tabs tell each
other who is signed in over a `BroadcastChannel` that carries only the user
id: signing out in one tab signs out every tab.

## Web app security headers

nginx in the `tasks-frontend` image sends the shared Con Services browser
security headers (Content-Security-Policy, `X-Frame-Options`,
`X-Content-Type-Options`, `Referrer-Policy`, `Permissions-Policy`) on the
pages and files of the web app. `/api/` responses come from the backend,
which sets its own stricter headers. The image fills in the origins the
browser may reach from these variables of the **web app container** when it
starts:

| Variable | Default | Required | What it does |
| --- | --- | --- | --- |
| `KEYCLOAK_ORIGIN` | none | with OIDC sign-in | The sign-in server's origin, for example `https://auth.example.org` (scheme, host, optional port; no path). Without it sign-in and silent renewal are blocked. The Helm chart sets it from `frontend.securityHeaders.keycloakOrigin`, else from the issuer URL. |
| `DEN_ORIGIN` | none | no | Den's origin, only if the browser calls Den itself. Tasks serves Den's brand through its own API, so leave it empty. |
| `S3_ORIGIN` | none | no | Only for direct browser uploads to S3. Tasks uploads through its backend, so leave it empty. |
| `EXTRA_CONNECT_SRC` | none | no | Any other origin the browser must call. |

Check the result:

```sh
curl -sI https://tasks.example.org/ | grep -i -E 'content-security|x-frame|permissions'
```

```text
content-security-policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob: ; font-src 'self' data:; connect-src 'self' https://auth.example.org   ; frame-src 'self' https://auth.example.org; frame-ancestors 'none'; form-action 'self' https://auth.example.org; base-uri 'self'; object-src 'none'
x-frame-options: DENY
permissions-policy: camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()
```

The live-update stream (`/api/v1/stream`) is proxied without these headers
and without buffering, as before. Details and troubleshooting:
[nginx security headers](../../concepts/shared-code.md#nginx-security-headers).

## Frontend build settings

Docker build arguments of `infra/Dockerfile.frontend`. None of them is
installation-specific; the sign-in settings live in `/config.json` (above).

| Build argument | Default | What it does |
| --- | --- | --- |
| `TASKS_VERSION` | `dev` | Version shown in the app. |
| `NGINX_CONF` | `nginx.conf` | Which file from `infra/` becomes the image's nginx config. The Helm chart (and the Kustomize manifests) mount their own. |

```sh
docker build -f infra/Dockerfile.frontend \
  --build-arg TASKS_VERSION=1.0.0 \
  -t registry.example.org/conservices/tasks-frontend:1.0.0-1 .
```

The local dev server (`npm run dev`) has no `/config.json`; it uses
`VITE_AUTH_MODE`, `VITE_OIDC_AUTHORITY`, `VITE_OIDC_CLIENT_ID`, `VITE_OIDC_SCOPE`, `VITE_API_BASE_URL` (for example `http://localhost:8160`), `VITE_PRODUCT_NAME` from the environment or `.env` instead. Image builds
ignore these.


## Access config file

Read once at start (restart after editing). Roles and their permissions:

| Keycloak group | Role | Permissions |
| --- | --- | --- |
| `tasks-admin` | `organization_admin` | `space.manage` (every space), `space.create`, `settings.manage` (Den connection) |
| `tasks-creator` | `space_creator` | `space.create` (new spaces, and manage the ones you created) |

Working on tasks is not a role: it comes from sharing spaces and lists
inside Tasks. See the [Admin guide](admin-guide.md#sharing).

Group names in grants are matched case-insensitively, with one leading `/`
ignored and the whole path compared, the same rule every Con Services
module uses (see the [API reference](api.md#sharing-grants)).
