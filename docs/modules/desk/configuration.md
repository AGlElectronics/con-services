# Desk configuration reference

Desk is configured through **environment variables**. The backend and the
migrate step read a `.env` file in their working directory if one exists,
then the real environment (which wins). The repository's
[`.env.example`](https://github.com/AGlElectronics/desk/blob/main/.env.example)
lists the basics for local development. An empty value counts as not set.
The backend checks its settings at start and refuses to start with a list
of every problem.

## Where the settings live on Kubernetes

| Kubernetes object | Holds |
| --- | --- |
| ConfigMap `<release>-config` (from `values.yaml` `config:`) | Every setting below that is not a secret. The chart adds `ACCESS_CONFIG_PATH`. |
| Secret `desk-secrets` (`existingSecret`, from your secret manager) | `DATABASE_URL`, `DESK_SECRET_KEY`, and `SMTP_PASSWORD` if the fallback SMTP server needs one. |
| ConfigMap `desk-access-config` | The access config file. |
| Secrets `desk-backend-tls`, `desk-frontend-tls` (from cert-manager) | The pods' internal TLS certificates (`tls.crt`, `tls.key`, `ca.crt`), mounted at `/etc/conservices-tls`. See [Internal TLS](#internal-tls). |
| ConfigMap `conservices-internal-ca` (from trust-manager) | The platform's internal CA (`ca.crt`), mounted at `/etc/conservices-internal-ca`. |

## Backend

| Variable | Default | Required | Secret | What it does |
| --- | --- | --- | --- | --- |
| `APP_ENV` | `development` | no | no | `production` on real installations. |
| `APP_BASE_URL` | `http://localhost:8080` | no | no | Public address, for example `https://desk.example.org`. |
| `HTTP_ADDR` | `:8080` | no | no | Listen address inside the container. |
| `DATABASE_URL` | none | **yes** | **yes** | PostgreSQL URL. Also read by the migrate step. On the platform it ends in `?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt`, because the platform's PostgreSQL accepts only TLS connections. |
| `SHUTDOWN_TIMEOUT` | `15s` | no | no | How long a stopping backend waits for requests. |
| `CORS_ALLOWED_ORIGINS` | `http://localhost:3008` | no | no | Comma-separated browser origins. |
| `TRUSTED_PROXY_CIDRS` | `10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,127.0.0.0/8,::1/128,fc00::/7` | no | no | Comma-separated CIDRs of the proxies in front of the API (Gateway, nginx, Caddy). `X-Forwarded-For` is only believed on connections from these addresses; the resulting client IP is what rate limits count. Add a proxy that sits outside the private ranges; `none` trusts no proxy. See [Client IP addresses](../../operations/production.md#client-ip-addresses). |
| `AUTH_MODE` | `dev` | no | no | `oidc` for real sign-in; `dev` trusts `X-Dev-User`/`X-Dev-Groups` headers (local only). |
| `OIDC_ISSUER_URL` | none | with `oidc` | no | Issuer URL. |
| `OIDC_CLIENT_ID` | none | with `oidc` | no | `desk-spa`. |
| `OIDC_AUDIENCE` | none | no | no | Normally `desk-spa`. |
| `ACCESS_CONFIG_PATH` | none | in production | no | Path of the [access config file](#access-config-file). |
| `DEV_DEFAULT_USER` | `dev-admin` | no | no | `dev` mode only. |
| `DEV_DEFAULT_GROUPS` | `desk-admin` | no | no | `dev` mode only. |
| `DEN_INTERNAL_URL` | none | no | no | Den's in-cluster address for pairing (platform: `https://den-backend.conservices-den.svc.cluster.local:8080`); empty without Den. |
| `DEN_MODE` | `standalone` | no | no | `required`: until the module is paired with Den, its API answers `503 den_pairing_required` and the web app shows *Waiting for Den* (admins: *Connect this module to Den*). `standalone`: the module works without Den; pairing is optional. Kubernetes sets `required` (Helm: `den.mode`); Docker Compose sets `standalone`. See [Required or standalone](../../concepts/pairing.md#required-or-standalone). |
| `BRAND_LOCAL_PATH` | none | no | no | Optional `brand.json` while not paired. |
| `DESK_SECRET_KEY` | a fixed development key, **only** with `APP_ENV=development` | **yes** outside development | **yes** | Encrypts the IMAP and SMTP passwords stored per mailbox (AES-GCM; any length, hashed to a 256-bit key). Generate with `openssl rand -hex 32`. **Changing it makes stored mailbox passwords unreadable**; they must then be entered again. |
| `FETCH_INTERVAL` | `60s` | no | no | How often every mailbox is polled over IMAP. |
| `SMTP_HOST` | none | no | no | Fallback SMTP server for mailboxes without their own. Empty: such mailboxes cannot send. |
| `SMTP_PORT` | `587` | no | no | Fallback SMTP port. |
| `SMTP_SECURITY` | `starttls` | no | no | `tls`, `starttls` or `none` (none only for test servers). Anything else stops the backend from starting. |
| `SMTP_USERNAME` | none | no | no | Fallback SMTP login. |
| `SMTP_PASSWORD` | none | no | **yes** | Fallback SMTP password. |

Per-mailbox IMAP and SMTP servers, logins and passwords are not environment
variables; admins set them in the app under **Mailboxes**.

## Internal TLS

On Kubernetes, Desk's backend serves HTTPS inside the cluster and checks
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
| `SSL_CERT_DIR` | none (system CAs only) | on Kubernetes | no | Standard Go setting: folders of extra CA certificates the backend trusts when it calls PostgreSQL, Den and the identity provider. Separate several folders with `:`. On Kubernetes `/etc/conservices-internal-ca` (the platform's internal CA, set by the chart); the local example overlay uses `/etc/conservices-internal-ca:/etc/conservices-ca` to trust mkcert's root as well. Without it, calls fail with `x509: certificate signed by unknown authority`. |

Setting `SSL_CERT_DIR` does not remove the public CAs: Go still reads the
image's system bundle (`/etc/ssl/certs/ca-certificates.crt`), so IMAP and
SMTP connections to public mail providers keep working.

With TLS on, the backend logs `tls enabled` at start, with the
certificate's expiry date in `not_after`. If a later re-read fails, it logs
`tls certificate reload failed; keeping the current one` and keeps serving
the old certificate. The minimum protocol version is TLS 1.2.

## Web app settings (config.json)

The `desk-frontend` image names no domain, so one published image works for
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
| `oidcClientId` | `""` | The public client the web app signs in with: `desk-spa`. Required with `"oidc"`. |
| `oidcScope` | `"openid profile email"` | Scopes requested at sign-in. |
| `apiBaseUrl` | `""` | Address put in front of every API call (`/api/...`). Leave empty: nginx serves the app and forwards `/api/` on the same address. Only set it when the API lives on another origin, for example `https://api.example.org`. |
| `productName` | `""` (shows `Desk`) | Name shown until Den's brand has loaded. |

Keys you leave out keep their default; unknown keys are ignored. The image
ships a placeholder file with empty `oidcAuthority` and `oidcClientId`: the
web app then shows **Not configured yet** instead of a sign-in page.

Example for `desk.example.org`:

```json
{
  "authMode": "oidc",
  "oidcAuthority": "https://auth.example.org/realms/conservices",
  "oidcClientId": "desk-spa",
  "oidcScope": "openid profile email",
  "apiBaseUrl": "",
  "productName": "Desk"
}
```

### How to set it

1. **Helm:** set `frontend.config` in your values. Keys you leave out are
   filled in from the chart's other values: `authMode` from `config.AUTH_MODE`, `oidcAuthority` from `config.OIDC_ISSUER_URL`, `oidcClientId` from `config.OIDC_CLIENT_ID` (else `desk-spa`), `productName` `Desk`,
   `oidcScope` `openid profile email` and `apiBaseUrl` empty. So with the
   usual `config.OIDC_ISSUER_URL` you often need nothing extra. The chart
   writes the file to the ConfigMap `<release>-frontend-config` and restarts
   the web app pods when it changes.

   ```yaml
   frontend:
     config:
       oidcAuthority: https://auth.example.org/realms/conservices
       oidcClientId: desk-spa
   ```

2. **Docker Compose:** the module's `infra/docker-compose.yml` mounts
   `infra/frontend-config/compose.json` (dev sign-in). For real sign-in, copy
   it, fill in the keys and set `FRONTEND_CONFIG` (a path relative to
   `infra/`) in `.env`. The full platform stack (root `docker-compose.yml`)
   mounts `infra/frontend-config/desk.json`.
3. **Plain Docker:** mount the file read-only:

   ```sh
   docker run --rm -p 3000:8080 \
     -v "$PWD/config.json:/etc/conservices/config.json:ro" \
     ghcr.io/aglelectronics/desk-frontend:1.0.0-1
   ```

Check what the browser gets:

```sh
curl -i https://desk.example.org/config.json
```

```text
HTTP/2 200
content-type: application/json
cache-control: no-store

{
  "authMode": "oidc",
  "oidcAuthority": "https://auth.example.org/realms/conservices",
  "oidcClientId": "desk-spa",
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
| `DESK_VERSION` | `dev` | Version shown in the app. |
| `NGINX_CONF` | `nginx.conf` | Which file from `infra/` becomes the image's nginx config. The Helm chart (and the Kustomize manifests) mount their own. |

```sh
docker build -f infra/Dockerfile.frontend \
  --build-arg DESK_VERSION=1.0.0 \
  -t registry.example.org/conservices/desk-frontend:1.0.0-1 .
```

The local dev server (`npm run dev`) has no `/config.json`; it uses
`VITE_AUTH_MODE`, `VITE_OIDC_AUTHORITY`, `VITE_OIDC_CLIENT_ID`, `VITE_OIDC_SCOPE`, `VITE_API_BASE_URL` (for example `http://localhost:8150`), `VITE_PRODUCT_NAME` from the environment or `.env` instead. Image builds
ignore these.


## Access config file

| Keycloak group | Role | Permissions |
| --- | --- | --- |
| `desk-admin` | `organization_admin` | `tickets.work`, `mailbox.manage`, `settings.manage` |
| `desk-agent` | `agent` | `tickets.work` |

| Permission | Allows |
| --- | --- |
| `tickets.work` | Read and work conversations in **every** mailbox (per-mailbox access is planned). |
| `mailbox.manage` | Create, edit, test, fetch and delete mailboxes. |
| `settings.manage` | The Den connection. |
