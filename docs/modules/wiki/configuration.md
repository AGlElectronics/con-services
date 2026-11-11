# Wiki configuration reference

Wiki is configured entirely through **environment variables**. The backend
and the migrate step read a `.env` file in their working directory if one
exists, then the real environment (which wins). The repository's
[`.env.example`](https://github.com/AGlElectronics/wiki/blob/main/.env.example)
lists them for local development.

An empty value counts as not set, so the default applies. The backend
checks its settings at start and refuses to start with a list of every
problem, for example:

```text
invalid config: DATABASE_URL is required; OIDC_CLIENT_ID is required when AUTH_MODE=oidc
```

## Where the settings live on Kubernetes

The Helm chart (`deploy/charts/wiki`) puts plain settings from `values.yaml`
`config:` into the ConfigMap `<release>-config`, and reads secrets from the
Secret named in `existingSecret` (default `wiki-secrets`), which your secret
manager creates (see [Secrets](../../operations/secrets.md)). The chart sets
`ACCESS_CONFIG_PATH` itself from `accessConfig`.

| Kubernetes object | Holds |
| --- | --- |
| ConfigMap `<release>-config` | Everything below marked "no" in the Secret column. |
| Secret `wiki-secrets` | `DATABASE_URL`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `WIKI_SERVICE_TOKEN`; optionally `HR_DIRECTORY_TOKEN` or `IDP_DIRECTORY_CLIENT_SECRET` for the [group picker](#group-picker). |
| ConfigMap `wiki-access-config` | The access config file (roles and group bindings). |
| Secrets `wiki-backend-tls`, `wiki-frontend-tls` (from cert-manager) | The pods' internal TLS certificates (`tls.crt`, `tls.key`, `ca.crt`), mounted at `/etc/conservices-tls`. See [Internal TLS](#internal-tls). |
| ConfigMap `conservices-internal-ca` (from trust-manager) | The platform's internal CA (`ca.crt`), mounted at `/etc/conservices-internal-ca`. |

After changing a Secret, restart the backend:
`kubectl rollout restart -n conservices-wiki deploy/wiki-backend`.
ConfigMap changes made through `helm upgrade` restart it automatically.

## Backend

### Core and database

| Variable | Default | Required | Secret | What it does |
| --- | --- | --- | --- | --- |
| `APP_ENV` | `development` | no | no | `production` on real installations. `development` makes logs human-readable. |
| `APP_BASE_URL` | `http://localhost:8080` | no | no | Public address of Wiki, for example `https://wiki.example.org`. |
| `HTTP_ADDR` | `:8080` | no | no | Address the backend listens on inside the container. Keep `:8080`. |
| `DATABASE_URL` | none | **yes** | **yes** | PostgreSQL connection URL, for example `postgres://wiki:change-me@db.example.org:5432/wiki?sslmode=require`. Also read by the migrate step. On the platform it ends in `?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt`, because the platform's PostgreSQL accepts only TLS connections. |
| `SHUTDOWN_TIMEOUT` | `15s` | no | no | How long a stopping backend waits for requests to finish. Give the pod at least 30 s on top for live editing. |
| `CORS_ALLOWED_ORIGINS` | `http://localhost:3007` | no | no | Comma-separated browser origins allowed to call the API, for example `https://wiki.example.org`. |
| `TRUSTED_PROXY_CIDRS` | `10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,127.0.0.0/8,::1/128,fc00::/7` | no | no | Comma-separated CIDRs of the proxies in front of the API (Gateway, nginx, Caddy). `X-Forwarded-For` is only believed on connections from these addresses; the resulting client IP is what rate limits count. Add a proxy that sits outside the private ranges; `none` trusts no proxy. See [Client IP addresses](../../operations/production.md#client-ip-addresses). |

### Sign-in

| Variable | Default | Required | Secret | What it does |
| --- | --- | --- | --- | --- |
| `AUTH_MODE` | `dev` | no | no | `oidc` checks real sign-in tokens. `dev` trusts the `X-Dev-User` and `X-Dev-Groups` headers: **local development only**, anyone can claim to be anyone. |
| `OIDC_ISSUER_URL` | none | with `oidc` | no | The sign-in server's issuer, for example `https://auth.example.org/realms/conservices`. The backend must reach it (OIDC discovery). |
| `OIDC_CLIENT_ID` | none | with `oidc` | no | Client the tokens are issued for: `wiki-spa`. |
| `OIDC_AUDIENCE` | none | no | no | Expected token audience, normally `wiki-spa`. |
| `ACCESS_CONFIG_PATH` | none | in production | no | Path of the access config file (roles and Keycloak group bindings), for example `/etc/wiki/access-config.toml`. Without it the built-in catalog is used. The Helm chart sets it. |
| `DEV_DEFAULT_USER` | `dev-admin` | no | no | `dev` mode only: user when no `X-Dev-User` header is sent. |
| `DEV_DEFAULT_GROUPS` | `wiki-admin` | no | no | `dev` mode only: comma-separated groups when no `X-Dev-Groups` header is sent. |

### Den and branding

| Variable | Default | Required | Secret | What it does |
| --- | --- | --- | --- | --- |
| `DEN_INTERNAL_URL` | none | no | no | Den's address as the backend reaches it, on the platform `https://den-backend.conservices-den.svc.cluster.local:8080`. Replaces the host of a pasted pairing URL. Empty without Den. See [Pairing](../../concepts/pairing.md). |
| `DEN_MODE` | `standalone` | no | no | `required`: until the module is paired with Den, its API answers `503 den_pairing_required` and the web app shows *Waiting for Den* (admins: *Connect this module to Den*). `standalone`: the module works without Den; pairing is optional. Kubernetes sets `required` (Helm: `den.mode`); Docker Compose sets `standalone`. See [Required or standalone](../../concepts/pairing.md#required-or-standalone). |
| `BRAND_LOCAL_PATH` | none | no | no | Optional `brand.json` used while Wiki is not paired. Once paired, Den's brand wins. |

### Storage and live editing

| Variable | Default | Required | Secret | What it does |
| --- | --- | --- | --- | --- |
| `S3_ENDPOINT` | none | in practice yes | no | S3 address, for example `https://fsn1.your-objectstorage.com`, or on the platform `https://s3.conservices-data.svc.cluster.local:9000`. **Empty turns storage off**: live editing, uploads, history and duplication answer `503`. Set but unreachable: the backend refuses to start. |
| `S3_BUCKET` | `wiki-data-dev` | no | no | Bucket for page content and uploads. Created on start if the keys allow it. Add it to the Den operator's `FILES_S3_BUCKETS`. |
| `S3_ACCESS_KEY_ID` | none | with S3 | **yes** | Key for the bucket. |
| `S3_SECRET_ACCESS_KEY` | none | with S3 | **yes** | Secret for the key. |
| `S3_REGION` | `us-east-1` | no | no | Region of the bucket. |
| `S3_USE_PATH_STYLE` | `true` | no | no | `true` for the local S3 server (SeaweedFS) and most self-hosted S3; `false` for AWS virtual-hosted addresses. |
| `WIKI_BUFFER_DIR` | `./data/buffer` | no | no | Directory for the last few seconds of live edits before they are shipped to S3. Put it on a volume; the images use `/var/lib/wiki/buffer`. One backend replica owns it. |
| `WIKI_REVISION_RETENTION_DAYS` | `0` | no | no | Page history: revisions older than this many days are deleted, every hour, from S3 and the database. `0` keeps every revision. Once paired, Den's module settings override it; see [Revision retention](#revision-retention). A negative number stops the backend at start. |

### Sharing and offboarding

| Variable | Default | Required | Secret | What it does |
| --- | --- | --- | --- | --- |
| `PUBLIC_LINKS_ENABLED` | `false` | no | no | Allows public share links while Wiki is **not paired**. Once paired, Den's organisation setting `wiki_public_links` decides. |
| `WIKI_SERVICE_TOKEN` | none | for HR | **yes** | Bearer token HR uses for `POST /api/internal/offboarded`. **Empty turns that endpoint off** (it answers `404`). Must equal the token in HR's `OFFBOARD_HOOKS`. Generate with `openssl rand -hex 32`. |
| `WIKI_OFFBOARD_GRACE_DAYS` | `30` | no | no | Days an offboarded person's private space stays (visible to Wiki admins) before an hourly sweep deletes it. |
| `HR_DIRECTORY_URL` | none | no | no | HR's backend address, for example `https://hr-backend.conservices-hr.svc.cluster.local:8080`. While Wiki is paired with Den, the group picker lists HR's departments and access groups from it. See [Group picker](#group-picker). |
| `HR_DIRECTORY_TOKEN` | none | with `HR_DIRECTORY_URL` | **yes** | Bearer token Wiki sends to HR's `GET /api/internal/directory/groups`. Must equal the token HR accepts there. Generate with `openssl rand -hex 32`. |
| `IDP_DIRECTORY_URL` | none | no | no | Keycloak's address as the backend reaches it, for example `https://keycloak.conservices-identity.svc.cluster.local:8443`. Used by the group picker when HR is not used. |
| `IDP_DIRECTORY_REALM` | `conservices` | no | no | Realm whose groups are listed. |
| `IDP_DIRECTORY_CLIENT_ID` | none | with `IDP_DIRECTORY_URL` | no | Confidential Keycloak client (client credentials) that may read groups, for example `wiki-directory`. |
| `IDP_DIRECTORY_CLIENT_SECRET` | none | with `IDP_DIRECTORY_URL` | **yes** | That client's secret. |

### Group picker

The share dialog's **group picker** suggests group names while you type.
You can always type any group name yourself; the picker only saves you from
remembering exact names. The backend picks one source per request:

1. **HR**, when Wiki is paired with Den and `HR_DIRECTORY_URL` is set: HR's
   departments (the group behind each department) and access groups (the
   groups behind module roles).
2. **The identity provider**, when `IDP_DIRECTORY_URL` is set: every group in
   the realm, read through Keycloak's admin API. A top-level group is offered
   by its name (`dept-security`), a nested one by its full path
   (`/org/dept-x`).
3. Otherwise **your own groups**, from your sign-in token.

Answers from HR or Keycloak are cached for 5 minutes. If the source fails,
the picker falls back to your own groups and shows a short warning; the
backend logs `group directory unavailable`.

**What HR must expose.** HR does not serve this endpoint yet. When it does,
it must answer exactly this, with the bearer token from `HR_DIRECTORY_TOKEN`:

```text
GET /api/internal/directory/groups
Authorization: Bearer <HR_DIRECTORY_TOKEN>
```

```json
{
  "groups": [
    { "name": "dept-security", "display_name": "Security", "kind": "department" },
    { "name": "wiki-editor", "display_name": "Wiki editors", "kind": "access" }
  ]
}
```

- `name` is the identity provider group exactly as it appears in tokens.
- `display_name` is what people read (the department's name).
- `kind` is `department` or `access`; anything else is treated as `access`.
- A wrong token answers `401`. Until HR serves the endpoint, leave
  `HR_DIRECTORY_URL` empty.

**Keycloak client for the identity provider source.** Create it once in the
Keycloak admin console:

1. **Clients → Create client**, client ID `wiki-directory`, **Client
   authentication** on, only **Service accounts roles** ticked.
2. **Service account roles → Assign role → Filter by clients**, pick
   `realm-management` `query-groups` and `view-users`.
3. **Credentials** shows the secret. Put it in your secret manager as
   `IDP_DIRECTORY_CLIENT_SECRET` (see [Secrets](../../operations/secrets.md)).
4. Set `IDP_DIRECTORY_URL` and `IDP_DIRECTORY_CLIENT_ID=wiki-directory`,
   restart the backend. On Kubernetes also set
   `networkPolicy.keycloakAdmin.enabled: true` in the chart.

Check it as any signed-in person:

```sh
curl -H "Authorization: Bearer $TOKEN" https://wiki.example.org/api/v1/groups
```

```json
{"groups":[{"name":"dept-security","display_name":"dept-security","kind":"idp"},{"name":"/org/dept-x","display_name":"dept-x","kind":"idp"}],"source":"idp"}
```

`"source":"token"` with a `warning` means the directory failed; see
Troubleshooting below.

### Revision retention

By default every revision is kept, so the bucket grows with every page's
history. `WIKI_REVISION_RETENTION_DAYS=90` deletes revisions older than 90
days once an hour: first the S3 object, then its database row, so a failed
delete is retried on the next run. The current page is never affected,
only its history. The history panel tells people how long revisions are
kept.

Once Wiki is paired, Den can set the retention for Wiki in its **module
settings**; Den's value wins. Den sends it in the integration bundle
(`GET /api/v1/integrations/bundle`), which Wiki stores with its pairing:

```json
{
  "brand": { "...": "..." },
  "settings": { "data": {} },
  "retention": { "revision_days": 90 }
}
```

`revision_days` must be a whole number, `0` or more (`0` keeps everything).
Anything else, or no `retention` at all, means "use
`WIKI_REVISION_RETENTION_DAYS`". Den does not send `retention` yet; until it
does, the local setting applies.

### Troubleshooting

- **The group picker only shows my own groups.** No directory is set, Wiki
  is not paired (HR is only used while paired), or the directory failed:
  `GET /api/v1/groups` then has a `warning` and the backend log shows
  `group directory unavailable` with the reason. `401` from HR: the tokens
  differ. `401` from Keycloak: wrong client secret. `403` from Keycloak: the
  client lacks `query-groups`. A timeout on Kubernetes: the network policy
  egress is missing (`networkPolicy.hr.enabled` or
  `networkPolicy.keycloakAdmin.enabled`, plus the ingress rule on the other
  side).
- **The backend does not start: `HR_DIRECTORY_TOKEN is required when
  HR_DIRECTORY_URL is set`** (or the same for `IDP_DIRECTORY_*`). Add the
  secret, or empty the URL.
- **Revisions are not deleted.** `GET /api/v1/pages/<id>/revisions` shows
  `retention_days` and `retention_source`; `0` keeps everything. With
  `source` `den`, the value comes from Den and overrides the local one. A
  failing S3 delete is logged as `could not remove an expired revision` and
  retried next hour.

### Internal TLS

On Kubernetes, Wiki's backend serves HTTPS inside the cluster and checks
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

The `wiki-frontend` image names no domain, so one published image works for
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
| `oidcClientId` | `""` | The public client the web app signs in with: `wiki-spa`. Required with `"oidc"`. |
| `oidcScope` | `"openid profile email"` | Scopes requested at sign-in. |
| `apiBaseUrl` | `""` | Address put in front of every API call (`/api/...`). Leave empty: nginx serves the app and forwards `/api/` on the same address. Only set it when the API lives on another origin, for example `https://api.example.org`. |
| `productName` | `""` (shows `Wiki`) | Name shown until Den's brand has loaded. |

Keys you leave out keep their default; unknown keys are ignored. The image
ships a placeholder file with empty `oidcAuthority` and `oidcClientId`: the
web app then shows **Not configured yet** instead of a sign-in page.

Example for `wiki.example.org`:

```json
{
  "authMode": "oidc",
  "oidcAuthority": "https://auth.example.org/realms/conservices",
  "oidcClientId": "wiki-spa",
  "oidcScope": "openid profile email",
  "apiBaseUrl": "",
  "productName": "Wiki"
}
```

### How to set it

1. **Helm:** set `frontend.config` in your values. Keys you leave out are
   filled in from the chart's other values: `authMode` from `config.AUTH_MODE`, `oidcAuthority` from `config.OIDC_ISSUER_URL`, `oidcClientId` from `config.OIDC_CLIENT_ID` (else `wiki-spa`), `productName` `Wiki`,
   `oidcScope` `openid profile email` and `apiBaseUrl` empty. So with the
   usual `config.OIDC_ISSUER_URL` you often need nothing extra. The chart
   writes the file to the ConfigMap `<release>-frontend-config` and restarts
   the web app pods when it changes.

   ```yaml
   frontend:
     config:
       oidcAuthority: https://auth.example.org/realms/conservices
       oidcClientId: wiki-spa
   ```

2. **Docker Compose:** the module's `infra/docker-compose.yml` mounts
   `infra/frontend-config/compose.json` (dev sign-in). For real sign-in, copy
   it, fill in the keys and set `FRONTEND_CONFIG` (a path relative to
   `infra/`) in `.env`. The full platform stack (root `docker-compose.yml`)
   mounts `infra/frontend-config/wiki.json`.
3. **Plain Docker:** mount the file read-only:

   ```sh
   docker run --rm -p 3000:8080 \
     -v "$PWD/config.json:/etc/conservices/config.json:ro" \
     ghcr.io/aglelectronics/wiki-frontend:1.0.0-1
   ```

Check what the browser gets:

```sh
curl -i https://wiki.example.org/config.json
```

```text
HTTP/2 200
content-type: application/json
cache-control: no-store

{
  "authMode": "oidc",
  "oidcAuthority": "https://auth.example.org/realms/conservices",
  "oidcClientId": "wiki-spa",
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
| `WIKI_VERSION` | `dev` | Version shown in the app. |
| `NGINX_CONF` | `nginx.conf` | Which file from `infra/` becomes the image's nginx config. The Helm chart (and the Kustomize manifests) mount their own. |

```sh
docker build -f infra/Dockerfile.frontend \
  --build-arg WIKI_VERSION=1.0.0 \
  -t registry.example.org/conservices/wiki-frontend:1.0.0-1 .
```

The local dev server (`npm run dev`) has no `/config.json`; it uses
`VITE_AUTH_MODE`, `VITE_OIDC_AUTHORITY`, `VITE_OIDC_CLIENT_ID`, `VITE_OIDC_SCOPE`, `VITE_API_BASE_URL` (for example `http://localhost:8140`), `VITE_PRODUCT_NAME` from the environment or `.env` instead. Image builds
ignore these.


## Access config file

`ACCESS_CONFIG_PATH` points at a TOML file that defines roles and binds
Keycloak groups to them. It is read once at start; restart the backend after
editing. The default file:

```toml
organization = "demo-org"

[roles.organization_admin]
description = "Full access to every team space and page, and the module settings."
permissions = ["wiki.manage", "space.create", "settings.manage"]

[roles.space_creator]
description = "Creates new team spaces."
permissions = ["space.create"]

[[bindings]]
group = "wiki-admin"
role = "organization_admin"

[[bindings]]
group = "wiki-editor"
role = "space_creator"
```

| Permission | Allows |
| --- | --- |
| `wiki.manage` | Full access to every team space and page (not private spaces). |
| `space.create` | Creating team spaces. |
| `settings.manage` | The Den connection (pairing). |

Reading and editing pages is **not** a role; it comes from sharing inside
Wiki. See the [Admin guide](admin-guide.md).
