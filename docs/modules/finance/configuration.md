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
| Secret `finance-secrets` (`existingSecret`, from your secret manager) | `DATABASE_URL`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` and `DEN_LINK_ENCRYPTION_KEY`; optionally `DEN_LINK_ENCRYPTION_KEY_PREVIOUS` and `HR_SERVICE_TOKEN` (see [Secrets](../../operations/secrets.md)). |
| Secrets `finance-backend-tls`, `finance-frontend-tls` (from cert-manager) | The pods' internal TLS certificates (`tls.crt`, `tls.key`, `ca.crt`), mounted at `/etc/conservices-tls`. See [Internal TLS](#internal-tls). |
| ConfigMap `conservices-internal-ca` (from trust-manager) | The platform's internal CA (`ca.crt`), mounted at `/etc/conservices-internal-ca`. |

Finance has no access config file.

## Backend

| Variable | Default | Required | Secret | What it does |
| --- | --- | --- | --- | --- |
| `APP_ENV` | `production` | no | no | Only `development` relaxes the rules: it allows `AUTH_MODE=dev`, an unencrypted Den credential and `http://` pairing URLs to `localhost` and `*.conservices.test`. Any other value counts as production. Spaces and case are ignored. Set `development` explicitly for local work (`.env.example` and the Compose files do). |
| `APP_BASE_URL` | `http://localhost:8080` | no | no | Public address, for example `https://finance.example.org`. |
| `HTTP_ADDR` | `:8080` | no | no | Listen address inside the container. |
| `DATABASE_URL` | none | **yes** | **yes** | PostgreSQL URL. Also read by the migrate step. On the platform it ends in `?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt`, because the platform's PostgreSQL accepts only TLS connections. |
| `SHUTDOWN_TIMEOUT` | `15s` | no | no | How long a stopping backend waits for requests. |
| `CORS_ALLOWED_ORIGINS` | `http://localhost:3006` | no | no | Comma-separated browser origins. |
| `TRUSTED_PROXY_CIDRS` | `10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,127.0.0.0/8,::1/128,fc00::/7` | no | no | Comma-separated CIDRs of the proxies in front of the API (Gateway, nginx, Caddy). `X-Forwarded-For` is only believed on connections from these addresses and is read right to left; `X-Real-IP` and `True-Client-IP` are never read. The resulting client IP is what rate limits count and what the request log shows. Add a proxy that sits outside the private ranges; `none` trusts no proxy. An invalid entry stops the backend at start-up. See [Client IP addresses](../../operations/production.md#client-ip-addresses). |
| `AUTH_MODE` | `oidc` | no | no | `oidc` verifies Keycloak access tokens. `dev` trusts the `X-Dev-User` and `X-Dev-Groups` headers, so anyone can claim any role; the backend refuses to start with it unless `APP_ENV=development`. Outside `dev` the backend deletes those headers from every request, and CORS allows them only in `dev`. |
| `DEV_DEFAULT_USER` | `dev-finance-admin` | no | no | `dev` mode only: user when no `X-Dev-User` header is sent. |
| `DEV_DEFAULT_GROUPS` | `finance_admin` | no | no | `dev` mode only: comma-separated groups when no `X-Dev-Groups` header is sent. They map to roles like real groups. |
| `OIDC_ISSUER_URL` | none | with `oidc` | no | Issuer, for example `https://auth.example.org/realms/conservices`. |
| `OIDC_CLIENT_ID` | none | with `oidc` | no | `finance-spa`. |
| `OIDC_AUDIENCE` | `finance-api` | no | no | The backend accepts only **access tokens** whose `aud` contains this name; ID tokens are refused. Keycloak adds it with the audience mapper on the `finance-spa` client ([Audiences per API](../../concepts/authentication.md#audiences-per-api)). Keep the default. |
| `OIDC_GROUPS_CLAIM` | `groups` | no | no | The token claim with the person's groups. Keycloak `roles` are never merged in. A dotted name such as `realm_access.roles` is followed into nested objects. |
| `OIDC_GROUP_MATCH` | `full` | no | no | `full`: the whole group path must match a `FINANCE_*_GROUPS` entry. `last`: only the last path segment is compared. See [How groups are matched](../../concepts/authentication.md#how-groups-are-matched). |
| `OIDC_GROUP_PREFIX` | none | no | no | A parent group such as `/con2026` removed from group names before matching, when each convention year has its own parent group. |
| `HR_SERVICE_TOKEN` | none | no | **yes** | Lets HR read [`GET /api/role-catalog`](api.md#get-apirole-catalog) as `Authorization: Bearer <token>`; set the same value on HR. Without it only signed-in staff can read the catalog. |
| `API_RATE_LIMIT` | `300/m` | no | no | How many API requests each signed-in person (or, signed out, each address; IPv6 per `/64`) may make, as `<number>/s`, `/m` or `/h`. Over the limit the API answers `429 rate_limited` with `Retry-After`. Each backend replica counts on its own. |
| `API_RATE_BURST` | `60` | no | no | How many requests may come at once before the rate applies (1 or more). |
| `FINANCE_ADMIN_GROUPS` | `finance_admin` | no | no | Comma-separated IdP groups that grant the **admin** role (see [Roles](#roles)). The first one is what the role catalog publishes, so HR assigns that group. |
| `FINANCE_APPROVER_GROUPS` | `finance_approver` | no | no | Groups that grant the **approver** role. |
| `FINANCE_BOOKKEEPER_GROUPS` | `finance_bookkeeper` | no | no | Groups that grant the **bookkeeper** role. |
| `FINANCE_READONLY_GROUPS` | `finance_read-only` | no | no | Groups that grant the **read-only** role. |
| `FINANCE_CURRENCY` | `EUR` | no | no | The one currency of this installation (three-letter ISO 4217 code). Every invoice is in it. Set it before the first invoice; changing it later does not convert anything. |
| `FINANCE_DEFAULT_VAT_RATE_BP` | `2000` | no | no | VAT rate new invoice lines start with, in basis points (`2000` = 20%, `700` = 7%). Each line can still use its own rate. |
| `FINANCE_INVOICE_PREFIX` | `FIN-` | no | no | Start of invoice numbers (`FIN-0001`); 1–16 letters, digits, `-`, `_` or `/`. The counter does not restart when you change it. |
| `FINANCE_CREDIT_NOTE_PREFIX` | `FIN-CN-` | no | no | Start of credit note numbers (`FIN-CN-0001`), their own gap-free series. Must differ from the invoice prefix. |
| `FINANCE_APPROVAL_THRESHOLD_CENTS` | `0` | no | no | Voids, payments, expenses, credit notes and refunds **above** this amount (in cents) need a second person to approve them ([four-eyes approval](bookkeeping.md#four-eyes-approval)). `0`: all of them. `50000`: only amounts over 500.00. |
| `FINANCE_MAX_BACKDATE_DAYS` | `366` | no | no | How many days in the past an issue, payment, expense, credit note or refund date may lie (0–3660). Dates in the future are always refused. |
| `DEN_INTERNAL_URL` | none | no | no | Den's in-cluster address for pairing (platform: `https://den-backend.conservices-den.svc.cluster.local:8080`); empty without Den. It replaces scheme and host of a pasted pairing URL, so the pasted host is never contacted. |
| `DEN_ALLOWED_HOSTS` | none | when `DEN_INTERNAL_URL` is empty and you pair | no | Comma-separated hosts a pasted pairing URL may point at, for example `den.example.org` or `*.example.org`. Outside development the URL must also use `https://`. With `APP_ENV=development`, `localhost`, `127.0.0.1`, `::1` and `*.conservices.test` are always allowed. |
| `DEN_LINK_ENCRYPTION_KEY` | none | **yes**, unless `APP_ENV=development` | **yes** | 32 random bytes, base64 (`openssl rand -base64 32`). Encrypts the Den credential Finance stores (AES-256-GCM). Without it outside development the backend refuses to start. One key per installation; see [Den link encryption key](../../operations/secrets.md#den-link-encryption-key). |
| `DEN_LINK_ENCRYPTION_KEY_PREVIOUS` | none | no | **yes** | Only during a key rotation: the old key. Credentials sealed with it are re-encrypted with the current key on the next read. |
| `DEN_MODE` | `standalone` | no | no | `required`: until the module is paired with Den, its API answers `503 den_pairing_required` and the web app shows *Waiting for Den* (admins: *Connect this module to Den*). `standalone`: the module works without Den; pairing is optional. Kubernetes sets `required` (Helm: `den.mode`); Docker Compose sets `standalone`. See [Required or standalone](../../concepts/pairing.md#required-or-standalone). |
| `S3_ENDPOINT` | none | to issue | no | S3-compatible endpoint where issued invoice and credit note PDFs are stored, for example `https://fsn1.your-objectstorage.com` or, on the platform, Garage's in-cluster address. Without S3, Finance runs but issuing answers `503 storage_unavailable`. If **any** of `S3_ENDPOINT`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` is set, the endpoint, bucket and both keys become required. |
| `S3_BUCKET` | `finance-data-dev` | with S3 | no | Bucket for the PDFs (platform: `<prefix>-conservices-finance`). Objects are written once, under `invoices/<invoice id>/<number>.pdf` and `credit-notes/<id>/<number>.pdf`. |
| `S3_ACCESS_KEY_ID` | none | with S3 | **yes** | Access key with read and write on the bucket (no delete needed). |
| `S3_SECRET_ACCESS_KEY` | none | with S3 | **yes** | Its secret. |
| `S3_REGION` | `us-east-1` | no | no | Region used for request signing. |
| `S3_USE_PATH_STYLE` | `true` | no | no | `true` puts the bucket in the path (`https://host/bucket/key`), which SeaweedFS, Garage and MinIO need; `false` uses `https://bucket.host/key` (AWS). |

Tests only: `FINANCE_TEST_DATABASE_URL` points `go test` at a dev
PostgreSQL in which each database test creates and drops its own schema,
for example `postgres://postgres:postgres@localhost:5432/postgres?sslmode=disable`
(dev-only credentials). Without it the database tests are skipped.

!!! note "Pending accountant review"
    The money settings (one currency, default VAT rate, number prefixes,
    approval threshold, backdating limit) are deliberately basic. Before you
    rely on Finance for your books, have your accountant confirm the VAT
    rates, the numbering and what your country requires on an invoice.

## Roles

A person's IdP groups decide their Finance roles; HR assigns the groups
the role catalog publishes. Every route checks one permission.

| Role | Default group | Permissions | Can |
| --- | --- | --- | --- |
| Read-only | `finance_read-only` | `finance.read`, `finance.audit` | See everything, including the audit log. For accountants and auditors. |
| Bookkeeper | `finance_bookkeeper` | `finance.read`, `finance.write` | Keep customers, drafts and expenses, issue invoices, and request payments, voids, credit notes and refunds. |
| Approver | `finance_approver` | `finance.read`, `finance.approve`, `finance.audit` | Approve or reject requests of other people, close months. Records no money itself. |
| Admin | `finance_admin` | all five | Everything above, plus reopening months, Finance settings and the Den connection. |

Someone with no Finance role gets `403` "you don't have access to Finance".
Groups come only from the claim `OIDC_GROUPS_CLAIM` and match with the
shared rule ([How groups are matched](../../concepts/authentication.md#how-groups-are-matched)):
case and Keycloak's leading `/` are ignored, and `OIDC_GROUP_MATCH` and
`OIDC_GROUP_PREFIX` decide how much of a group path counts.

```sh
# Map existing groups instead of the defaults:
FINANCE_ADMIN_GROUPS=treasury-admins
FINANCE_APPROVER_GROUPS=treasurer,board
FINANCE_BOOKKEEPER_GROUPS=finance-team
FINANCE_READONLY_GROUPS=auditors
```

## Seller details

Issued invoices print the seller's name, address and VAT number. Finance
takes each field from, in this order:

1. Finance's own settings (Settings page, `PUT /api/settings`, admins);
2. Den, when paired: **Den → Module settings → Finance** (seller name,
   address, VAT number). Den sends them in the integration bundle, and
   Finance reads them from the bundle it stores with the pairing on every
   sync (within a minute of a change, and straight away after a restart);
3. nothing: issuing then answers `422` until a name and address are set.

Finance understands two forms of Den's seller details. The
[module settings contract](../../concepts/module-settings.md#finance-seller-details)
for 1.0 puts them under `finance.seller`:

```json
{
  "module_settings": {
    "updated_at": "2026-11-11T09:30:00Z",
    "data": {
      "finance": {
        "seller": {
          "legal_name": "Fur Con e.V.",
          "address": "Main Street 1\n1010 Vienna",
          "vat_id": "ATU12345678"
        }
      }
    }
  }
}
```

Den releases that do not send this form yet send
`module_settings.finance.seller_name`, `seller_address` and `vat_number`;
Finance reads those too. When both forms are present, the contract key
wins for each field (`legal_name` over `seller_name`, `address` over
`seller_address`, `vat_id` over `vat_number`). The other contract fields
(`country`, `tax_number`, `registration`, `email`, `website`) are not
printed on Finance's documents yet.

A standalone Finance (no Den) uses only its own settings. The Settings
page shows each value and where it comes from (`set in Finance`, `from
Den`, `not set`). Issued invoices keep the details they were issued with.

## Internal TLS

On Kubernetes, Finance's backend serves HTTPS inside the cluster and checks
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

With TLS on, the backend logs `tls enabled` at start, with the
certificate's expiry date in `not_after`. If a later re-read fails, it logs
`tls certificate reload failed; keeping the current one` and keeps serving
the old certificate. The minimum protocol version is TLS 1.2.

## Web app settings (config.json)

The `finance-frontend` image names no domain, so one published image works for
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
| `oidcClientId` | `""` | The public client the web app signs in with: `finance-spa`. Required with `"oidc"`. |
| `oidcScope` | `"openid profile email"` | Scopes requested at sign-in. |
| `apiBaseUrl` | `""` | Address put in front of every API call (`/api/...`). Leave empty: nginx serves the app and forwards `/api/` on the same address. Only set it when the API lives on another origin, for example `https://api.example.org`. |

Keys you leave out keep their default; unknown keys are ignored. The image
ships a placeholder file with empty `oidcAuthority` and `oidcClientId`: the
web app then shows **Not configured yet** instead of a sign-in page.

Example for `finance.example.org`:

```json
{
  "authMode": "oidc",
  "oidcAuthority": "https://auth.example.org/realms/conservices",
  "oidcClientId": "finance-spa",
  "oidcScope": "openid profile email",
  "apiBaseUrl": ""
}
```

### How to set it

1. **Helm:** set `frontend.config` in your values. Keys you leave out are
   filled in from the chart's other values: `authMode` from `config.AUTH_MODE`, `oidcAuthority` from `config.OIDC_ISSUER_URL`, `oidcClientId` from `config.OIDC_CLIENT_ID` (else `finance-spa`),
   `oidcScope` `openid profile email` and `apiBaseUrl` empty. So with the
   usual `config.OIDC_ISSUER_URL` you often need nothing extra. The chart
   writes the file to the ConfigMap `<release>-frontend-config` and restarts
   the web app pods when it changes.

   ```yaml
   frontend:
     config:
       oidcAuthority: https://auth.example.org/realms/conservices
       oidcClientId: finance-spa
   ```

2. **Docker Compose:** the module's `infra/docker-compose.yml` mounts
   `infra/frontend-config/compose.json` (dev sign-in). For real sign-in, copy
   it, fill in the keys and set `FRONTEND_CONFIG` (a path relative to
   `infra/`) in `.env`. The full platform stack (root `docker-compose.yml`)
   mounts `infra/frontend-config/finance.json`.
3. **Plain Docker:** mount the file read-only:

   ```sh
   docker run --rm -p 3000:8080 \
     -v "$PWD/config.json:/etc/conservices/config.json:ro" \
     ghcr.io/aglelectronics/finance-frontend:1.0.0-1
   ```

Check what the browser gets:

```sh
curl -i https://finance.example.org/config.json
```

```text
HTTP/2 200
content-type: application/json
cache-control: no-store

{
  "authMode": "oidc",
  "oidcAuthority": "https://auth.example.org/realms/conservices",
  "oidcClientId": "finance-spa",
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

## Web app security headers

The web app's nginx sends browser security headers on every page and file
of the app (not on `/api/`, where the backend sends its own): a **Content
Security Policy** (CSP, the list of places the page may load scripts and
data from), `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`,
`Referrer-Policy` and `Permissions-Policy`. They come from
`infra/security-headers.conf.template`, a copy of `con-services`
`shared/nginx` ([Nginx security headers](../../concepts/shared-code.md#nginx-security-headers)).

The CSP lets the browser talk to the app itself and to the origins in these
environment variables of the **web app container** (scheme and host, no
path; empty leaves them out):

| Variable | Default | What it is |
| --- | --- | --- |
| `KEYCLOAK_ORIGIN` | empty (Helm: scheme and host of `oidcAuthority`) | The sign-in server, for example `https://auth.example.org`. **Needed for sign-in**: without it the browser blocks the calls to Keycloak. |
| `DEN_ORIGIN` | empty | Den, only if the browser should call Den directly. Finance serves Den's brand through its own API, so leave it empty. |
| `S3_ORIGIN` | empty | Not needed: PDFs are downloaded through Finance's API. |
| `EXTRA_CONNECT_SRC` | empty | Anything else the browser must call. |

With Helm set them under `frontend.securityHeaders` (`keycloakOrigin`,
`denOrigin`, `s3Origin`, `extraConnectSrc`); the chart mounts an
`emptyDir` at `/etc/nginx/snippets` so nginx can write the filled-in file
at start-up. With Docker Compose set them under the frontend service's
`environment:` (the root stack sets `KEYCLOAK_ORIGIN:
https://auth.conservices.test`).

Check it:

```sh
curl -sI https://finance.example.org/ | grep -i -E 'content-security|x-frame|nosniff'
```

```text
content-security-policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob: ; font-src 'self' data:; connect-src 'self' https://auth.example.org   ; frame-src 'self' https://auth.example.org; frame-ancestors 'none'; form-action 'self' https://auth.example.org; base-uri 'self'; object-src 'none'
x-frame-options: DENY
x-content-type-options: nosniff
```

**Sign-in fails and the browser console says *Refused to connect to
'https://auth…'*.** `KEYCLOAK_ORIGIN` is empty or wrong. Set it on the web
app container and restart it.

## Frontend build settings

Docker build arguments of `infra/Dockerfile.frontend`. None of them is
installation-specific; the sign-in settings live in `/config.json` (above).

| Build argument | Default | What it does |
| --- | --- | --- |
| `FINANCE_VERSION` | `dev` | Version shown in the app. |
| `NGINX_CONF` | `nginx.conf` | Which file from `infra/` becomes the image's nginx config. The Helm chart (and the Kustomize manifests) mount their own. |

```sh
docker build -f infra/Dockerfile.frontend \
  --build-arg FINANCE_VERSION=1.0.0 \
  -t registry.example.org/conservices/finance-frontend:1.0.0-1 .
```

The local dev server (`npm run dev`) has no `/config.json`; it uses
`VITE_AUTH_MODE`, `VITE_OIDC_AUTHORITY`, `VITE_OIDC_CLIENT_ID`, `VITE_OIDC_SCOPE`, `VITE_API_BASE_URL` (for example `http://localhost:8130`) from the environment or `.env` instead. Image builds
ignore these. `VITE_DEV_USER` (default `dev-finance-admin`) picks the user the
dev server signs in as in `dev` mode; production builds always use
`dev-finance-admin`, so the setting cannot be smuggled into an image.
