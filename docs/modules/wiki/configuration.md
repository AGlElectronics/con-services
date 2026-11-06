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
| Secret `wiki-secrets` | `DATABASE_URL`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `WIKI_SERVICE_TOKEN`. |
| ConfigMap `wiki-access-config` | The access config file (roles and group bindings). |

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
| `DATABASE_URL` | none | **yes** | **yes** | PostgreSQL connection URL, for example `postgres://wiki:change-me@db.example.org:5432/wiki?sslmode=require`. Also read by the migrate step. |
| `SHUTDOWN_TIMEOUT` | `15s` | no | no | How long a stopping backend waits for requests to finish. Give the pod at least 30 s on top for live editing. |
| `CORS_ALLOWED_ORIGINS` | `http://localhost:3007` | no | no | Comma-separated browser origins allowed to call the API, for example `https://wiki.example.org`. |

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
| `DEN_INTERNAL_URL` | none | no | no | Den's address as the backend reaches it, for example `http://den-backend.conservices-den.svc.cluster.local:8080`. Replaces the host of a pasted pairing URL. Empty without Den. See [Pairing](../../concepts/pairing.md). |
| `BRAND_LOCAL_PATH` | none | no | no | Optional `brand.json` used while Wiki is not paired. Once paired, Den's brand wins. |

### Storage and live editing

| Variable | Default | Required | Secret | What it does |
| --- | --- | --- | --- | --- |
| `S3_ENDPOINT` | none | in practice yes | no | S3 address, for example `https://fsn1.your-objectstorage.com`. **Empty turns storage off**: live editing, uploads, history and duplication answer `503`. Set but unreachable: the backend refuses to start. |
| `S3_BUCKET` | `wiki-data-dev` | no | no | Bucket for page content and uploads. Created on start if the keys allow it. Add it to the Den operator's `FILES_S3_BUCKETS`. |
| `S3_ACCESS_KEY_ID` | none | with S3 | **yes** | Key for the bucket. |
| `S3_SECRET_ACCESS_KEY` | none | with S3 | **yes** | Secret for the key. |
| `S3_REGION` | `us-east-1` | no | no | Region of the bucket. |
| `S3_USE_PATH_STYLE` | `true` | no | no | `true` for MinIO and most self-hosted S3; `false` for AWS virtual-hosted addresses. |
| `WIKI_BUFFER_DIR` | `./data/buffer` | no | no | Directory for the last few seconds of live edits before they are shipped to S3. Put it on a volume; the images use `/var/lib/wiki/buffer`. One backend replica owns it. |

### Sharing and offboarding

| Variable | Default | Required | Secret | What it does |
| --- | --- | --- | --- | --- |
| `PUBLIC_LINKS_ENABLED` | `false` | no | no | Allows public share links while Wiki is **not paired**. Once paired, Den's organisation setting `wiki_public_links` decides. |
| `WIKI_SERVICE_TOKEN` | none | for HR | **yes** | Bearer token HR uses for `POST /api/internal/offboarded`. **Empty turns that endpoint off** (it answers `404`). Must equal the token in HR's `OFFBOARD_HOOKS`. Generate with `openssl rand -hex 32`. |
| `WIKI_OFFBOARD_GRACE_DAYS` | `30` | no | no | Days an offboarded person's private space stays (visible to Wiki admins) before an hourly sweep deletes it. |

## Frontend build settings

The web app's settings are compiled in when the `wiki-frontend` image is
**built**; changing them later has no effect. Pass them as build arguments:

| Build argument | Default | What it does |
| --- | --- | --- |
| `VITE_AUTH_MODE` | `dev` | `oidc` for real sign-in. The build fails if `oidc` is chosen without the next two. |
| `VITE_OIDC_AUTHORITY` | none | Issuer URL, for example `https://auth.example.org/realms/conservices`. |
| `VITE_OIDC_CLIENT_ID` | none | `wiki-spa`. |
| `VITE_OIDC_SCOPE` | `openid profile email` | Scopes requested at sign-in. |
| `VITE_API_BASE_URL` | empty | Leave empty: the web app calls `/api` on its own address, and nginx forwards it. |
| `VITE_PRODUCT_NAME` | `Wiki` | Name shown before Den's brand loads. |
| `NGINX_CONF` | `nginx.conf` | Which file from `infra/` becomes nginx's config. The Helm chart replaces it at run time anyway. |

```sh
cd wiki
docker build -f infra/Dockerfile.frontend \
  --build-arg VITE_AUTH_MODE=oidc \
  --build-arg VITE_OIDC_AUTHORITY=https://auth.example.org/realms/conservices \
  --build-arg VITE_OIDC_CLIENT_ID=wiki-spa \
  -t registry.example.org/conservices/wiki-frontend:1.0.0-1 .
```

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
