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

## Backend

| Variable | Default | Required | Secret | What it does |
| --- | --- | --- | --- | --- |
| `APP_ENV` | `development` | no | no | `production` on real installations. |
| `APP_BASE_URL` | `http://localhost:8080` | no | no | Public address, for example `https://desk.example.org`. |
| `HTTP_ADDR` | `:8080` | no | no | Listen address inside the container. |
| `DATABASE_URL` | none | **yes** | **yes** | PostgreSQL URL. Also read by the migrate step. |
| `SHUTDOWN_TIMEOUT` | `15s` | no | no | How long a stopping backend waits for requests. |
| `CORS_ALLOWED_ORIGINS` | `http://localhost:3008` | no | no | Comma-separated browser origins. |
| `AUTH_MODE` | `dev` | no | no | `oidc` for real sign-in; `dev` trusts `X-Dev-User`/`X-Dev-Groups` headers (local only). |
| `OIDC_ISSUER_URL` | none | with `oidc` | no | Issuer URL. |
| `OIDC_CLIENT_ID` | none | with `oidc` | no | `desk-spa`. |
| `OIDC_AUDIENCE` | none | no | no | Normally `desk-spa`. |
| `ACCESS_CONFIG_PATH` | none | in production | no | Path of the [access config file](#access-config-file). |
| `DEV_DEFAULT_USER` | `dev-admin` | no | no | `dev` mode only. |
| `DEV_DEFAULT_GROUPS` | `desk-admin` | no | no | `dev` mode only. |
| `DEN_INTERNAL_URL` | none | no | no | Den's in-cluster address for pairing; empty without Den. |
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

## Frontend build settings

Compiled into the `desk-frontend` image at **build** time:

| Build argument | Default | What it does |
| --- | --- | --- |
| `VITE_AUTH_MODE` | `dev` | `oidc` for real sign-in. |
| `VITE_OIDC_AUTHORITY` | none | Issuer URL. |
| `VITE_OIDC_CLIENT_ID` | none | `desk-spa`. |
| `VITE_OIDC_SCOPE` | `openid profile email` | Scopes. |
| `VITE_API_BASE_URL` | empty | Leave empty behind nginx. |
| `VITE_PRODUCT_NAME` | `Desk` | Name shown before Den's brand loads. |
| `NGINX_CONF` | `nginx.conf` | nginx config baked into the image (the Helm chart replaces it). |

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
