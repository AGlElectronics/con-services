# Set up Stash

This page installs Stash. Pick the posture that matches what you are
building:

| Posture | Database, storage, sign-in | Den | Use it for |
| --- | --- | --- | --- |
| [Production cluster with Argo CD](../../deploy/apps.md) (recommended for production) | CloudNativePG, Keycloak, managed S3 | Paired | Production: the whole suite on a cluster managed from Git |
| [Platform on Kubernetes](#recommended-install-into-the-platform) | Shared platform services | Paired | A cluster you run yourself; also the local trial cluster |
| [Standalone on Kubernetes](#standalone-on-kubernetes) | Your own | Optional | Inventory only |
| [Production with Docker](#production-with-docker) | Your own or the platform's | Optional | One server, no Kubernetes |
| [Development with Docker](#development-with-docker) | Throwaway containers | Optional | Trying it out, coding. **Never production.** |

The Argo CD path installs Stash together with Den and the other modules; see [Den and the modules](../../deploy/apps.md). A local Kubernetes cluster (the [quickstart](../../getting-started/den-quickstart.md)) is for trials only.

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
postgres://stash:3f9c…e1@postgres.conservices-data.svc.cluster.local:5432/stash?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt
```

Copy it straight into your secret manager (step 4). Den does not keep it.
The `sslmode=verify-full` part makes Stash connect with TLS and check the
database's certificate against the platform's internal CA; the platform's
PostgreSQL refuses connections without TLS.

### 3. Create the namespace

The labels let the platform's NetworkPolicies admit Stash's backend to Den,
PostgreSQL and storage, let trust-manager copy the internal CA into the
namespace ([Internal TLS](#internal-tls)), and enforce the restricted Pod
Security level.

```sh
kubectl create namespace conservices-stash
kubectl label namespace conservices-stash \
  conservices.io/tier=module conservices.io/module=stash \
  app.kubernetes.io/part-of=conservices \
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
  DATABASE_URL='postgres://stash:change-me@postgres.conservices-data.svc.cluster.local:5432/stash?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt' \
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

The public certificate browsers see lives on the Gateway, not in this
namespace: make sure the certificate of the Gateway `public` (in
`conservices-gateway`) covers your Stash host, for example
`stash.example.org`. Only with the legacy Ingress
(`ingress.enabled: true`) does the chart expect it in a Secret
`conservices-tls` in this namespace:

```sh
kubectl create secret tls conservices-tls -n conservices-stash --cert=tls.crt --key=tls.key
```

 The certificates for the
traffic **inside** the cluster (`stash-backend-tls`, `stash-frontend-tls`)
are requested from cert-manager by the chart; you do not create them. See
[Internal TLS](#internal-tls).

### 6. Write your values and install the chart

Create `stash-values.yaml` with your addresses (everything else has
defaults; the full list is in `deploy/charts/stash/values.yaml`):

```yaml
image:
  backend: { tag: "1.0.0-1" }
  frontend: { tag: "1.0.0-1" }
route:
  host: stash.example.org
config:
  APP_BASE_URL: https://stash.example.org
  CORS_ALLOWED_ORIGINS: https://stash.example.org
  OIDC_ISSUER_URL: https://auth.example.org/realms/conservices
  S3_ENDPOINT: https://s3.example.org
  S3_USE_PATH_STYLE: "false"
```

The chart's defaults already point at the platform services over HTTPS
(`DEN_INTERNAL_URL: https://den-backend.conservices-den.svc.cluster.local:8080`,
`S3_ENDPOINT: https://s3.conservices-data.svc.cluster.local:9000`), and
internal TLS is on (`internalTLS.enabled: true`). The cluster needs
cert-manager, trust-manager and the platform's internal CA; see
[Internal TLS](#internal-tls).

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
    The chart's NetworkPolicies allow PostgreSQL (CloudNativePG pods
    `cnpg.io/cluster: conservices-pg`) and S3 (Garage pods, port 3900) in
    `conservices-data` only; for the local-trial in-cluster postgres and S3 server
    change the selectors as in
    [Network policy values](../../operations/helm.md#network-policy-values).
    For an external S3 such as Hetzner Object Storage set
    `networkPolicy.data.s3.enabled: false` and list its host under
    `networkPolicy.data.s3.external.fqdns` (Cilium) or its address ranges
    under `.cidrs` ([External S3](../../operations/helm.md#external-s3-hetzner-object-storage)).
    For a managed database set
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
kubectl get certificate -n conservices-stash
kubectl exec -n conservices-stash deploy/stash-frontend -- curl -s --cacert /etc/conservices-internal-ca/ca.crt https://stash-backend:8080/api/health
```

```text
NAME                 READY   SECRET               AGE
stash-backend-tls    True    stash-backend-tls    45s
stash-frontend-tls   True    stash-frontend-tls   45s
```

```json
{"status":"ok","database":"ok","version":"1.0.0-1","uptime_sec":42}
```

The backend answers over HTTPS. `--cacert` makes `curl` check its certificate against the internal CA, which is mounted in the web app pod
at `/etc/conservices-internal-ca`; nginx does the same check on every
`/api/` request.

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
Internal TLS is on there too, so cert-manager and trust-manager must be
installed first; the overlay sets
`SSL_CERT_DIR=/etc/conservices-internal-ca:/etc/conservices-ca` so the
backend trusts both the internal CA and mkcert's root (for
`auth.conservices.test`).

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
   with your own database URL and storage keys. For a managed database,
   end the URL in `?sslmode=verify-full&sslrootcert=<path to the provider's CA>`
   and mount that CA file with `backend.extraVolumes` and
   `backend.extraVolumeMounts`.
5. **Internal TLS.** It stays on by default and needs cert-manager,
   trust-manager and an issuer in your cluster. Without them, either turn it
   off or bring your own certificates; see
   [Without cert-manager](#without-cert-manager).
6. **Values.** Turn off the platform rules and allow your services instead:

    ```yaml
    image:
      backend: { tag: "1.0.0-1" }
      frontend: { tag: "1.0.0-1" }
    route:
      host: stash.example.org
    den: { mode: standalone }   # no Den: do not wait for pairing
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

7. Install and check as in steps 6 and 8.

!!! warning "Backups are your job"
    Without Den's operator nothing backs Stash up. Schedule
    `pg_dump --format=custom` of the `stash` database and a copy of the
    bucket, encrypt both, and keep them off the server.

## Internal TLS

On Kubernetes, Stash encrypts the traffic **inside** the cluster as well,
not only between browsers and the Gateway. It is on by default
in the Helm chart and in the Kustomize manifests. The shared how-to,
including the platform setup and certificate rotation, is
[Internal TLS](../../operations/internal-tls.md).

What happens:

- **cert-manager** (a Kubernetes add-on that issues and renews
  certificates) issues `stash-backend-tls` and `stash-frontend-tls` from
  the ClusterIssuer `conservices-internal-ca`. They last 90 days and are
  renewed 30 days before they expire. Pods mount them at
  `/etc/conservices-tls` (`tls.crt`, `tls.key`, `ca.crt`).
- **trust-manager** copies the platform's internal CA certificate into the
  ConfigMap `conservices-internal-ca` (key `ca.crt`) in every namespace
  labelled `app.kubernetes.io/part-of: conservices`. Pods mount it at
  `/etc/conservices-internal-ca/ca.crt`.
- The **backend** serves HTTPS on port 8080 (`TLS_CERT_FILE`,
  `TLS_KEY_FILE`) and trusts the internal CA when it calls PostgreSQL,
  the S3 server and Den (`SSL_CERT_DIR`). It re-reads its certificate every
  minute, so a renewed one is used without a restart.
- The **web app**'s nginx serves HTTPS on port 8080, forwards `/api/` to the
  backend over HTTPS and checks the backend's certificate. It reloads every
  six hours to pick up a renewed certificate. Its Service listens on port
  443 (port name `https`).
- **The gateway** talks HTTPS to the web app and checks its certificate (a `BackendTLSPolicy`; with the legacy Ingress, the ingress controller does it).

Check it:

```sh
kubectl get certificate -n conservices-stash
kubectl get configmap conservices-internal-ca -n conservices-stash
kubectl logs -n conservices-stash deploy/stash-backend | grep "tls enabled"
```

```text
NAME                 READY   SECRET               AGE
stash-backend-tls    True    stash-backend-tls    3d
stash-frontend-tls   True    stash-frontend-tls   3d
NAME                      DATA   AGE
conservices-internal-ca   1      3d
```

The backend's `tls enabled` log line carries the certificate's expiry date
in `not_after`.

### Chart values

| Value | Default | What it does |
| --- | --- | --- |
| `internalTLS.enabled` | `true` | Turns internal TLS on or off for the backend, the web app and the Ingress. |
| `internalTLS.createCertificates` | `true` | `true`: the chart asks cert-manager for the two certificates. `false`: you create the Secrets `stash-backend-tls` and `stash-frontend-tls` yourself (keys `tls.crt`, `tls.key`, `ca.crt`). |
| `internalTLS.issuerRef` | ClusterIssuer `conservices-internal-ca` | The cert-manager issuer that signs them. |
| `internalTLS.duration` | `2160h` (90 days) | Certificate lifetime. |
| `internalTLS.renewBefore` | `720h` (30 days) | How long before expiry cert-manager renews. |
| `internalTLS.caConfigMap` | `conservices-internal-ca` | ConfigMap (key `ca.crt`) with the CA the pods trust. |
| `internalTLS.ingressNginxAnnotations` | `false` | Legacy, only with `ingress.enabled: true`: adds the ingress-nginx annotations for HTTPS to the web app (`backend-protocol: HTTPS`, `proxy-ssl-verify`). The Gateway API route uses a `BackendTLSPolicy` instead. ingress-nginx is no longer maintained; do not use it. |
| `route.enabled`, `route.host`, `route.parentRefs`, `route.timeout` | `true`, `stash.conservices.test`, Gateway `public` in `conservices-gateway` (listener `https`), `60s` | Exposes the web app through the Gateway API: an `HTTPRoute` and, with internal TLS, a `BackendTLSPolicy` that makes the gateway check `stash-frontend`'s certificate. See [Exposing the web app](../../operations/helm.md#exposing-the-web-app-gateway-api). |
| `frontend.config` | `{}` | The web app's `/config.json` (sign-in address, client id, claim page; see [Web app settings](configuration.md#web-app-settings-configjson)), written to the ConfigMap `<release>-frontend-config`. Keys left out come from `config.AUTH_MODE`, `config.OIDC_ISSUER_URL`, `config.OIDC_CLIENT_ID` (else `stash-spa`) and `config.PUBLIC_LOSTFOUND_CLAIM_ENABLED`. |
| `ingress.enabled` | `false` | Plain `Ingress` for another controller instead of the route. |
| `ha.podDisruptionBudget`, `ha.topologySpread`, `priorityClassName` | `true`, `true`, `""` | PodDisruptionBudget and spreading over nodes for the web app (two replicas); see [High availability](../../operations/helm.md#high-availability). |
| `networkPolicy.gateway.cilium` | `true` | Adds a `CiliumNetworkPolicy` that admits Cilium's gateway to the web app; see [Network policy values](../../operations/helm.md#network-policy-values). |
| `imagePullSecrets` | `[]` | Pull Secrets for private images on every pod, for example `[{name: ghcr-pull}]`; see [Private images](../../operations/helm.md#private-images). |
| `networkPolicy.data.s3.external.fqdns` / `.cidrs` / `.port` | `[]` / `[]` / `443` | Egress to an external S3 such as Hetzner Object Storage (`https://<location>.your-objectstorage.com`): host names with Cilium, address ranges otherwise; see [External S3](../../operations/helm.md#external-s3-hetzner-object-storage). |

### Without cert-manager

A standalone cluster without cert-manager has two choices.

**Turn internal TLS off.** Everything inside the cluster is plain HTTP
again, as in Docker Compose. Change the in-cluster `https://` addresses in
`config:` back to `http://`, and use a database URL with an `sslmode` your
database accepts:

```yaml
internalTLS:
  enabled: false
config:
  # The chart defaults, changed back to plain HTTP:
  S3_ENDPOINT: http://s3.conservices-data.svc.cluster.local:9000
  DEN_INTERNAL_URL: http://den-backend.conservices-den.svc.cluster.local:8080
```

**Bring your own certificates.** Create the two Secrets with any tool
(your own CA, a secret manager), each with `tls.crt`, `tls.key` and
`ca.crt`, and a ConfigMap with your CA under the key `ca.crt`:

```sh
kubectl create secret generic stash-backend-tls -n conservices-stash \
  --from-file=tls.crt=backend.crt --from-file=tls.key=backend.key --from-file=ca.crt=ca.crt
kubectl create secret generic stash-frontend-tls -n conservices-stash \
  --from-file=tls.crt=frontend.crt --from-file=tls.key=frontend.key --from-file=ca.crt=ca.crt
kubectl create configmap my-internal-ca -n conservices-stash --from-file=ca.crt=ca.crt
```

```yaml
internalTLS:
  createCertificates: false
  caConfigMap: my-internal-ca
```

The backend certificate must be valid for `stash-backend` and
`stash-backend.conservices-stash.svc.cluster.local`, the web app's for
`stash-frontend.conservices-stash.svc.cluster.local`. Replace them before
they expire; the backend picks up new files within a minute, nginx within
six hours.

!!! note "The web app image"
    The published frontend image names no domain. The chart's
    `frontend.config` (by default filled in from `config.OIDC_ISSUER_URL`
    and `config.OIDC_CLIENT_ID`) becomes its `/config.json`; see
    [Web app settings](configuration.md#web-app-settings-configjson).

## Production with Docker

Follow [Full stack on Docker](../../operations/docker-production.md) first:
it sets up the host, the proxy, Keycloak, Den and the hardened
`compose.production.yml`. Stash is then added to that file like Den.

| Container | Image | Port | Needs |
| --- | --- | --- | --- |
| `stash-backend` | `ghcr.io/aglelectronics/stash-backend:<tag>` | 8080 | The environment below, the access config file mounted read-only. |
| `stash-frontend` | `ghcr.io/aglelectronics/stash-frontend:<tag>` | 8080 | Reaches the backend as `stash-backend:8080`. |

The published web app image names no domain. Give it two files next to
the compose file: Stash's `infra/nginx.stack.conf` as its nginx config (it
forwards `/api/` to `stash-backend:8080`; the image's built-in config
expects a service called `backend`) and its sign-in settings as
`config.json` (keys: [Web app settings](configuration.md#web-app-settings-configjson)):

```sh
mkdir stash-frontend
cp ~/src/stash/infra/nginx.stack.conf stash-frontend/nginx.conf   # from a checkout of the release you run
cat > stash-frontend/config.json <<'EOF'
{
  "authMode": "oidc",
  "oidcAuthority": "https://auth.con.example.org/realms/conservices",
  "oidcClientId": "stash-spa",
  "publicClaimEnabled": false
}
EOF
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
        image: ghcr.io/aglelectronics/stash-frontend:1.0.0-1
        <<: *hardening
        networks: [internal]
        volumes:
          - ./stash-frontend/nginx.conf:/etc/nginx/conf.d/default.conf:ro
          - ./stash-frontend/config.json:/etc/conservices/config.json:ro
    ```

4. Add the host to the `Caddyfile`:

    ```text
    stash.con.example.org {
    	reverse_proxy stash-frontend:8080
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

**The backend exits with `tls: TLS_CERT_FILE and TLS_KEY_FILE must be set
together`.** Only one of the two is set, usually because one was added by
hand to `config:` or `backend.extraEnv`. Remove it: the chart and the
manifests set both while internal TLS is on, and neither while it is off.

**A pod stays `ContainerCreating`.** It waits for a volume that does not
exist yet: the Secret `stash-backend-tls` or `stash-frontend-tls` (made by
cert-manager) or the ConfigMap `conservices-internal-ca` (made by
trust-manager). `kubectl describe pod` shows `MountVolume.SetUp failed …
not found` under Events. Check:

```sh
kubectl get certificate -n conservices-stash
kubectl describe certificate stash-backend-tls -n conservices-stash
kubectl get configmap conservices-internal-ca -n conservices-stash
```

A certificate that is not `READY True` means cert-manager or the
ClusterIssuer `conservices-internal-ca` is missing; the events of
`kubectl describe certificate` say which. A missing ConfigMap means
trust-manager is not installed, or the namespace lacks the label:
`kubectl label namespace conservices-stash app.kubernetes.io/part-of=conservices`.
Without cert-manager, see [Without cert-manager](#without-cert-manager).

**The web app answers `502 Bad Gateway` and its log shows `upstream SSL
certificate verify error`.** nginx could not check the backend's
certificate. Either the backend serves plain HTTP (its log has no
`tls enabled` line), or its certificate was signed by a CA other than the
one in `conservices-internal-ca` (with your own certificates: put the right
CA in the ConfigMap named by `internalTLS.caConfigMap`). See the error with
`kubectl logs -n conservices-stash deploy/stash-frontend`.

**Calls to Den, storage or the database fail with `x509: certificate signed
by unknown authority`.** The backend does not trust the internal CA:
`SSL_CERT_DIR` is missing, or a value in `config:` replaced it with another
folder. It must include `/etc/conservices-internal-ca`; separate several
folders with `:`. Check with
`kubectl get configmap stash-config -n conservices-stash -o yaml`.

**The backend cannot reach the database: `no pg_hba.conf entry for host
"…", user "stash", database "stash", no encryption`.** `DATABASE_URL` still
ends in `sslmode=disable`, and the platform's PostgreSQL accepts only TLS.
Change the end to
`?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt` in
your secret manager, then
`kubectl rollout restart -n conservices-stash deploy/stash-backend`. For a
managed database use `sslmode=verify-full&sslrootcert=<path to the provider's CA>`.

**Sign-in loops or the API answers 401 `invalid token`.** The issuer in
`OIDC_ISSUER_URL` must be exactly the `iss` of the tokens, and the backend
must reach it (on the platform, through the Service `keycloak-public` on
port 443, which a CoreDNS rewrite or, in the local trial, `hostAliases`
points `auth.<domain>` at).
With a private CA, mount it (`backend.extraVolumes` and
`extraVolumeMounts` in the chart) and set `SSL_CERT_DIR` in `config:` to
both folders, for example
`/etc/conservices-internal-ca:/etc/my-ca`.

**Signed in, but the app is empty or shows "forbidden".** The person is in
no group bound in the access config, or the group name differs. Compare the
token's `groups` claim with the `[[bindings]]` entries; restart the backend
after editing the file.

**Pairing fails with `could not reach Den`.** `DEN_INTERNAL_URL` is wrong,
or the NetworkPolicy blocks it. From the backend's namespace, Den's
backend must answer on `https://den-backend.conservices-den.svc.cluster.local:8080`
(plain `http://` only when internal TLS is off).

**Pairing fails with `Den refused the pairing URL`.** The URL expired (15
minutes) or was already used. Create a new one in Den.

**Downloads or presigned uploads fail in the browser.** Presigned links
point at `S3_ENDPOINT`, which is often an in-cluster address. Set
`S3_PUBLIC_BASE_URL` to an address browsers can reach
([Configuration](configuration.md#object-storage)). Photos shown in the
app are streamed by the backend and are not affected.
