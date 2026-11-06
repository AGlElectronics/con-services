# Finance configuration reference

Finance is configured through **environment variables**. The backend and
the migrate step read a `.env` file in their working directory if one
exists, then the real environment (which wins). The repository's
[`.env.example`](https://github.com/AGlElectronics/finance/blob/main/.env.example)
has a local development example. An empty value counts as not set. The
backend checks its settings at start and refuses to start with a list of
every problem.

## Where the settings live on Kubernetes

| Kubernetes object | Holds |
| --- | --- |
| ConfigMap `<release>-config` (from `values.yaml` `config:`) | Every setting below that is not a secret. |
| Secret `finance-secrets` (`existingSecret`, from your secret manager) | `DATABASE_URL` (and the `S3_*` keys once Finance stores files). |

Finance has no access config file.

## Backend

| Variable | Default | Required | Secret | What it does |
| --- | --- | --- | --- | --- |
| `APP_ENV` | `development` | no | no | `production` on real installations. |
| `APP_BASE_URL` | `http://localhost:8080` | no | no | Public address, for example `https://finance.example.org`. |
| `HTTP_ADDR` | `:8080` | no | no | Listen address inside the container. |
| `DATABASE_URL` | none | **yes** | **yes** | PostgreSQL URL. Also read by the migrate step. |
| `SHUTDOWN_TIMEOUT` | `15s` | no | no | How long a stopping backend waits for requests. |
| `CORS_ALLOWED_ORIGINS` | `http://localhost:3006` | no | no | Comma-separated browser origins. |
| `AUTH_MODE` | `dev` | no | no | `oidc` for real sign-in. `dev` trusts the `X-Dev-User` header and **grants everyone access**: local development only. |
| `DEV_DEFAULT_USER` | `dev-finance-admin` | no | no | `dev` mode only: user when no header is sent. |
| `OIDC_ISSUER_URL` | none | with `oidc` | no | Issuer, for example `https://auth.example.org/realms/conservices`. |
| `OIDC_CLIENT_ID` | none | with `oidc` | no | `finance-spa`. |
| `OIDC_AUDIENCE` | none | no | no | Normally `finance-spa`. |
| `FINANCE_ACCESS_GROUPS` | `finance-admin` | no | no | Comma-separated Keycloak groups allowed to use Finance (with `oidc`). Members get full access; everyone else gets `403`. |
| `DEN_INTERNAL_URL` | none | no | no | Den's in-cluster address for pairing; empty without Den. |
| `S3_ENDPOINT` | none | no | no | Reserved for invoice PDFs; Finance stores no files yet. If **any** `S3_*` value below (endpoint or keys) is set, the endpoint, bucket and both keys become required. |
| `S3_BUCKET` | `finance-data-dev` | no | no | Reserved. |
| `S3_ACCESS_KEY_ID` | none | no | **yes** | Reserved. |
| `S3_SECRET_ACCESS_KEY` | none | no | **yes** | Reserved. |
| `S3_REGION` | `us-east-1` | no | no | Reserved. |
| `S3_USE_PATH_STYLE` | `true` | no | no | Reserved. |

## Frontend build settings

Compiled into the `finance-frontend` image at **build** time:

| Build argument | Default | What it does |
| --- | --- | --- |
| `VITE_AUTH_MODE` | `dev` | `oidc` for real sign-in. |
| `VITE_OIDC_AUTHORITY` | none | Issuer URL. |
| `VITE_OIDC_CLIENT_ID` | none | `finance-spa`. |
| `VITE_OIDC_SCOPE` | `openid profile email` | Scopes. |
| `VITE_DEV_USER` | `dev-finance-admin` | `dev` mode only: user name the web app sends. |
| `NGINX_CONF` | `nginx.conf` | nginx config baked into the image (the Helm chart replaces it). |

The image has no `VITE_API_BASE_URL` build argument: the web app calls
`/api` on its own address, and nginx forwards it.

```sh
cd finance
docker build -f infra/Dockerfile.frontend \
  --build-arg VITE_AUTH_MODE=oidc \
  --build-arg VITE_OIDC_AUTHORITY=https://auth.example.org/realms/conservices \
  --build-arg VITE_OIDC_CLIENT_ID=finance-spa \
  -t registry.example.org/conservices/finance-frontend:1.0.0-1 .
```
