# Set up Stash

This page installs Stash. Pick the posture that matches what you are
building:

| Posture | Database, storage, sign-in | Den | Use it for |
| --- | --- | --- | --- |
| [Platform on Kubernetes](#recommended-install-into-the-platform) (recommended) | Shared platform services | Paired | Production |
| [Standalone on Kubernetes](#standalone-on-kubernetes) | Your own | Optional | Inventory only |
| [Production with Docker](#production-with-docker) | Your own or the platform's | Optional | One server, no Kubernetes |
| [Development with Docker](#development-with-docker) | Throwaway containers | Optional | Trying it out, coding. **Never production.** |

!!! info "Words used on this page"
    A **namespace** is a named section of a Kubernetes cluster. A **Helm
    chart** is a package of Kubernetes manifests with settings ("values")
    you fill in. **Pairing** connects Stash to Den
    ([details](../../concepts/pairing.md)). A **secret manager** (Vault,
    AWS Secrets Manager, …) stores passwords outside the cluster
    ([Secrets](../../operations/secrets.md)).

## Recommended: install into the platform

You install Stash into a running Con Services platform: Den, Keycloak,
PostgreSQL and S3 storage are already up. If they are not, start with
[How the platform starts](../../getting-started/how-the-platform-starts.md).

!!! warning "The Helm chart is a first version"
    `deploy/charts/stash` (chart `0.1.0`) mirrors the tested Kustomize
    manifests in `deploy/kubernetes/modules/stash/`, but has not been
    installed on a real cluster yet. For a local trial, the Kustomize
    overlay is the tested path; see [Local trial with Kustomize](#local-trial-with-kustomize).

You need: `kubectl` and `helm` (3.x) pointed at the cluster, a Den
administrator account, and access to your secret manager.

### 1. Check that Den is ready

```sh
kubectl get pods -n conservices-den
```

All pods should be `Running` and `1/1`. In Den, **Admin console → Backups**
should list the database server. If not, fix Den first
([Troubleshooting](../../getting-started/troubleshooting.md)).

### 2. Register Stash in Den and create its database

In Den: **Admin console → Modules → New module**.

| Field | Value |
| --- | --- |
| Short name | `stash` |
| Display name | `Stash` |
| Address | `https://stash.example.org` (your Stash address) |
| Create a database for it | ticked |

Den shows the database connection URL **once**:

```text
postgres://stash:3f9c…e1@postgres.conservices-data.svc.cluster.local:5432/stash?sslmode=disable
```

Copy it straight into your secret manager (step 4). Den does not keep it.

### 3. Create the namespace

The labels let the platform's NetworkPolicies admit Stash's backend to Den,
PostgreSQL and storage, and enforce the restricted Pod Security level.

```sh
kubectl create namespace conservices-stash
kubectl label namespace conservices-stash \
  conservices.io/tier=module conservices.io/module=stash \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted
```

```text
namespace/conservices-stash created
namespace/conservices-stash labeled
```

### 4. Create the secret from your secret manager

Stash needs one Kubernetes Secret, `stash-secrets`, with three keys:

| Key | Value |
| --- | --- |
| `DATABASE_URL` | The URL Den showed in step 2. |
| `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` | Storage keys that can reach only the `stash-data` bucket. |

Store them in your secret manager and let the External Secrets Operator
create the Secret. With Vault (the full walkthrough, including the
`SecretStore` and other providers, is in [Secrets](../../operations/secrets.md)):

```sh
vault kv put secret/conservices/stash/backend \
  DATABASE_URL='postgres://stash:change-me@postgres.conservices-data.svc.cluster.local:5432/stash?sslmode=disable' \
  S3_ACCESS_KEY_ID=change-me S3_SECRET_ACCESS_KEY=change-me
```

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: stash-secrets
  namespace: conservices-stash
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault
    kind: SecretStore
  target:
    name: stash-secrets
  dataFrom:
    - extract:
        key: conservices/stash/backend
```

```sh
kubectl get externalsecret -n conservices-stash
```

```text
NAME            STORE   REFRESH INTERVAL   STATUS         READY
stash-secrets   vault   1h                 SecretSynced   True
```

!!! note "Not automated yet"
    Den does not create buckets or per-module storage keys. Create a key
    limited to `stash-data` at your storage provider yourself. Stash creates
    the bucket on first start if the key may do so.

### 5. Add the access config and the TLS certificate

Stash reads its roles and group bindings from a file (see
[Admin guide](admin-guide.md#who-can-do-what)). Start from the default:

```sh
kubectl create configmap stash-access-config -n conservices-stash \
  --from-file=access-config.toml=stash/infra/access-config.toml
```

The Ingress expects the HTTPS certificate in a Secret `conservices-tls` in
this namespace. With cert-manager, request a `Certificate` for your host;
by hand:

```sh
kubectl create secret tls conservices-tls -n conservices-stash --cert=tls.crt --key=tls.key
```

### 6. Write your values and install the chart

Create `stash-values.yaml` with your addresses (everything else has
defaults; the full list is in `deploy/charts/stash/values.yaml`):

```yaml
image:
  backend: { tag: "1.0.0-1" }
  frontend: { tag: "1.0.0-1" }
ingress:
  host: stash.example.org
config:
  APP_BASE_URL: https://stash.example.org
  CORS_ALLOWED_ORIGINS: https://stash.example.org
  OIDC_ISSUER_URL: https://auth.example.org/realms/conservices
  S3_ENDPOINT: https://s3.example.org
  S3_USE_PATH_STYLE: "false"
```

```sh
helm install stash deploy/charts/stash -n conservices-stash -f stash-values.yaml
```

```text
NAME: stash
NAMESPACE: conservices-stash
STATUS: deployed
REVISION: 1
NOTES:
Stash 1.0.0-1 is installed in namespace conservices-stash.
...
```

!!! note "Managed database or storage outside the cluster"
    The chart's NetworkPolicies allow PostgreSQL and MinIO in
    `conservices-data` only. For managed services set
    `networkPolicy.data.enabled: false` and add `ipBlock` rules under
    `networkPolicy.extraEgress` ([External services](../../operations/network-policies.md#external-services)).

### 7. Add the bucket to backups

Den's operator backs up only the buckets listed in its `FILES_S3_BUCKETS`.
Add `stash-data` there and re-apply Den's configuration
([Databases and backups](../../operations/databases-and-backups.md)). This
is **not automated** yet.

### 8. Check the pods

```sh
kubectl get pods -n conservices-stash
```

```text
NAME                              READY   STATUS    RESTARTS   AGE
stash-backend-5f7d9c6b8-kq2xd     1/1     Running   0          40s
stash-frontend-6c8b5d9f7-7wqzm    1/1     Running   0          40s
stash-frontend-6c8b5d9f7-p4ncs    1/1     Running   0          40s
```

```sh
kubectl exec -n conservices-stash deploy/stash-frontend -- wget -qO- http://stash-backend:8080/api/health
```

```json
{"status":"ok","database":"ok","version":"1.0.0-1","uptime_sec":42}
```

### 9. Pair Stash with Den

1. In Den: **Admin console → Modules**, click **Pair** on the Stash row and
   copy the pairing URL (valid 15 minutes, usable once).
2. Open `https://stash.example.org`, sign in as a Stash admin (a member of
   the Keycloak group `stash-admin`), go to **Settings → Den connection**,
   paste the URL and confirm.
3. Stash replaces the URL's host with `DEN_INTERNAL_URL`, redeems the token
   and stores its module credential in its own database.

Within a minute Stash shows Den's brand, Den's Modules page shows Stash as
paired, and the organisation name in Stash's settings becomes read-only
("managed in Den").

### 10. Sign in and check access

Sign in as someone in a Stash group (for example `stash-logistics-lead`).
They should see Items and Sign-outs. Someone in no bound group can sign
in but has no permissions, so every page answers "permission denied". If
that happens for the wrong person, see [Troubleshooting](#troubleshooting).

### Local trial with Kustomize

On a local cluster that runs the platform's example overlay, the tested
manifests install Stash in one command, after you paste Den's database URL
into `deploy/kubernetes/overlays/example-stash/secrets.yaml` and follow
that overlay's header comment:

```sh
kubectl apply -k deploy/kubernetes/overlays/example-stash
```

The full walkthrough is [How the platform starts, step 4](../../getting-started/how-the-platform-starts.md#step-4-deploy-a-module-stash).
The overlay uses a plain Secret with development values: local trials only.

## Standalone on Kubernetes

Run only Stash, with your own PostgreSQL, S3 bucket and OIDC provider.
Den is optional. The general steps are in
[Run one module on Kubernetes](../../getting-started/standalone-kubernetes.md);
this section covers what is specific to Stash.

**What changes without Den.** Stash works fully on its own. Until it is
paired it uses its own settings (organisation name, barcode prefix, default
currency in **Settings**), its built-in look, and `GET /api/brand` answers
`"source": "standalone"`. People's light or dark theme is kept in their
browser only. You can pair later at any time; unpairing returns Stash to
these defaults.

1. **Database.** Create a database and login for Stash on your PostgreSQL
   server (Stash creates its tables itself):

    ```sql
    CREATE ROLE stash LOGIN PASSWORD 'change-me';
    CREATE DATABASE stash OWNER stash;
    ```

2. **Storage.** Create a private bucket and a key limited to it.
3. **Sign-in.** In your OIDC provider, create a public client for the web
   app (redirect URI `https://stash.example.org/auth/callback`, web origin
   `https://stash.example.org`) and groups matching the bindings in your
   access config (for example `stash-admin`). Stash reads groups from the
   `groups` claim (or `roles`).
4. **Namespace, secret, access config, certificate:** steps 3 to 5 above,
   with your own database URL and storage keys.
5. **Values.** Turn off the platform rules and allow your services instead:

    ```yaml
    image:
      backend: { tag: "1.0.0-1" }
      frontend: { tag: "1.0.0-1" }
    ingress:
      host: stash.example.org
    config:
      APP_BASE_URL: https://stash.example.org
      CORS_ALLOWED_ORIGINS: https://stash.example.org
      OIDC_ISSUER_URL: https://login.example.org/realms/example
      OIDC_CLIENT_ID: stash
      OIDC_AUDIENCE: stash
      S3_ENDPOINT: https://s3.eu-central-1.amazonaws.com
      S3_BUCKET: example-stash
      S3_REGION: eu-central-1
      S3_USE_PATH_STYLE: "false"
      DEN_INTERNAL_URL: ""
    networkPolicy:
      den: { enabled: false }
      data: { enabled: false }
      oidcViaIngressController: false
      allowFromNamespaces: []
      extraEgress:
        - to: [{ ipBlock: { cidr: 10.20.0.0/24 } }]   # your PostgreSQL subnet
          ports: [{ protocol: TCP, port: 5432 }]
        - to: [{ ipBlock: { cidr: 0.0.0.0/0 } }]      # S3 and the OIDC provider
          ports: [{ protocol: TCP, port: 443 }]
    ```

6. Install and check as in steps 6 and 8.

!!! warning "Backups are your job"
    Without Den's operator nothing backs Stash up. Schedule
    `pg_dump --format=custom` of the `stash` database and a copy of the
    bucket, encrypt both, and keep them off the server.

!!! note "The web app image"
    The published frontend image is built for `https://auth.conservices.test/realms/conservices`
    and client `stash-spa`. For your own provider, build it yourself
    ([Frontend build settings](configuration.md#frontend-build-settings)).

## Production with Docker

Follow [Full stack on Docker](../../operations/docker-production.md) first:
it sets up the host, the proxy, Keycloak, Den and the hardened
`compose.production.yml`. Stash is then added to that file like Den.

| Container | Image | Port | Needs |
| --- | --- | --- | --- |
| `stash-backend` | `ghcr.io/aglelectronics/stash-backend:<tag>` | 8080 | The environment below, the access config file mounted read-only. |
| `stash-frontend` | your own build | 80 | Reaches the backend as `stash-backend:8080`. |

The web app reads its sign-in settings when it is **built**, so build your
own with `--build-arg NGINX_CONF=nginx.stack.conf` (its nginx config
proxies to `stash-backend:8080`; the default `nginx.conf` expects a service
called `backend`):

```sh
docker build -f infra/Dockerfile.frontend \
  --build-arg NGINX_CONF=nginx.stack.conf \
  --build-arg VITE_AUTH_MODE=oidc \
  --build-arg VITE_OIDC_AUTHORITY=https://auth.con.example.org/realms/conservices \
  --build-arg VITE_OIDC_CLIENT_ID=stash-spa \
  -t registry.example.org/conservices/stash-frontend:1.0.0-1 .
```

1. Write the env file. There are no default passwords; replace every
   `change-me`:

    ```text
    # /etc/conservices/stash-backend.env   (mode 600; values from the secret manager)
    DATABASE_URL=postgres://stash:change-me@db.example.org:5432/stash?sslmode=require
    S3_ACCESS_KEY_ID=change-me
    S3_SECRET_ACCESS_KEY=change-me
    ```

2. Copy `stash/infra/access-config.toml` to `./stash/access-config.toml`
   next to the compose file.
3. Add the services to `compose.production.yml`:

    ```yaml
      stash-backend:
        image: ghcr.io/aglelectronics/stash-backend:1.0.0-1
        <<: *hardening
        networks: [internal, egress]   # egress: database, S3
        env_file: /etc/conservices/stash-backend.env
        environment:
          APP_ENV: production
          APP_BASE_URL: https://stash.con.example.org
          HTTP_ADDR: ":8080"
          AUTH_MODE: oidc
          OIDC_ISSUER_URL: https://auth.con.example.org/realms/conservices
          OIDC_CLIENT_ID: stash-spa
          OIDC_AUDIENCE: stash-spa
          ACCESS_CONFIG_PATH: /etc/stash/access-config.toml
          CORS_ALLOWED_ORIGINS: https://stash.con.example.org
          S3_ENDPOINT: https://fsn1.your-objectstorage.com
          S3_BUCKET: example-stash
          S3_REGION: fsn1
          S3_USE_PATH_STYLE: "false"
          DEN_INTERNAL_URL: http://den-backend:8080
        volumes:
          - ./stash/access-config.toml:/etc/stash/access-config.toml:ro

      stash-frontend:
        image: registry.example.org/conservices/stash-frontend:1.0.0-1   # your own build
        restart: unless-stopped
        networks: [internal]
    ```

4. Add the host to the `Caddyfile`:

    ```text
    stash.con.example.org {
    	reverse_proxy stash-frontend:80
    }
    ```

5. Make sure the bucket is in Den's operator `FILES_S3_BUCKETS` (the
   reference file already lists `example-stash`), then start and check:

    ```sh
    docker compose -f compose.production.yml up -d
    docker compose -f compose.production.yml exec stash-frontend wget -qO- http://stash-backend:8080/api/health
    ```

    ```json
    {"status":"ok","database":"ok","version":"1.0.0-1","uptime_sec":12}
    ```

Run **one** `stash-backend` container only: it migrates the database when
it starts. Pair with Den as in [step 9](#9-pair-stash-with-den).

## Development with Docker

Quick and easy; uses development passwords and is **not for production**.

**Inside the full local stack** (root of the `con-services` checkout; Stash
has no profile, so it always starts with the stack):

```sh
docker compose up -d --build stash-frontend
```

Stash is then at <https://stash.conservices.test> (sign in through the
local Keycloak) and the API at <http://localhost:8088>. Details:
[Local development with Docker Compose](../../contributing/local-development.md).

**Stash on its own** (from the `stash/` checkout, header-based dev login,
no Keycloak):

```sh
cp .env.example .env
docker compose -f infra/docker-compose.yml up --build
```

Open <http://localhost:3000>. In `AUTH_MODE=dev` every request is the
`dev-admin` user with all permissions.

```sh
curl -s http://localhost:8080/api/health
```

```json
{"status":"ok","database":"ok","version":"dev","uptime_sec":5}
```

## Troubleshooting

**The backend exits with `invalid config: …`.** It lists every missing
setting at once, for example `DATABASE_URL is required; S3_ENDPOINT is
required`. Check that the Secret exists and has all three keys
(`kubectl get secret stash-secrets -n conservices-stash -o jsonpath='{.data}'`
shows the key names), and see [Configuration](configuration.md).

**`ACCESS_CONFIG_PATH is required when AUTH_MODE=oidc`.** The access
config ConfigMap is missing or not mounted. Create `stash-access-config`
(step 5).

**The pod stays `CreateContainerConfigError`.** A referenced Secret or
ConfigMap does not exist yet. `kubectl describe pod -n conservices-stash -l app.kubernetes.io/component=backend`
names it.

**Sign-in loops or the API answers 401 `invalid token`.** The issuer in
`OIDC_ISSUER_URL` must be exactly the `iss` of the tokens, and the backend
must reach it (on the platform, through the ingress controller on port 443).
With a private CA, mount it and set `SSL_CERT_DIR`
(`backend.extraEnv` / `extraVolumes` in the chart).

**Signed in, but the app is empty or shows "forbidden".** The person is in
no group bound in the access config, or the group name differs. Compare the
token's `groups` claim with the `[[bindings]]` entries; restart the backend
after editing the file.

**Pairing fails with `could not reach Den`.** `DEN_INTERNAL_URL` is wrong,
or the NetworkPolicy blocks it. From the backend's namespace, Den's
backend must answer on `http://den-backend.conservices-den.svc.cluster.local:8080`.

**Pairing fails with `Den refused the pairing URL`.** The URL expired (15
minutes) or was already used. Create a new one in Den.

**Downloads or presigned uploads fail in the browser.** Presigned links
point at `S3_ENDPOINT`, which is often an in-cluster address. Set
`S3_PUBLIC_BASE_URL` to an address browsers can reach
([Configuration](configuration.md#object-storage)). Photos shown in the
app are streamed by the backend and are not affected.
