# Set up Learn

This page installs Learn. Pick one of five ways:

| Option | When | Data safe? |
| --- | --- | --- |
| [Production cluster with Argo CD](../../deploy/apps.md) (recommended for production) | Production: the whole suite on a cluster managed from Git | Yes, CloudNativePG backups and Den's operator |
| [1. Kubernetes platform](#option-1-kubernetes-platform-recommended) | A cluster you run yourself, with Den running; also the local trial cluster from the quickstart | Yes, backed up by Den's operator |
| [2. Standalone on Kubernetes](#option-2-standalone-on-kubernetes) | Only Learn | Yes, if **you** back it up |
| [3. Production on Docker](#option-3-production-on-docker) | One server, no Kubernetes | Yes, with care |
| [4. Development on Docker](#option-4-development-on-docker) | Trying it out | **No**: public passwords |

The Argo CD path installs Learn together with Den and the other modules; see [Den and the modules](../../deploy/apps.md). A local Kubernetes cluster (the [quickstart](../../getting-started/den-quickstart.md)) is for trials only.

## What Learn needs

| Needs | Why |
| --- | --- |
| PostgreSQL 16 database and a login that owns it | Courses, enrolments, attempts, certificates. |
| An S3-compatible bucket and keys (optional) | Course media. Without it, uploads answer `503`. Browsers upload and download directly with presigned links, so the bucket must be reachable from browsers at `S3_PUBLIC_BASE_URL`. |
| An OpenID Connect sign-in server (Keycloak) | Public client `learn-spa`; groups `learn-admin`, `learn-trainer`, `learn-coordinator`. |
| A confidential Keycloak client (optional) | `learn-provisioner`, with read access to groups and members, for group sync. |
| SMTP (optional) | Reminder and notice emails. |

## Option 1: Kubernetes platform (recommended)

Den must be running first: [How the platform starts](../../getting-started/how-the-platform-starts.md).

1. **Register Learn in Den** (**Admin console → Modules → New module**, short
   name `learn`, tick **Create a database for it**) and copy the database URL
   into your secret manager. It ends in
   `?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt`:
   Learn connects with TLS and checks the database's certificate against
   the platform's internal CA, and the platform's PostgreSQL refuses
   connections without TLS.

2. **Create the bucket** (for example `learn-data`) with keys limited to it,
   allow browser access from your Learn address (CORS on the bucket), and add
   it to the Den operator's `FILES_S3_BUCKETS`.

3. **Create the namespace.** The `app.kubernetes.io/part-of` label lets
   trust-manager copy the internal CA into it ([Internal TLS](#internal-tls)).

    ```sh
    kubectl create namespace conservices-learn
    kubectl label namespace conservices-learn \
      conservices.io/tier=module conservices.io/module=learn \
      app.kubernetes.io/part-of=conservices \
      pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/warn=restricted
    ```

4. **Store the secrets** and let an `ExternalSecret` create `learn-secrets`
   (see [Secrets](../../operations/secrets.md)). Regenerate the
   `learn-provisioner` client secret in Keycloak first (**Clients →
   learn-provisioner → Credentials → Regenerate**); the realm file ships a
   public development value.

    ```sh
    vault kv put secret/conservices/learn/backend \
      DATABASE_URL='postgres://learn:change-me@postgres.conservices-data.svc.cluster.local:5432/learn?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt' \
      S3_ACCESS_KEY_ID=change-me S3_SECRET_ACCESS_KEY=change-me \
      KEYCLOAK_CLIENT_SECRET=change-me \
      LEARN_SERVICE_TOKEN="$(openssl rand -hex 32)" \
      SMTP_PASSWORD=change-me
    ```

    ```yaml
    apiVersion: external-secrets.io/v1
    kind: ExternalSecret
    metadata:
      name: learn-secrets
      namespace: conservices-learn
    spec:
      refreshInterval: 1h
      secretStoreRef: { name: vault, kind: SecretStore }
      target: { name: learn-secrets }
      dataFrom:
        - extract: { key: conservices/learn/backend }
    ```

5. **Create the access config** from `infra/access-config.toml` in the Learn
   repository:

    ```sh
    kubectl create configmap learn-access-config -n conservices-learn \
      --from-file=access-config.toml=access-config.toml
    ```

6. **Install the chart:**

    ```yaml
    # my-learn.yaml
    image:
      backend:  { tag: "1.0.0-1" }
      frontend: { tag: "1.0.0-1" }
      migrate:  { tag: "1.0.0-1" }
    config:
      APP_BASE_URL: https://learn.example.org
      PUBLIC_BASE_URL: https://learn.example.org
      OIDC_ISSUER_URL: https://auth.example.org/realms/conservices
      CORS_ALLOWED_ORIGINS: https://learn.example.org,https://den.example.org
      S3_BUCKET: learn-data
      S3_PUBLIC_BASE_URL: https://s3.example.org
      SMTP_HOST: smtp.example.org
      SMTP_USERNAME: learn@example.org
      SMTP_FROM: no-reply@example.org
    route:
      host: learn.example.org
    networkPolicy:
      extraEgress:
        - to: [{ ipBlock: { cidr: 203.0.113.10/32 } }]   # your SMTP server
          ports: [{ protocol: TCP, port: 587 }]
    ```

    ```sh
    helm install learn deploy/charts/learn -n conservices-learn -f my-learn.yaml
    kubectl get pods -n conservices-learn -w
    ```

    Internal TLS is on by default (`internalTLS.enabled: true`), and the
    chart's defaults reach the platform services over HTTPS
    (`S3_ENDPOINT: https://s3.conservices-data.svc.cluster.local:9000`,
    `KEYCLOAK_BASE_URL: https://keycloak.conservices-identity.svc.cluster.local:8443`,
    `DEN_INTERNAL_URL: https://den-backend.conservices-den.svc.cluster.local:8080`).
    The cluster needs cert-manager, trust-manager and the platform's
    internal CA; see [Internal TLS](#internal-tls).

7. **Let Learn reach Keycloak's admin API.** The chart adds the egress rule
   from Learn to `keycloak` in `conservices-identity` on port 8443
   (Keycloak's HTTPS port).
   Keycloak's namespace also needs an **ingress** rule admitting Learn's
   backend; that rule belongs to the platform manifests (see
   [Network policies](../../operations/network-policies.md#calls-between-modules)).
   Without it, group sync logs errors and everything else works. To turn
   group sync off, leave `KEYCLOAK_BASE_URL` empty and set
   `networkPolicy.keycloakAdmin.enabled: false`.

8. **Pair with Den:** Den: **Modules → Pair** on the Learn row; Learn (as
   `learn-admin`): **Settings → Den connection**, paste, **Connect**.

9. **Connect HR** (only if you run HR). In HR's settings:

    ```text
    QUALIFICATION_CATALOG_SOURCES=learn=https://learn-backend.conservices-learn.svc.cluster.local:8080/api/qualification-catalog
    LEARN_HOLDINGS_URL=https://learn-backend.conservices-learn.svc.cluster.local:8080/api/internal/holdings
    LEARN_SERVICE_TOKEN=<the same token as Learn's>
    ```

    The Learn chart already admits HR's backend. HR's namespace needs the
    matching egress rule to `conservices-learn` port 8080.

10. **Verify:**

    ```sh
    kubectl get certificate -n conservices-learn
    kubectl exec -n conservices-learn deploy/learn-frontend -- curl -s --cacert /etc/conservices-internal-ca/ca.crt https://learn-backend:8080/api/health
    ```

    ```text
    NAME                 READY   SECRET               AGE
    learn-backend-tls    True    learn-backend-tls    40s
    learn-frontend-tls   True    learn-frontend-tls   40s
    ```

    ```json
    {"status":"ok","database":"ok","version":"1.0.0-1","uptime_sec":40}
    ```

    The backend answers over HTTPS. `--cacert` makes `curl` check its

    certificate against the internal CA mounted in the web app pod; nginx

    does the same check on every `/api/` request.

    Sign in as a trainer, create a course with one page, publish it, enrol
    someone, and check their progress after they open the page.

### Replicas

Learn's background jobs (group sync and reminders) take a PostgreSQL lock,
so only one pod runs them at a time; the app itself could run several
replicas. The chart still defaults to **one**, because each pod runs the
migrate step when it starts and pods starting together would migrate at the
same time. Scale only after moving migrations to a separate Job.

## Option 2: Standalone on Kubernetes

Follow [Run one module on Kubernetes](../../getting-started/standalone-kubernetes.md)
with these Learn values:

```yaml
config:
  APP_BASE_URL: https://learn.example.org
  PUBLIC_BASE_URL: https://learn.example.org
  OIDC_ISSUER_URL: https://login.example.org/realms/conservices
  OIDC_EXTRA_AUDIENCES: ""            # no Den web app
  CORS_ALLOWED_ORIGINS: https://learn.example.org
  S3_ENDPOINT: https://fsn1.your-objectstorage.com
  S3_BUCKET: example-learn
  S3_REGION: fsn1
  S3_PUBLIC_BASE_URL: ""             # managed S3 is already browser-reachable
  KEYCLOAK_BASE_URL: ""              # group sync off (or your Keycloak)
  DEN_INTERNAL_URL: ""
networkPolicy:
  den:  { enabled: false }
  data: { enabled: false }
  keycloakAdmin: { enabled: false }
  allowFromNamespaces: []
  extraEgress:
    - to: [{ ipBlock: { cidr: 10.20.0.0/24 } }]   # your database subnet
      ports: [{ protocol: TCP, port: 5432 }]
    - to: [{ ipBlock: { cidr: 0.0.0.0/0 } }]      # managed S3 over HTTPS
      ports: [{ protocol: TCP, port: 443 }]
```

`learn-secrets` needs `DATABASE_URL` and the `S3_*` keys;
`LEARN_SERVICE_TOKEN` can stay empty (it turns the holdings endpoint off).
**Back up the database and bucket yourself.**

Internal TLS stays on by default and needs cert-manager, trust-manager and
an issuer in your cluster. Without them, turn it off or bring your own
certificates ([Without cert-manager](#without-cert-manager)). For a managed
database, end `DATABASE_URL` in
`?sslmode=verify-full&sslrootcert=<path to the provider's CA>` and mount
that CA file with `backend.extraVolumes` and `backend.extraVolumeMounts`.

## Internal TLS

On Kubernetes, Learn encrypts the traffic **inside** the cluster as well,
not only between browsers and the Gateway. It is on by default
in the Helm chart. The shared how-to, including the platform setup and
certificate rotation, is [Internal TLS](../../operations/internal-tls.md).

What happens:

- **cert-manager** (a Kubernetes add-on that issues and renews
  certificates) issues `learn-backend-tls` and `learn-frontend-tls` from
  the ClusterIssuer `conservices-internal-ca`. They last 90 days and are
  renewed 30 days before they expire. Pods mount them at
  `/etc/conservices-tls` (`tls.crt`, `tls.key`, `ca.crt`).
- **trust-manager** copies the platform's internal CA certificate into the
  ConfigMap `conservices-internal-ca` (key `ca.crt`) in every namespace
  labelled `app.kubernetes.io/part-of: conservices`. Pods mount it at
  `/etc/conservices-internal-ca/ca.crt`.
- The **backend** serves HTTPS on port 8080 (`TLS_CERT_FILE`,
  `TLS_KEY_FILE`) and trusts the internal CA when it calls PostgreSQL,
  the S3 server, Keycloak and Den (`SSL_CERT_DIR`). It re-reads its certificate
  every minute, so a renewed one is used without a restart.
- The **web app**'s nginx serves HTTPS on port 8080, forwards `/api/` to the
  backend over HTTPS and checks the backend's certificate. It reloads every
  six hours to pick up a renewed certificate. Its Service listens on port
  443 (port name `https`).
- **The gateway** talks HTTPS to the web app and checks its certificate (a `BackendTLSPolicy`; with the legacy Ingress, the ingress controller does it).

Check it:

```sh
kubectl get certificate -n conservices-learn
kubectl get configmap conservices-internal-ca -n conservices-learn
kubectl logs -n conservices-learn deploy/learn-backend | grep "tls enabled"
```

Both certificates should be `READY True`, the ConfigMap should exist, and
the backend's `tls enabled` log line carries the certificate's expiry date
in `not_after`.

### Chart values

| Value | Default | What it does |
| --- | --- | --- |
| `internalTLS.enabled` | `true` | Turns internal TLS on or off for the backend, the web app and the Ingress. |
| `internalTLS.createCertificates` | `true` | `true`: the chart asks cert-manager for the two certificates. `false`: you create the Secrets `learn-backend-tls` and `learn-frontend-tls` yourself (keys `tls.crt`, `tls.key`, `ca.crt`). |
| `internalTLS.issuerRef` | ClusterIssuer `conservices-internal-ca` | The cert-manager issuer that signs them. |
| `internalTLS.duration` | `2160h` (90 days) | Certificate lifetime. |
| `internalTLS.renewBefore` | `720h` (30 days) | How long before expiry cert-manager renews. |
| `internalTLS.caConfigMap` | `conservices-internal-ca` | ConfigMap (key `ca.crt`) with the CA the pods trust. |
| `internalTLS.ingressNginxAnnotations` | `false` | Legacy, only with `ingress.enabled: true`: adds the ingress-nginx annotations for HTTPS to the web app (`backend-protocol: HTTPS`, `proxy-ssl-verify`). The Gateway API route uses a `BackendTLSPolicy` instead. ingress-nginx is no longer maintained; do not use it. |
| `route.enabled`, `route.host`, `route.parentRefs`, `route.timeout` | `true`, `learn.conservices.test`, Gateway `public` in `conservices-gateway` (listener `https`), `60s` | Exposes the web app through the Gateway API: an `HTTPRoute` and, with internal TLS, a `BackendTLSPolicy` that makes the gateway check `learn-frontend`'s certificate. See [Exposing the web app](../../operations/helm.md#exposing-the-web-app-gateway-api). |
| `frontend.config` | `{}` | The web app's `/config.json` (sign-in address, client id; see [Web app settings](configuration.md#web-app-settings-configjson)), written to the ConfigMap `<release>-frontend-config`. Keys left out come from `config.AUTH_MODE`, `config.OIDC_ISSUER_URL` and `config.OIDC_CLIENT_ID` (else `learn-spa`). |
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
kubectl create secret generic learn-backend-tls -n conservices-learn \
  --from-file=tls.crt=backend.crt --from-file=tls.key=backend.key --from-file=ca.crt=ca.crt
kubectl create secret generic learn-frontend-tls -n conservices-learn \
  --from-file=tls.crt=frontend.crt --from-file=tls.key=frontend.key --from-file=ca.crt=ca.crt
kubectl create configmap my-internal-ca -n conservices-learn --from-file=ca.crt=ca.crt
```

```yaml
internalTLS:
  createCertificates: false
  caConfigMap: my-internal-ca
```

The backend certificate must be valid for `learn-backend` and
`learn-backend.conservices-learn.svc.cluster.local`, the web app's for
`learn-frontend.conservices-learn.svc.cluster.local`. Replace them before
they expire; the backend picks up new files within a minute, nginx within
six hours.

## Option 3: Production on Docker

Read [Full stack on Docker (production)](../../operations/docker-production.md),
then add:

```yaml
# in compose.production.yml (services:)
  learn-migrate:
    image: ghcr.io/aglelectronics/learn-migrate:1.0.0-1
    <<: *hardening
    restart: "no"
    networks: [internal, egress]
    env_file: /etc/conservices/learn-backend.env
    environment:
      APP_ENV: production

  learn-backend:
    image: ghcr.io/aglelectronics/learn-backend:1.0.0-1
    <<: *hardening
    depends_on:
      learn-migrate: { condition: service_completed_successfully }
    networks: [internal, egress]
    # DATABASE_URL, S3_*, KEYCLOAK_CLIENT_SECRET, LEARN_SERVICE_TOKEN, SMTP_PASSWORD
    env_file: /etc/conservices/learn-backend.env
    environment:
      APP_ENV: production
      APP_BASE_URL: https://learn.con.example.org
      PUBLIC_BASE_URL: https://learn.con.example.org
      HTTP_ADDR: ":8080"
      AUTH_MODE: oidc
      OIDC_ISSUER_URL: https://auth.con.example.org/realms/conservices
      OIDC_CLIENT_ID: learn-spa
      OIDC_AUDIENCE: learn-spa
      OIDC_EXTRA_AUDIENCES: den-spa
      ACCESS_CONFIG_PATH: /etc/learn/access-config.toml
      CORS_ALLOWED_ORIGINS: https://learn.con.example.org,https://den.con.example.org
      S3_ENDPOINT: https://fsn1.your-objectstorage.com
      S3_BUCKET: example-learn
      S3_REGION: fsn1
      SMTP_HOST: smtp.example.org
      SMTP_USERNAME: learn@example.org
      SMTP_FROM: no-reply@example.org
      KEYCLOAK_BASE_URL: http://keycloak:8080
      KEYCLOAK_REALM: conservices
      KEYCLOAK_CLIENT_ID: learn-provisioner
      DEN_INTERNAL_URL: http://den-backend:8080
    volumes:
      - ./learn/access-config.toml:/etc/learn/access-config.toml:ro

  learn-frontend:
    image: ghcr.io/aglelectronics/learn-frontend:1.0.0-1
    restart: unless-stopped
    networks: [internal]
    volumes:
      # infra/nginx.stack.conf from the Learn repository: forwards /api/ to learn-backend:8080.
      - ./learn/nginx.stack.conf:/etc/nginx/conf.d/default.conf:ro
      # The web app's sign-in settings, served as /config.json.
      - ./learn/config.json:/etc/conservices/config.json:ro
```

`./learn/config.json` holds the web app's sign-in settings; the published
image names no domain. Keys: [Web app settings](configuration.md#web-app-settings-configjson).

```json
{
  "authMode": "oidc",
  "oidcAuthority": "https://auth.con.example.org/realms/conservices",
  "oidcClientId": "learn-spa"
}
```

Proxy block: `learn.con.example.org { reverse_proxy learn-frontend:8080 }`.
Keep one `learn-backend` container (it migrates through `learn-migrate`
anyway).

## Option 4: Development on Docker

Never for real data. From the root of the `con-services` repository:

```powershell
docker compose --profile den --profile learn up --build -d
```

Learn runs at <https://learn.conservices.test> (or <http://localhost:3005>)
with the development Keycloak, S3 server (SeaweedFS) and Mailpit. On its own, with
development sign-in (pick any name; default groups `learn-admin`):

```powershell
cd learn
docker compose -f infra/docker-compose.yml up --build
```

| Service | Host port |
| --- | --- |
| backend | 8120 |
| frontend | 3005 |
| PostgreSQL (standalone stack only) | 5437 |
| S3 server, SeaweedFS (standalone stack only) | 9030 |
| Mailpit SMTP (standalone stack only) | 1026 |

## Troubleshooting

**Media uploads fail with `503`.** `S3_ENDPOINT` is empty. **Uploads fail
in the browser** (CORS or network error): the browser cannot reach the
bucket at the presigned address; set `S3_PUBLIC_BASE_URL` to an address
browsers can reach and allow your Learn origin in the bucket's CORS rules.

**Group sync does nothing.** One of `KEYCLOAK_BASE_URL`, `KEYCLOAK_REALM`,
`KEYCLOAK_CLIENT_ID`, `KEYCLOAK_CLIENT_SECRET` is empty (all four turn it
on), the client lacks group read rights, or a network policy blocks
Keycloak (timeouts in the log).

**Den's portal shows no Learn to-dos.** Den's web app calls Learn from the
browser: `OIDC_EXTRA_AUDIENCES` must include `den-spa` and
`CORS_ALLOWED_ORIGINS` Den's address.

**HR grants roles without checking training.** HR has no
`LEARN_HOLDINGS_URL`/`LEARN_SERVICE_TOKEN`, or the tokens differ (`401`), or
Learn's token is empty (`404`).

**No reminder emails.** `SMTP_HOST` is empty, or the egress rule to your SMTP
server is missing. Reminders run hourly; an admin can trigger them with
`POST /api/v1/reminders/run`.

**The backend exits with `tls: TLS_CERT_FILE and TLS_KEY_FILE must be set
together`.** Only one of the two is set, usually because one was added by
hand to `config:` or `backend.extraEnv`. Remove it: the chart sets both
while internal TLS is on, and neither while it is off.

**A pod stays `ContainerCreating`.** It waits for a volume that does not
exist yet: the Secret `learn-backend-tls` or `learn-frontend-tls` (made by
cert-manager) or the ConfigMap `conservices-internal-ca` (made by
trust-manager). `kubectl describe pod` shows `MountVolume.SetUp failed …
not found` under Events. Check:

```sh
kubectl get certificate -n conservices-learn
kubectl describe certificate learn-backend-tls -n conservices-learn
kubectl get configmap conservices-internal-ca -n conservices-learn
```

A certificate that is not `READY True` means cert-manager or the
ClusterIssuer `conservices-internal-ca` is missing; the events of
`kubectl describe certificate` say which. A missing ConfigMap means
trust-manager is not installed, or the namespace lacks the label:
`kubectl label namespace conservices-learn app.kubernetes.io/part-of=conservices`.
Without cert-manager, see [Without cert-manager](#without-cert-manager).

**The web app answers `502 Bad Gateway` and its log shows `upstream SSL
certificate verify error`.** nginx could not check the backend's
certificate. Either the backend serves plain HTTP (its log has no
`tls enabled` line), or its certificate was signed by a CA other than the
one in `conservices-internal-ca` (with your own certificates: put the right
CA in the ConfigMap named by `internalTLS.caConfigMap`). See the error with
`kubectl logs -n conservices-learn deploy/learn-frontend`.

**Group sync, uploads or pairing fail with `x509: certificate signed by
unknown authority`.** The backend does not trust the internal CA when it
calls Keycloak, the S3 server or Den: `SSL_CERT_DIR` is missing, or a value in
`config:` replaced it with another folder. It must include
`/etc/conservices-internal-ca`; separate several folders with `:`. Check
with `kubectl get configmap learn-config -n conservices-learn -o yaml`.

**The backend pod stays in `Init:CrashLoopBackOff` and the migrate log shows
`no pg_hba.conf entry for host "…", user "learn", database "learn", no
encryption`.** `DATABASE_URL` still ends in `sslmode=disable`, and the
platform's PostgreSQL accepts only TLS. Change the end to
`?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt` in
your secret manager, then
`kubectl rollout restart -n conservices-learn deploy/learn-backend`. For a
managed database use `sslmode=verify-full&sslrootcert=<path to the provider's CA>`.
