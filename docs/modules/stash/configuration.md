# Stash configuration

Stash's backend reads all of its settings from **environment variables**
when it starts (a `.env` file in the working directory is read too, for
local development). Change a value, then restart the backend. On startup it
checks the required ones and exits with one message listing everything
missing, for example:

```text
invalid config: DATABASE_URL is required; S3_BUCKET is required
```

The source of truth is
[`backend/internal/config/config.go`](https://github.com/AGlElectronics/stash/blob/main/backend/internal/config/config.go);
the example file is [`.env.example`](https://github.com/AGlElectronics/stash/blob/main/.env.example).

**Where each value goes on Kubernetes.** *Secret* means the value belongs
in your secret manager and reaches the pod through the `stash-secrets`
Secret ([Secrets](../../operations/secrets.md)). *ConfigMap* means it is
plain configuration (`config:` in the Helm values, or the `stash-config`
ConfigMap in the Kustomize manifests).

## Core

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `APP_ENV` | `development` | no | ConfigMap | `development` turns on human-readable console logs; use `production` everywhere else (JSON logs). |
| `APP_BASE_URL` | `http://localhost:8080` | no | ConfigMap | Public address of Stash, for example `https://stash.example.org`. |
| `HTTP_ADDR` | `:8080` | no | ConfigMap | Address the API listens on inside the container. Keep `:8080`; the manifests and nginx configs expect it. |
| `DATABASE_URL` | none | **yes** | **Secret** | PostgreSQL connection URL, for example `postgres://stash:change-me@db:5432/stash?sslmode=require`. On the platform, Den shows it once when it creates the database; it ends in `?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt` because the platform's PostgreSQL accepts only TLS connections. |
| `CORS_ALLOWED_ORIGINS` | `http://localhost:3000` | no | ConfigMap | Comma-separated origins allowed to call the API from a browser. Set it to Stash's own address. |
| `TRUSTED_PROXY_CIDRS` | `10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,127.0.0.0/8,::1/128,fc00::/7` | no | ConfigMap | Comma-separated CIDRs of the proxies in front of the API (Gateway, nginx, Caddy). `X-Forwarded-For` is only believed on connections from these addresses; the resulting client IP is what rate limits count. Add a proxy that sits outside the private ranges; `none` trusts no proxy. See [Client IP addresses](../../operations/production.md#client-ip-addresses). |
| `SHUTDOWN_TIMEOUT` | `15s` | no | ConfigMap | How long running requests may finish when the backend stops (Go duration). |

## Internal TLS

On Kubernetes, Stash's backend serves HTTPS inside the cluster and checks
the certificates of the services it calls
([Internal TLS](../../operations/internal-tls.md)). The Helm chart (while
`internalTLS.enabled` is `true`, the default) and the Kustomize manifests
set these three variables themselves, so you normally do not add them to
`config:`. In Docker Compose development all three stay empty and the
backend serves plain HTTP.

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `TLS_CERT_FILE` | none | no | ConfigMap (set by the chart) | Path to the PEM certificate the backend serves HTTPS with; on Kubernetes `/etc/conservices-tls/tls.crt`. Set it together with `TLS_KEY_FILE`: setting only one stops the backend with `tls: TLS_CERT_FILE and TLS_KEY_FILE must be set together`. Both empty means plain HTTP. The backend re-reads the file every minute, so a certificate renewed by cert-manager is used without a restart. |
| `TLS_KEY_FILE` | none | no | ConfigMap (set by the chart) | Path to the matching PEM private key; on Kubernetes `/etc/conservices-tls/tls.key`. |
| `SSL_CERT_DIR` | none (system CAs only) | on Kubernetes | ConfigMap (set by the chart) | Standard Go setting: folders of extra CA certificates the backend trusts when it calls PostgreSQL, S3, Den and the identity provider. Separate several folders with `:`. On Kubernetes `/etc/conservices-internal-ca` (the platform's internal CA); the local example overlay uses `/etc/conservices-internal-ca:/etc/conservices-ca` to trust mkcert's root as well. Without it, calls fail with `x509: certificate signed by unknown authority`. |

With TLS on, the backend logs `tls enabled` at start, with the
certificate's expiry date in `not_after`. If a later re-read fails (for
example a half-written file), it logs `tls certificate reload failed;
keeping the current one` and keeps serving the old certificate. The
minimum protocol version is TLS 1.2.

## Object storage

Stash stores photos and attachments in one S3-compatible bucket. It creates
the bucket on first start if it does not exist and the keys allow it.

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `S3_ENDPOINT` | none | **yes** | ConfigMap | S3 API address, for example `https://s3.eu-central-1.amazonaws.com` or, on the platform, `https://s3.conservices-data.svc.cluster.local:9000`. |
| `S3_BUCKET` | none | **yes** | ConfigMap | Bucket name. Platform: `stash-data`. |
| `S3_ACCESS_KEY_ID` | none | **yes** | **Secret** | Access key, ideally limited to this bucket. |
| `S3_SECRET_ACCESS_KEY` | none | **yes** | **Secret** | Secret key for it. |
| `S3_REGION` | `us-east-1` | no | ConfigMap | Bucket region. |
| `S3_USE_PATH_STYLE` | `true` | no | ConfigMap | `true` for the local S3 server (SeaweedFS) and most self-hosted endpoints, `false` for AWS S3. |
| `S3_PUBLIC_BASE_URL` | none | no | ConfigMap | Replaces scheme and host in presigned download and upload links so browsers can reach them. Without it, the development host names `s3` and `minio` (exact match only) are rewritten to `localhost`. |

## Sign-in and access

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `AUTH_MODE` | `dev` | no | ConfigMap | `oidc` verifies bearer tokens from your identity provider. `dev` trusts an `X-Dev-User` header and must never be used outside local development. |
| `OIDC_ISSUER_URL` | none | with `oidc` | ConfigMap | Issuer of staff tokens, for example `https://auth.example.org/realms/conservices`. Must match the tokens' `iss` exactly. |
| `OIDC_CLIENT_ID` | none | with `oidc` | ConfigMap | Keycloak client of the web app (`stash-spa` on the platform). |
| `OIDC_AUDIENCE` | none | no | ConfigMap | Expected token audience if it differs from the client id. |
| `ACCESS_CONFIG_PATH` | none | with `oidc` | ConfigMap | Path to the access config TOML file (roles, permissions, group bindings), for example `/etc/stash/access-config.toml`. The file itself is mounted from a ConfigMap. See [Admin guide](admin-guide.md#who-can-do-what). |
| `OIDC_BINDINGS_PATH` | none | no | ConfigMap | Old name of `ACCESS_CONFIG_PATH`, still read when the new name is not set. |
| `DEV_DEFAULT_USER` | `dev-admin` | no | ConfigMap | User assumed in `dev` mode when no `X-Dev-User` header is sent. |

## Den and guest features

| Name | Default | Required | Where | What it does |
| --- | --- | --- | --- | --- |
| `DEN_INTERNAL_URL` | none | no | ConfigMap | Replaces scheme and host of a pasted Den pairing URL, for when the backend reaches Den at a different address than browsers (platform: `https://den-backend.conservices-den.svc.cluster.local:8080`). Empty for standalone installs. |
| `PUBLIC_LOSTFOUND_CLAIM_ENABLED` | `false` | no | ConfigMap | Turns on the guest Lost & Found lookup (`/api/public/lostfound`, no sign-in). Leave off until guest kiosks are ready. Pair with `publicClaimEnabled` in the web app's `/config.json` (the Helm chart derives it from this setting). |

## Other variables

| Name | Where | What it does |
| --- | --- | --- |
| `STASH_ACCESS_CONFIG` | `.env` for Compose only | Host path of the access config file mounted by `infra/docker-compose.local.yml`. Not read by Stash itself. |

## Web app settings (config.json)

The `stash-frontend` image names no domain, so one published image works for
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
| `oidcClientId` | `""` | The public client the web app signs in with: `stash-spa`. Required with `"oidc"`. |
| `oidcScope` | `"openid profile email"` | Scopes requested at sign-in. |
| `apiBaseUrl` | `""` | Address put in front of every API call (`/api/...`). Leave empty: nginx serves the app and forwards `/api/` on the same address. Only set it when the API lives on another origin, for example `https://api.example.org`. |
| `publicClaimEnabled` | `false` | Shows the guest Lost & Found claim page. Turn it on together with the backend's `PUBLIC_LOSTFOUND_CLAIM_ENABLED`. |

Keys you leave out keep their default; unknown keys are ignored. The image
ships a placeholder file with empty `oidcAuthority` and `oidcClientId`: the
web app then shows **Not configured yet** instead of a sign-in page.

Example for `stash.example.org`:

```json
{
  "authMode": "oidc",
  "oidcAuthority": "https://auth.example.org/realms/conservices",
  "oidcClientId": "stash-spa",
  "oidcScope": "openid profile email",
  "apiBaseUrl": "",
  "publicClaimEnabled": false
}
```

### How to set it

1. **Helm:** set `frontend.config` in your values. Keys you leave out are
   filled in from the chart's other values: `authMode` from `config.AUTH_MODE`, `oidcAuthority` from `config.OIDC_ISSUER_URL`, `oidcClientId` from `config.OIDC_CLIENT_ID` (else `stash-spa`), `publicClaimEnabled` from `config.PUBLIC_LOSTFOUND_CLAIM_ENABLED`,
   `oidcScope` `openid profile email` and `apiBaseUrl` empty. So with the
   usual `config.OIDC_ISSUER_URL` you often need nothing extra. The chart
   writes the file to the ConfigMap `<release>-frontend-config` and restarts
   the web app pods when it changes.

   ```yaml
   frontend:
     config:
       oidcAuthority: https://auth.example.org/realms/conservices
       oidcClientId: stash-spa
   ```

2. **Kustomize:** `deploy/kubernetes/modules/stash/frontend-config.json`
   becomes the ConfigMap `stash-frontend-config`. In your overlay, replace it
   with your own file:

   ```yaml
   configMapGenerator:
     - name: stash-frontend-config
       namespace: conservices-stash
       behavior: replace
       files:
         - config.json=stash-frontend-config.json
   ```

3. **Docker Compose:** the module's `infra/docker-compose.yml` mounts
   `infra/frontend-config/compose.json` (dev sign-in). For real sign-in, copy
   it, fill in the keys and set `FRONTEND_CONFIG` (a path relative to
   `infra/`) in `.env`. The full platform stack (root `docker-compose.yml`)
   mounts `infra/frontend-config/stash.json`.
4. **Plain Docker:** mount the file read-only:

   ```sh
   docker run --rm -p 3000:8080 \
     -v "$PWD/config.json:/etc/conservices/config.json:ro" \
     ghcr.io/aglelectronics/stash-frontend:1.0.0-1
   ```

Check what the browser gets:

```sh
curl -i https://stash.example.org/config.json
```

```text
HTTP/2 200
content-type: application/json
cache-control: no-store

{
  "authMode": "oidc",
  "oidcAuthority": "https://auth.example.org/realms/conservices",
  "oidcClientId": "stash-spa",
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
| `STASH_VERSION` | `dev` | Version shown in the app. |
| `NGINX_CONF` | `nginx.conf` | Which file from `infra/` becomes the image's nginx config. The Helm chart (and the Kustomize manifests) mount their own. |

```sh
docker build -f infra/Dockerfile.frontend \
  --build-arg STASH_VERSION=1.0.0 \
  -t registry.example.org/conservices/stash-frontend:1.0.0-1 .
```

The local dev server (`npm run dev`) has no `/config.json`; it uses
`VITE_AUTH_MODE`, `VITE_OIDC_AUTHORITY`, `VITE_OIDC_CLIENT_ID`, `VITE_OIDC_SCOPE`, `VITE_API_BASE_URL` (for example `http://localhost:8080`), `VITE_PUBLIC_CLAIM_ENABLED` from the environment or `.env` instead. Image builds
ignore these.


## Helm values

The chart in `deploy/charts/stash` maps its values onto the variables above:

| Value | Becomes |
| --- | --- |
| `config.*` | One entry each in the ConfigMap `<release>-config`. |
| `existingSecret` | Name of the Secret loaded with `envFrom` (`DATABASE_URL`, `S3_*` keys). |
| `accessConfig.existingConfigMap`, `mountPath`, `fileName` | The mounted access config and `ACCESS_CONFIG_PATH`. |
| `backend.extraEnv`, `extraVolumes`, `extraVolumeMounts` | Extra settings, for example another CA volume (then set `SSL_CERT_DIR` in `config:` to both folders, separated by `:`). |
| `image.*.tag` | `MAJOR.MINOR.PATCH-BUILD`; required. |
| `internalTLS.enabled` (default `true`) | HTTPS inside the cluster: sets `TLS_CERT_FILE`, `TLS_KEY_FILE` and `SSL_CERT_DIR`, mounts the certificate at `/etc/conservices-tls` and the CA at `/etc/conservices-internal-ca`, and makes nginx serve HTTPS and check the backend. `false` turns all of it off; change the `https://` URLs in `config:` back to `http://`. |
| `internalTLS.createCertificates` (default `true`) | Asks cert-manager for `stash-backend-tls` and `stash-frontend-tls`. `false`: create those Secrets yourself (keys `tls.crt`, `tls.key`, `ca.crt`). |
| `internalTLS.issuerRef` (default ClusterIssuer `conservices-internal-ca`) | The cert-manager issuer that signs them. |
| `internalTLS.duration`, `internalTLS.renewBefore` (default `2160h`, `720h`) | Certificate lifetime (90 days) and how long before expiry cert-manager renews it (30 days). |
| `internalTLS.caConfigMap` (default `conservices-internal-ca`) | ConfigMap (key `ca.crt`) with the internal CA, copied into the namespace by trust-manager. |
| `internalTLS.ingressNginxAnnotations` (default `false`) | Legacy, only with `ingress.enabled: true`: adds the ingress-nginx annotations that make the controller talk HTTPS to the web app and check its certificate. The Gateway API route uses a `BackendTLSPolicy` instead. ingress-nginx is no longer maintained; do not use it. |
| `route.*` (default on: host `stash.conservices.test`, Gateway `public` in `conservices-gateway`, timeout `60s`) | Gateway API `HTTPRoute` and, with internal TLS, a `BackendTLSPolicy`. See [Exposing the web app](../../operations/helm.md#exposing-the-web-app-gateway-api). |
| `ingress.*` (default off) | Plain `Ingress` for another controller. |
| `frontend.clientMaxBodySize` (default `50m`) | Upload limit in the web app's nginx; the gateway has no limit of its own. |
| `frontend.config` (default `{}`) | The web app's `/config.json` ([Web app settings](#web-app-settings-configjson)), as the ConfigMap `<release>-frontend-config`. Keys left out come from `config.AUTH_MODE`, `config.OIDC_ISSUER_URL`, `config.OIDC_CLIENT_ID` and `config.PUBLIC_LOSTFOUND_CLAIM_ENABLED`. |
| `ha.podDisruptionBudget`, `ha.topologySpread`, `priorityClassName` | PodDisruptionBudget and spreading over nodes for the web app; see [High availability](../../operations/helm.md#high-availability). |
