# Set up Tasks

This page installs Tasks. Pick one of five ways:

| Option | When | Data safe? |
| --- | --- | --- |
| [Production cluster with Argo CD](../../deploy/apps.md) (recommended for production) | Production: the whole suite on a cluster managed from Git | Yes, CloudNativePG backups and Den's operator |
| [1. Kubernetes platform](#option-1-kubernetes-platform-recommended) | A cluster you run yourself, with Den already running; also the local trial cluster from the quickstart | Yes, backed up by Den's operator |
| [2. Standalone on Kubernetes](#option-2-standalone-on-kubernetes) | Only Tasks, your own PostgreSQL, S3 and sign-in | Yes, if **you** back it up |
| [3. Production on Docker](#option-3-production-on-docker) | One server without Kubernetes | Yes, with care |
| [4. Development on Docker](#option-4-development-on-docker) | Trying it out, development | **No**: public passwords |

The Argo CD path installs Tasks together with Den and the other modules; see [Den and the modules](../../deploy/apps.md). A local Kubernetes cluster (the [quickstart](../../getting-started/den-quickstart.md)) is for trials only.

## What Tasks needs

| Needs | Why |
| --- | --- |
| PostgreSQL 16 database and a login that owns it | Everything except attachments. |
| An S3-compatible bucket and keys (optional) | Attachments. Without it, uploads answer `503`. |
| An OpenID Connect sign-in server (Keycloak) | A public client `tasks-spa` with your Tasks address as redirect URI, and the groups `tasks-admin`, `tasks-creator`. |

## Option 1: Kubernetes platform (recommended)

Den must be running and checked first: see
[How the platform starts](../../getting-started/how-the-platform-starts.md).

1. **Register Tasks in Den and create its database.** Den: **Admin console
   → Modules → New module**, short name `tasks`, address
   `https://tasks.<your-domain>`, tick **Create a database for it**. Copy the
   connection URL Den shows once straight into your secret manager. It ends
   in `?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt`:
   Tasks connects with TLS and checks the database's certificate against
   the platform's internal CA, and the platform's PostgreSQL refuses
   connections without TLS.

2. **Create the bucket** (for example `tasks-data`) with keys limited to it,
   and add it to the Den operator's `FILES_S3_BUCKETS` so attachments are
   backed up.

3. **Create the namespace.** The `app.kubernetes.io/part-of` label lets
   trust-manager copy the internal CA into it ([Internal TLS](#internal-tls)).

    ```sh
    kubectl create namespace conservices-tasks
    kubectl label namespace conservices-tasks \
      conservices.io/tier=module conservices.io/module=tasks \
      app.kubernetes.io/part-of=conservices \
      pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/warn=restricted
    ```

4. **Store the secrets in your secret manager** and let an `ExternalSecret`
   create `tasks-secrets` (see [Secrets](../../operations/secrets.md)):

    ```sh
    vault kv put secret/conservices/tasks/backend \
      DATABASE_URL='postgres://tasks:change-me@postgres.conservices-data.svc.cluster.local:5432/tasks?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt' \
      S3_ACCESS_KEY_ID=change-me S3_SECRET_ACCESS_KEY=change-me \
      TASKS_SERVICE_TOKEN="$(openssl rand -hex 32)"
    ```

    ```yaml
    apiVersion: external-secrets.io/v1
    kind: ExternalSecret
    metadata:
      name: tasks-secrets
      namespace: conservices-tasks
    spec:
      refreshInterval: 1h
      secretStoreRef: { name: vault, kind: SecretStore }
      target: { name: tasks-secrets }
      dataFrom:
        - extract: { key: conservices/tasks/backend }
    ```

5. **Create the access config** from `infra/access-config.toml` in the
   Tasks repository:

    ```sh
    kubectl create configmap tasks-access-config -n conservices-tasks \
      --from-file=access-config.toml=access-config.toml
    ```

6. **Install the chart:**

    ```yaml
    # my-tasks.yaml
    image:
      backend:  { tag: "1.0.0-1" }
      frontend: { tag: "1.0.0-1" }
      migrate:  { tag: "1.0.0-1" }
    config:
      APP_BASE_URL: https://tasks.example.org
      OIDC_ISSUER_URL: https://auth.example.org/realms/conservices
      CORS_ALLOWED_ORIGINS: https://tasks.example.org
      S3_BUCKET: tasks-data
    route:
      host: tasks.example.org
    ```

    ```sh
    helm install tasks deploy/charts/tasks -n conservices-tasks -f my-tasks.yaml
    kubectl get pods -n conservices-tasks -w
    ```

    ```text
    NAME                              READY   STATUS     RESTARTS   AGE
    tasks-backend-6f8d7c9b5-l2wqp     0/1     Init:0/1   0          4s
    tasks-backend-6f8d7c9b5-l2wqp     1/1     Running    0          18s
    tasks-frontend-5b7c8d9f6-9xkzr    1/1     Running    0          18s
    tasks-frontend-5b7c8d9f6-tq4mn    1/1     Running    0          18s
    ```

    Internal TLS is on by default (`internalTLS.enabled: true`), and the
    chart's defaults reach the platform services over HTTPS
    (`S3_ENDPOINT: https://s3.conservices-data.svc.cluster.local:9000`,
    `DEN_INTERNAL_URL: https://den-backend.conservices-den.svc.cluster.local:8080`).
    The cluster needs cert-manager, trust-manager and the platform's
    internal CA; see [Internal TLS](#internal-tls).

7. **Pair with Den.** Den: **Admin console → Modules → Pair** on the Tasks
   row. Tasks (as `tasks-admin`): **Settings → Den connection**, paste the
   URL, **Connect**.

8. **Connect HR** (only if you run HR). HR tells Tasks about departments.
   In HR's settings:

    ```text
    DEPARTMENT_HOOKS=https://tasks-backend.conservices-tasks.svc.cluster.local:8080/api/internal/departments|<TASKS_SERVICE_TOKEN>
    ```

    The Tasks chart already admits HR's backend; HR's namespace needs the
    matching egress rule to `conservices-tasks` port 8080 (see
    [Network policies](../../operations/network-policies.md#calls-between-modules)).
    Departments that existed before can be seeded with
    `scripts/backfill-department-spaces.ps1` from the `con-services`
    repository.

9. **Verify:**

    ```sh
    kubectl get certificate -n conservices-tasks
    kubectl exec -n conservices-tasks deploy/tasks-frontend -- curl -s --cacert /etc/conservices-internal-ca/ca.crt https://tasks-backend:8080/api/health
    ```

    ```text
    NAME                 READY   SECRET               AGE
    tasks-backend-tls    True    tasks-backend-tls    35s
    tasks-frontend-tls   True    tasks-frontend-tls   35s
    ```

    ```json
    {"status":"ok","database":"ok","version":"1.0.0-1","uptime_sec":31}
    ```

    The backend answers over HTTPS. `--cacert` makes `curl` check its

    certificate against the internal CA mounted in the web app pod; nginx

    does the same check on every `/api/` request.

    Open `https://tasks.<your-domain>`, create a space (key `TEST`) and a
    task; its ID is `TEST-1`.

## Option 2: Standalone on Kubernetes

Only Tasks, without Den. Follow
[Run one module on Kubernetes](../../getting-started/standalone-kubernetes.md)
with these Tasks values:

- Create the database and login yourself; a bucket only if you want
  attachments.
- Secret `tasks-secrets` with `DATABASE_URL` (and the `S3_*` keys).
  `TASKS_SERVICE_TOKEN` stays empty without HR, which turns the department
  hook off.
- Values:

    ```yaml
    config:
      APP_BASE_URL: https://tasks.example.org
      OIDC_ISSUER_URL: https://login.example.org/realms/conservices
      CORS_ALLOWED_ORIGINS: https://tasks.example.org
      S3_ENDPOINT: https://fsn1.your-objectstorage.com   # or "" for no attachments
      S3_BUCKET: example-tasks
      S3_REGION: fsn1
      DEN_INTERNAL_URL: ""
    networkPolicy:
      den:  { enabled: false }
      data: { enabled: false }
      allowFromNamespaces: []
      extraEgress:
        - to: [{ ipBlock: { cidr: 10.20.0.0/24 } }]   # your database subnet
          ports: [{ protocol: TCP, port: 5432 }]
        - to: [{ ipBlock: { cidr: 0.0.0.0/0 } }]      # managed S3 over HTTPS
          ports: [{ protocol: TCP, port: 443 }]
    ```

- Internal TLS stays on by default and needs cert-manager, trust-manager
  and an issuer in your cluster. Without them, turn it off or bring your
  own certificates ([Without cert-manager](#without-cert-manager)). For a
  managed database, end `DATABASE_URL` in
  `?sslmode=verify-full&sslrootcert=<path to the provider's CA>` and mount
  that CA file with `backend.extraVolumes` and `backend.extraVolumeMounts`.
- **Back up the database (and bucket) yourself.**

## Internal TLS

On Kubernetes, Tasks encrypts the traffic **inside** the cluster as well,
not only between browsers and the Gateway. It is on by default
in the Helm chart. The shared how-to, including the platform setup and
certificate rotation, is [Internal TLS](../../operations/internal-tls.md).

What happens:

- **cert-manager** (a Kubernetes add-on that issues and renews
  certificates) issues `tasks-backend-tls` and `tasks-frontend-tls` from
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
kubectl get certificate -n conservices-tasks
kubectl get configmap conservices-internal-ca -n conservices-tasks
kubectl logs -n conservices-tasks deploy/tasks-backend | grep "tls enabled"
```

Both certificates should be `READY True`, the ConfigMap should exist, and
the backend's `tls enabled` log line carries the certificate's expiry date
in `not_after`.

### Chart values

| Value | Default | What it does |
| --- | --- | --- |
| `internalTLS.enabled` | `true` | Turns internal TLS on or off for the backend, the web app and the Ingress. |
| `internalTLS.createCertificates` | `true` | `true`: the chart asks cert-manager for the two certificates. `false`: you create the Secrets `tasks-backend-tls` and `tasks-frontend-tls` yourself (keys `tls.crt`, `tls.key`, `ca.crt`). |
| `internalTLS.issuerRef` | ClusterIssuer `conservices-internal-ca` | The cert-manager issuer that signs them. |
| `internalTLS.duration` | `2160h` (90 days) | Certificate lifetime. |
| `internalTLS.renewBefore` | `720h` (30 days) | How long before expiry cert-manager renews. |
| `internalTLS.caConfigMap` | `conservices-internal-ca` | ConfigMap (key `ca.crt`) with the CA the pods trust. |
| `internalTLS.ingressNginxAnnotations` | `false` | Legacy, only with `ingress.enabled: true`: adds the ingress-nginx annotations for HTTPS to the web app (`backend-protocol: HTTPS`, `proxy-ssl-verify`). The Gateway API route uses a `BackendTLSPolicy` instead. ingress-nginx is no longer maintained; do not use it. |
| `route.enabled`, `route.host`, `route.parentRefs`, `route.timeout` | `true`, `tasks.conservices.test`, Gateway `public` in `conservices-gateway` (listener `https`), `60s` | Exposes the web app through the Gateway API: an `HTTPRoute` and, with internal TLS, a `BackendTLSPolicy` that makes the gateway check `tasks-frontend`'s certificate. See [Exposing the web app](../../operations/helm.md#exposing-the-web-app-gateway-api). |
| `frontend.config` | `{}` | The web app's `/config.json` (sign-in address, client id; see [Web app settings](configuration.md#web-app-settings-configjson)), written to the ConfigMap `<release>-frontend-config`. Keys left out come from `config.AUTH_MODE`, `config.OIDC_ISSUER_URL` and `config.OIDC_CLIENT_ID` (else `tasks-spa`). |
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
kubectl create secret generic tasks-backend-tls -n conservices-tasks \
  --from-file=tls.crt=backend.crt --from-file=tls.key=backend.key --from-file=ca.crt=ca.crt
kubectl create secret generic tasks-frontend-tls -n conservices-tasks \
  --from-file=tls.crt=frontend.crt --from-file=tls.key=frontend.key --from-file=ca.crt=ca.crt
kubectl create configmap my-internal-ca -n conservices-tasks --from-file=ca.crt=ca.crt
```

```yaml
internalTLS:
  createCertificates: false
  caConfigMap: my-internal-ca
```

The backend certificate must be valid for `tasks-backend` and
`tasks-backend.conservices-tasks.svc.cluster.local`, the web app's for
`tasks-frontend.conservices-tasks.svc.cluster.local`. Replace them before
they expire; the backend picks up new files within a minute, nginx within
six hours.

## Option 3: Production on Docker

Read [Full stack on Docker (production)](../../operations/docker-production.md)
first, then add Tasks next to Den:

```yaml
# in compose.production.yml (services:)
  tasks-migrate:
    image: ghcr.io/aglelectronics/tasks-migrate:1.0.0-1
    <<: *hardening
    restart: "no"
    networks: [internal, egress]
    env_file: /etc/conservices/tasks-backend.env
    environment:
      APP_ENV: production

  tasks-backend:
    image: ghcr.io/aglelectronics/tasks-backend:1.0.0-1
    <<: *hardening
    depends_on:
      tasks-migrate: { condition: service_completed_successfully }
    networks: [internal, egress]
    env_file: /etc/conservices/tasks-backend.env   # DATABASE_URL, S3_*, TASKS_SERVICE_TOKEN
    environment:
      APP_ENV: production
      APP_BASE_URL: https://tasks.con.example.org
      HTTP_ADDR: ":8080"
      AUTH_MODE: oidc
      OIDC_ISSUER_URL: https://auth.con.example.org/realms/conservices
      OIDC_CLIENT_ID: tasks-spa
      OIDC_AUDIENCE: tasks-spa
      ACCESS_CONFIG_PATH: /etc/tasks/access-config.toml
      CORS_ALLOWED_ORIGINS: https://tasks.con.example.org
      S3_ENDPOINT: https://fsn1.your-objectstorage.com
      S3_BUCKET: example-tasks
      S3_REGION: fsn1
      DEN_INTERNAL_URL: http://den-backend:8080
    volumes:
      - ./tasks/access-config.toml:/etc/tasks/access-config.toml:ro

  tasks-frontend:
    image: ghcr.io/aglelectronics/tasks-frontend:1.0.0-1
    restart: unless-stopped
    networks: [internal]
    volumes:
      # infra/nginx.stack.conf from the Tasks repository: forwards /api/ to tasks-backend:8080.
      - ./tasks/nginx.stack.conf:/etc/nginx/conf.d/default.conf:ro
      # The web app's sign-in settings, served as /config.json.
      - ./tasks/config.json:/etc/conservices/config.json:ro
```

`./tasks/config.json` holds the web app's sign-in settings; the published
image names no domain. Keys: [Web app settings](configuration.md#web-app-settings-configjson).

```json
{
  "authMode": "oidc",
  "oidcAuthority": "https://auth.con.example.org/realms/conservices",
  "oidcClientId": "tasks-spa"
}
```

- One `tasks-backend` container only.
- Proxy block: `tasks.con.example.org { reverse_proxy tasks-frontend:8080 }`.
- Pinned tags, no default passwords, secrets only in the root-only env file.

## Option 4: Development on Docker

Never for real data. From the root of the `con-services` repository:

```powershell
docker compose --profile tasks up --build -d
```

Open <https://tasks.conservices.test> (or <http://localhost:3009>). A second
copy for development on the `tasks_dev` database runs with
`--profile tasks-dev` at <http://localhost:3010>.

On its own, with development sign-in:

```powershell
cd tasks
docker compose -f infra/docker-compose.yml up --build
```

| Service | Host port |
| --- | --- |
| backend | 8160 (dev copy 8161) |
| frontend | 3009 (dev copy 3010) |
| PostgreSQL (standalone stack only) | 5441 |

## Why the backend runs one replica

- The **per-user rate limiter** (about 20 requests a second per person)
  lives in the backend's memory; with two replicas each would count
  separately.
- The **due-date automation sweep** runs every minute in every backend
  process. The run history prevents most double runs, but two replicas
  would race each other.

So the Helm chart refuses any `backend.replicas` other than 1 and uses the
`Recreate` strategy. The frontend can run several replicas.

## Troubleshooting

**Attachments fail with `503`.** `S3_ENDPOINT` is empty; set it and the
`S3_*` keys to enable attachments.

**HR's department hook fails.** Timeout: HR has no egress rule to
`conservices-tasks`. `401` "invalid service token": the tokens differ.
`404`: `TASKS_SERVICE_TOKEN` is empty on Tasks.

**Saving a task says it was changed by someone else (`409`).** Someone
saved the task in the meantime; reload it and apply your change again. This
is the version check that prevents lost updates.

**Requests fail with `429`.** The per-user rate limit was hit, usually by a
script. Slow it down.

**Signed in, but no spaces.** Spaces start closed. A space must be shared
with you, one of your groups, or everyone; see the
[Admin guide](admin-guide.md#sharing).

**The backend pod stays in `Init:0/1`.** The migrate step cannot reach the
database: check `DATABASE_URL` and
`kubectl logs -n conservices-tasks deploy/tasks-backend -c migrate`.
For `no encryption`, see below.

**The backend exits with `tls: TLS_CERT_FILE and TLS_KEY_FILE must be set
together`.** Only one of the two is set, usually because one was added by
hand to `config:` or `backend.extraEnv`. Remove it: the chart sets both
while internal TLS is on, and neither while it is off.

**A pod stays `ContainerCreating`.** It waits for a volume that does not
exist yet: the Secret `tasks-backend-tls` or `tasks-frontend-tls` (made by
cert-manager) or the ConfigMap `conservices-internal-ca` (made by
trust-manager). `kubectl describe pod` shows `MountVolume.SetUp failed …
not found` under Events. Check:

```sh
kubectl get certificate -n conservices-tasks
kubectl describe certificate tasks-backend-tls -n conservices-tasks
kubectl get configmap conservices-internal-ca -n conservices-tasks
```

A certificate that is not `READY True` means cert-manager or the
ClusterIssuer `conservices-internal-ca` is missing; the events of
`kubectl describe certificate` say which. A missing ConfigMap means
trust-manager is not installed, or the namespace lacks the label:
`kubectl label namespace conservices-tasks app.kubernetes.io/part-of=conservices`.
Without cert-manager, see [Without cert-manager](#without-cert-manager).

**The web app answers `502 Bad Gateway` and its log shows `upstream SSL
certificate verify error`.** nginx could not check the backend's
certificate. Either the backend serves plain HTTP (its log has no
`tls enabled` line), or its certificate was signed by a CA other than the
one in `conservices-internal-ca` (with your own certificates: put the right
CA in the ConfigMap named by `internalTLS.caConfigMap`). See the error with
`kubectl logs -n conservices-tasks deploy/tasks-frontend`.

**Attachments or pairing fail with `x509: certificate signed by unknown
authority`.** The backend does not trust the internal CA when it calls
the S3 server or Den: `SSL_CERT_DIR` is missing, or a value in `config:` replaced
it with another folder. It must include `/etc/conservices-internal-ca`;
separate several folders with `:`. Check with
`kubectl get configmap tasks-config -n conservices-tasks -o yaml`.

**The migrate log shows `no pg_hba.conf entry for host "…", user "tasks",
database "tasks", no encryption`.** `DATABASE_URL` still ends in
`sslmode=disable`, and the platform's PostgreSQL accepts only TLS. Change
the end to
`?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt` in
your secret manager, then
`kubectl rollout restart -n conservices-tasks deploy/tasks-backend`. For a
managed database use `sslmode=verify-full&sslrootcert=<path to the provider's CA>`.
