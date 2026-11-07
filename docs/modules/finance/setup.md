# Set up Finance

This page installs Finance. Pick one of five ways:

| Option | When | Data safe? |
| --- | --- | --- |
| [Production cluster with Argo CD](../../deploy/apps.md) (recommended for production) | Production: the whole suite on a cluster managed from Git | Yes, CloudNativePG backups and Den's operator |
| [1. Kubernetes platform](#option-1-kubernetes-platform-recommended) | A cluster you run yourself, with Den running; also the local trial cluster from the quickstart | Yes, backed up by Den's operator |
| [2. Standalone on Kubernetes](#option-2-standalone-on-kubernetes) | Only Finance | Yes, if **you** back it up |
| [3. Production on Docker](#option-3-production-on-docker) | One server, no Kubernetes | Yes, with care |
| [4. Development on Docker](#option-4-development-on-docker) | Trying it out | **No**: public passwords |

The Argo CD path installs Finance together with Den and the other modules; see [Den and the modules](../../deploy/apps.md). A local Kubernetes cluster (the [quickstart](../../getting-started/den-quickstart.md)) is for trials only.

## What Finance needs

| Needs | Why |
| --- | --- |
| PostgreSQL 16 database and a login that owns it | Everything. Finance stores no files. |
| An OpenID Connect sign-in server (Keycloak) | Public client `finance-spa` and the group `finance-admin` (or the groups you list in `FINANCE_ACCESS_GROUPS`). |

Finance has **no access config file**: whoever is in one of the
`FINANCE_ACCESS_GROUPS` has full access; nobody else has any.

## Option 1: Kubernetes platform (recommended)

Den must be running first: [How the platform starts](../../getting-started/how-the-platform-starts.md).

1. **Register Finance in Den** (**Admin console → Modules → New module**,
   short name `finance`, tick **Create a database for it**) and copy the
   database URL into your secret manager. It ends in
   `?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt`:
   Finance connects with TLS and checks the database's certificate against
   the platform's internal CA, and the platform's PostgreSQL refuses
   connections without TLS.

2. **Create the namespace.** The `app.kubernetes.io/part-of` label lets
   trust-manager copy the internal CA into it ([Internal TLS](#internal-tls)).

    ```sh
    kubectl create namespace conservices-finance
    kubectl label namespace conservices-finance \
      conservices.io/tier=module conservices.io/module=finance \
      app.kubernetes.io/part-of=conservices \
      pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/warn=restricted
    ```

3. **Store the secret** and let an `ExternalSecret` create
   `finance-secrets` (see [Secrets](../../operations/secrets.md)):

    ```sh
    vault kv put secret/conservices/finance/backend \
      DATABASE_URL='postgres://finance:change-me@postgres.conservices-data.svc.cluster.local:5432/finance?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt'
    ```

    ```yaml
    apiVersion: external-secrets.io/v1
    kind: ExternalSecret
    metadata:
      name: finance-secrets
      namespace: conservices-finance
    spec:
      refreshInterval: 1h
      secretStoreRef: { name: vault, kind: SecretStore }
      target: { name: finance-secrets }
      dataFrom:
        - extract: { key: conservices/finance/backend }
    ```

4. **Install the chart:**

    ```yaml
    # my-finance.yaml
    image:
      backend:  { tag: "1.0.0-1" }
      frontend: { tag: "1.0.0-1" }
      migrate:  { tag: "1.0.0-1" }
    config:
      APP_BASE_URL: https://finance.example.org
      OIDC_ISSUER_URL: https://auth.example.org/realms/conservices
      CORS_ALLOWED_ORIGINS: https://finance.example.org
      FINANCE_ACCESS_GROUPS: finance-admin
    route:
      host: finance.example.org
    ```

    ```sh
    helm install finance deploy/charts/finance -n conservices-finance -f my-finance.yaml
    kubectl get pods -n conservices-finance -w
    ```

    Internal TLS is on by default (`internalTLS.enabled: true`) and the
    chart's `DEN_INTERNAL_URL` is
    `https://den-backend.conservices-den.svc.cluster.local:8080`. The
    cluster needs cert-manager, trust-manager and the platform's internal
    CA; see [Internal TLS](#internal-tls).

5. **Give people access:** add them to the `finance-admin` group in
   Keycloak, or grant the **Finance admin** role in HR's access picker.

6. **Pair with Den:** Den: **Modules → Pair** on the Finance row; Finance:
   **Settings → Den connection**, paste, **Connect**.

7. **Verify:**

    ```sh
    kubectl get certificate -n conservices-finance
    kubectl exec -n conservices-finance deploy/finance-frontend -- curl -s --cacert /etc/conservices-internal-ca/ca.crt https://finance-backend:8080/readyz
    ```

    ```text
    NAME                   READY   SECRET                 AGE
    finance-backend-tls    True    finance-backend-tls    40s
    finance-frontend-tls   True    finance-frontend-tls   40s
    ```

    ```json
    {"status":"ok","database":"ok"}
    ```

    The backend answers over HTTPS. `--cacert` makes `curl` check its

    certificate against the internal CA mounted in the web app pod; nginx

    does the same check on every `/api/` request.

    Sign in, create a customer and a draft invoice, issue it: it gets the
    number `FIN-0001`.

### Replicas

The backend keeps no state in the process. The chart still defaults to one
replica because each pod runs the migrate step when it starts, and pods
starting together would migrate at the same time.

## Option 2: Standalone on Kubernetes

Follow [Run one module on Kubernetes](../../getting-started/standalone-kubernetes.md),
skipping the access config step (Finance has none). Values:

```yaml
config:
  APP_BASE_URL: https://finance.example.org
  OIDC_ISSUER_URL: https://login.example.org/realms/conservices
  CORS_ALLOWED_ORIGINS: https://finance.example.org
  FINANCE_ACCESS_GROUPS: finance-admin
  DEN_INTERNAL_URL: ""
networkPolicy:
  den:  { enabled: false }
  data: { enabled: false }
  allowFromNamespaces: []
  extraEgress:
    - to: [{ ipBlock: { cidr: 10.20.0.0/24 } }]   # your database subnet
      ports: [{ protocol: TCP, port: 5432 }]
```

Internal TLS stays on by default and needs cert-manager, trust-manager and
an issuer in your cluster. Without them, turn it off or bring your own
certificates ([Without cert-manager](#without-cert-manager)). For a managed
database, end `DATABASE_URL` in
`?sslmode=verify-full&sslrootcert=<path to the provider's CA>` and mount
that CA file with `backend.extraVolumes` and `backend.extraVolumeMounts`.

**Back up the database yourself** (`pg_dump --format=custom`, encrypted,
kept elsewhere). Invoices must not be lost.

## Internal TLS

On Kubernetes, Finance encrypts the traffic **inside** the cluster as well,
not only between browsers and the Gateway. It is on by default
in the Helm chart. The shared how-to, including the platform setup and
certificate rotation, is [Internal TLS](../../operations/internal-tls.md).

What happens:

- **cert-manager** (a Kubernetes add-on that issues and renews
  certificates) issues `finance-backend-tls` and `finance-frontend-tls`
  from the ClusterIssuer `conservices-internal-ca`. They last 90 days and
  are renewed 30 days before they expire. Pods mount them at
  `/etc/conservices-tls` (`tls.crt`, `tls.key`, `ca.crt`).
- **trust-manager** copies the platform's internal CA certificate into the
  ConfigMap `conservices-internal-ca` (key `ca.crt`) in every namespace
  labelled `app.kubernetes.io/part-of: conservices`. Pods mount it at
  `/etc/conservices-internal-ca/ca.crt`.
- The **backend** serves HTTPS on port 8080 (`TLS_CERT_FILE`,
  `TLS_KEY_FILE`) and trusts the internal CA when it calls PostgreSQL and
  Den (`SSL_CERT_DIR`). It re-reads its certificate every minute, so a
  renewed one is used without a restart.
- The **web app**'s nginx serves HTTPS on port 8080, forwards `/api/` to the
  backend over HTTPS and checks the backend's certificate. It reloads every
  six hours to pick up a renewed certificate. Its Service listens on port
  443 (port name `https`).
- **The gateway** talks HTTPS to the web app and checks its certificate (a `BackendTLSPolicy`; with the legacy Ingress, the ingress controller does it).

Check it:

```sh
kubectl get certificate -n conservices-finance
kubectl get configmap conservices-internal-ca -n conservices-finance
kubectl logs -n conservices-finance deploy/finance-backend | grep "tls enabled"
```

Both certificates should be `READY True`, the ConfigMap should exist, and
the backend's `tls enabled` log line carries the certificate's expiry date
in `not_after`.

### Chart values

| Value | Default | What it does |
| --- | --- | --- |
| `internalTLS.enabled` | `true` | Turns internal TLS on or off for the backend, the web app and the Ingress. |
| `internalTLS.createCertificates` | `true` | `true`: the chart asks cert-manager for the two certificates. `false`: you create the Secrets `finance-backend-tls` and `finance-frontend-tls` yourself (keys `tls.crt`, `tls.key`, `ca.crt`). |
| `internalTLS.issuerRef` | ClusterIssuer `conservices-internal-ca` | The cert-manager issuer that signs them. |
| `internalTLS.duration` | `2160h` (90 days) | Certificate lifetime. |
| `internalTLS.renewBefore` | `720h` (30 days) | How long before expiry cert-manager renews. |
| `internalTLS.caConfigMap` | `conservices-internal-ca` | ConfigMap (key `ca.crt`) with the CA the pods trust. |
| `internalTLS.ingressNginxAnnotations` | `false` | Legacy, only with `ingress.enabled: true`: adds the ingress-nginx annotations for HTTPS to the web app (`backend-protocol: HTTPS`, `proxy-ssl-verify`). The Gateway API route uses a `BackendTLSPolicy` instead. ingress-nginx is no longer maintained; do not use it. |
| `route.enabled`, `route.host`, `route.parentRefs`, `route.timeout` | `true`, `finance.conservices.test`, Gateway `public` in `conservices-gateway` (listener `https`), `60s` | Exposes the web app through the Gateway API: an `HTTPRoute` and, with internal TLS, a `BackendTLSPolicy` that makes the gateway check `finance-frontend`'s certificate. See [Exposing the web app](../../operations/helm.md#exposing-the-web-app-gateway-api). |
| `frontend.config` | `{}` | The web app's `/config.json` (sign-in address, client id; see [Web app settings](configuration.md#web-app-settings-configjson)), written to the ConfigMap `<release>-frontend-config`. Keys left out come from `config.AUTH_MODE`, `config.OIDC_ISSUER_URL` and `config.OIDC_CLIENT_ID` (else `finance-spa`). |
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
  # The chart default, changed back to plain HTTP (or "" without Den):
  DEN_INTERNAL_URL: http://den-backend.conservices-den.svc.cluster.local:8080
```

**Bring your own certificates.** Create the two Secrets with any tool
(your own CA, a secret manager), each with `tls.crt`, `tls.key` and
`ca.crt`, and a ConfigMap with your CA under the key `ca.crt`:

```sh
kubectl create secret generic finance-backend-tls -n conservices-finance \
  --from-file=tls.crt=backend.crt --from-file=tls.key=backend.key --from-file=ca.crt=ca.crt
kubectl create secret generic finance-frontend-tls -n conservices-finance \
  --from-file=tls.crt=frontend.crt --from-file=tls.key=frontend.key --from-file=ca.crt=ca.crt
kubectl create configmap my-internal-ca -n conservices-finance --from-file=ca.crt=ca.crt
```

```yaml
internalTLS:
  createCertificates: false
  caConfigMap: my-internal-ca
```

The backend certificate must be valid for `finance-backend` and
`finance-backend.conservices-finance.svc.cluster.local`, the web app's for
`finance-frontend.conservices-finance.svc.cluster.local`. Replace them
before they expire; the backend picks up new files within a minute, nginx
within six hours.

## Option 3: Production on Docker

Read [Full stack on Docker (production)](../../operations/docker-production.md),
then add:

```yaml
# in compose.production.yml (services:)
  finance-migrate:
    image: ghcr.io/aglelectronics/finance-migrate:1.0.0-1
    <<: *hardening
    restart: "no"
    networks: [internal, egress]
    env_file: /etc/conservices/finance-backend.env   # DATABASE_URL
    environment:
      APP_ENV: production

  finance-backend:
    image: ghcr.io/aglelectronics/finance-backend:1.0.0-1
    <<: *hardening
    depends_on:
      finance-migrate: { condition: service_completed_successfully }
    networks: [internal, egress]
    env_file: /etc/conservices/finance-backend.env
    environment:
      APP_ENV: production
      APP_BASE_URL: https://finance.con.example.org
      HTTP_ADDR: ":8080"
      AUTH_MODE: oidc
      OIDC_ISSUER_URL: https://auth.con.example.org/realms/conservices
      OIDC_CLIENT_ID: finance-spa
      OIDC_AUDIENCE: finance-spa
      FINANCE_ACCESS_GROUPS: finance-admin
      CORS_ALLOWED_ORIGINS: https://finance.con.example.org
      DEN_INTERNAL_URL: http://den-backend:8080

  finance-frontend:
    image: ghcr.io/aglelectronics/finance-frontend:1.0.0-1
    restart: unless-stopped
    networks: [internal]
    volumes:
      # infra/nginx.stack.conf from the Finance repository: forwards /api/ to finance-backend:8080.
      - ./finance/nginx.stack.conf:/etc/nginx/conf.d/default.conf:ro
      # The web app's sign-in settings, served as /config.json.
      - ./finance/config.json:/etc/conservices/config.json:ro
```

`./finance/config.json` holds the web app's sign-in settings; the published
image names no domain. Keys: [Web app settings](configuration.md#web-app-settings-configjson).

```json
{
  "authMode": "oidc",
  "oidcAuthority": "https://auth.con.example.org/realms/conservices",
  "oidcClientId": "finance-spa"
}
```

Proxy block: `finance.con.example.org { reverse_proxy finance-frontend:8080 }`.

## Option 4: Development on Docker

Never for real data. Finance is part of the root stack without a profile,
so it starts with the default `docker compose up`. From the root of the
`con-services` repository:

```powershell
docker compose up --build -d finance-frontend
```

Open <https://finance.conservices.test> (or <http://localhost:3006>) and
sign in as a user in `finance-admin`. On its own:

```powershell
cd finance
docker compose -f infra/docker-compose.yml up --build
```

| Service | Host port |
| --- | --- |
| backend | 8130 |
| frontend | 3006 |
| PostgreSQL (standalone stack only) | 5438 |
| Adminer (with `infra/docker-compose.local.yml`) | 8083 |

!!! note "Backend and web app must use the same sign-in mode"
    Finance's `.env.example` sets `AUTH_MODE=oidc` against a Keycloak on
    `localhost:8085`, while the web app gets `infra/frontend-config/compose.json`
    (dev sign-in) as its `/config.json`. For header-only local work set
    `AUTH_MODE=dev`. For real sign-in keep `oidc`, copy `compose.json`, set
    `"authMode": "oidc"`, `"oidcAuthority": "http://localhost:8085/realms/conservices"`
    and `"oidcClientId": "finance-spa"`, and point `FRONTEND_CONFIG` in `.env`
    at the copy (see [Web app settings](configuration.md#web-app-settings-configjson)).

## Troubleshooting

**Signed in, but "you don't have access to Finance" (`403`).** You are not
in a group listed in `FINANCE_ACCESS_GROUPS`. Group names match with or
without Keycloak's leading `/`.

**The backend does not start: "S3_ENDPOINT is required when any S3_* var is
set".** Remove all `S3_*` settings (Finance uses no storage yet) or set all
of them.

**Issuing fails.** `409` "only drafts can be issued": the invoice is
already issued or void. `422`: the draft has no lines yet.

**A payment is refused.** `409`: payments go only on issued invoices.
`422` "amount exceeds what is still owed": the amount is more than the open
balance (the message gives it in cents).

**The backend exits with `tls: TLS_CERT_FILE and TLS_KEY_FILE must be set
together`.** Only one of the two is set, usually because one was added by
hand to `config:` or `backend.extraEnv`. Remove it: the chart sets both
while internal TLS is on, and neither while it is off.

**A pod stays `ContainerCreating`.** It waits for a volume that does not
exist yet: the Secret `finance-backend-tls` or `finance-frontend-tls`
(made by cert-manager) or the ConfigMap `conservices-internal-ca` (made by
trust-manager). `kubectl describe pod` shows `MountVolume.SetUp failed …
not found` under Events. Check:

```sh
kubectl get certificate -n conservices-finance
kubectl describe certificate finance-backend-tls -n conservices-finance
kubectl get configmap conservices-internal-ca -n conservices-finance
```

A certificate that is not `READY True` means cert-manager or the
ClusterIssuer `conservices-internal-ca` is missing; the events of
`kubectl describe certificate` say which. A missing ConfigMap means
trust-manager is not installed, or the namespace lacks the label:
`kubectl label namespace conservices-finance app.kubernetes.io/part-of=conservices`.
Without cert-manager, see [Without cert-manager](#without-cert-manager).

**The web app answers `502 Bad Gateway` and its log shows `upstream SSL
certificate verify error`.** nginx could not check the backend's
certificate. Either the backend serves plain HTTP (its log has no
`tls enabled` line), or its certificate was signed by a CA other than the
one in `conservices-internal-ca` (with your own certificates: put the right
CA in the ConfigMap named by `internalTLS.caConfigMap`). See the error with
`kubectl logs -n conservices-finance deploy/finance-frontend`.

**Pairing or the database fails with `x509: certificate signed by unknown
authority`.** The backend does not trust the internal CA: `SSL_CERT_DIR` is
missing, or a value in `config:` replaced it with another folder. It must
include `/etc/conservices-internal-ca`; separate several folders with `:`.
Check with `kubectl get configmap finance-config -n conservices-finance -o yaml`.

**The backend pod stays in `Init:CrashLoopBackOff` and the migrate log shows
`no pg_hba.conf entry for host "…", user "finance", database "finance", no
encryption`.** `DATABASE_URL` still ends in `sslmode=disable`, and the
platform's PostgreSQL accepts only TLS. Change the end to
`?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt` in
your secret manager, then
`kubectl rollout restart -n conservices-finance deploy/finance-backend`.
For a managed database use `sslmode=verify-full&sslrootcert=<path to the provider's CA>`.
