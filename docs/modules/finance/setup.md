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
| PostgreSQL 16 database and a login that owns it | Everything except the PDFs. |
| An S3-compatible bucket and a key with read and write on it | The PDFs of issued invoices and credit notes, stored once and never rewritten. Without it Finance runs, but nothing can be issued (`503 storage_unavailable`). Invoices are legal records: back the bucket up (Den's operator does, when the bucket is in its `FILES_S3_BUCKETS`). |
| An OpenID Connect sign-in server (Keycloak) | Public client `finance-spa` with an **audience mapper** that adds `finance-api` to its access tokens ([Audiences per API](../../concepts/authentication.md#audiences-per-api); realms from `con-services` have it), and the groups of the four roles: `finance_admin`, `finance_approver`, `finance_bookkeeper`, `finance_read-only` (or the groups you set in `FINANCE_*_GROUPS`). |
| A Den link encryption key | 32 random bytes (`openssl rand -base64 32`) in `DEN_LINK_ENCRYPTION_KEY`, kept in your secret manager. Finance encrypts its Den credential with it and does not start without it outside development. |
| Seller details | The name, address and VAT number printed on invoices, from Den → Module settings → Finance or Finance's Settings page. Issuing needs at least the name and address. |

Finance has **no access config file**: a person's groups decide their role
([Roles](configuration.md#roles)); someone with no Finance role has no
access.

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

3. **Create the PDF bucket and its key** at your S3 provider (platform:
   `<prefix>-conservices-finance`, see
   [Buckets and keys](../../deploy/data.md#buckets-and-keys)). The key needs
   read and write on that bucket only. Turn on versioning or Object Lock if
   your provider has it: Finance never rewrites a stored PDF, so neither
   gets in its way. Add the bucket to Den's operator backups
   (`FILES_S3_BUCKETS` in Den's chart, for example
   `den-data,<prefix>-conservices-finance`).

4. **Store the secrets** and let an `ExternalSecret` create
   `finance-secrets` (see [Secrets](../../operations/secrets.md)):

    ```sh
    vault kv put secret/conservices/finance/backend \
      DATABASE_URL='postgres://finance:change-me@postgres.conservices-data.svc.cluster.local:5432/finance?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt' \
      S3_ACCESS_KEY_ID='change-me' \
      S3_SECRET_ACCESS_KEY='change-me' \
      DEN_LINK_ENCRYPTION_KEY="$(openssl rand -base64 32)" \
      HR_SERVICE_TOKEN='change-me'
    ```

    `DEN_LINK_ENCRYPTION_KEY` is required: the backend pod does not start
    without it ([Den link encryption key](../../operations/secrets.md#den-link-encryption-key)).
    `HR_SERVICE_TOKEN` is optional and must equal HR's value; it lets HR
    read Finance's role catalog.

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

5. **Install the chart:**

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
      # The defaults; change them to map existing groups.
      FINANCE_ADMIN_GROUPS: finance_admin
      FINANCE_APPROVER_GROUPS: finance_approver
      FINANCE_BOOKKEEPER_GROUPS: finance_bookkeeper
      FINANCE_READONLY_GROUPS: finance_read-only
      # Pending accountant review: set these before the first invoice.
      FINANCE_CURRENCY: EUR
      FINANCE_DEFAULT_VAT_RATE_BP: "2000"
      FINANCE_APPROVAL_THRESHOLD_CENTS: "0"
      # The PDF bucket (keys from finance-secrets).
      S3_ENDPOINT: https://s3.conservices-data.svc.cluster.local:9000
      S3_BUCKET: acme-conservices-finance
    route:
      host: finance.example.org
    ```

    For an S3 outside the cluster set `S3_ENDPOINT` to it (for example
    `https://fsn1.your-objectstorage.com`), `networkPolicy.data.s3.enabled:
    false` and `networkPolicy.data.s3.external.fqdns` (see
    [External S3](../../operations/helm.md#external-s3-hetzner-object-storage)).

    ```sh
    helm install finance deploy/charts/finance -n conservices-finance -f my-finance.yaml
    kubectl get pods -n conservices-finance -w
    ```

    Internal TLS is on by default (`internalTLS.enabled: true`) and the
    chart's `DEN_INTERNAL_URL` is
    `https://den-backend.conservices-den.svc.cluster.local:8080`. The
    cluster needs cert-manager, trust-manager and the platform's internal
    CA; see [Internal TLS](#internal-tls).

6. **Give people roles** in HR's access picker (**Finance admin**,
   **Finance approver**, **Finance bookkeeper**, **Finance read-only**), or
   add them to the groups in Keycloak. Four-eyes approval needs at least one
   approver besides the bookkeepers; with the default threshold `0` every
   payment waits for one ([Bookkeeping](bookkeeping.md#four-eyes-approval)).

7. **Pair with Den:** Den: **Modules → Pair** on the Finance row; Finance:
   **Settings → Den connection**, paste, **Connect**.

8. **Set the seller details:** Den: **Module settings → Finance** (seller
   name, address, VAT number). Finance shows them on **Settings** as *from
   Den* within a minute; an admin can override each field there.

9. **Verify:**

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

    Sign in as a bookkeeper, create a customer and a draft invoice, issue
    it: it gets the number `FIN-0001` and a **PDF** button. Download the PDF
    and check the seller and customer details on it.

### Replicas

The backend keeps no state in the process. The chart still defaults to one
replica because each pod runs the migrate step when it starts, and pods
starting together would migrate at the same time.

## Option 2: Standalone on Kubernetes

Follow [Run one module on Kubernetes](../../getting-started/standalone-kubernetes.md),
skipping the access config step (Finance has none). Values:

```yaml
den: { mode: standalone }   # no Den: do not wait for pairing
config:
  APP_BASE_URL: https://finance.example.org
  OIDC_ISSUER_URL: https://login.example.org/realms/conservices
  CORS_ALLOWED_ORIGINS: https://finance.example.org
  DEN_INTERNAL_URL: ""
  S3_ENDPOINT: https://fsn1.your-objectstorage.com
  S3_BUCKET: example-finance-pdfs
  S3_USE_PATH_STYLE: "true"
networkPolicy:
  den:  { enabled: false }
  data:
    enabled: false
    s3:
      enabled: false
      external: { fqdns: ["fsn1.your-objectstorage.com", "*.fsn1.your-objectstorage.com"] }
  allowFromNamespaces: []
  extraEgress:
    - to: [{ ipBlock: { cidr: 10.20.0.0/24 } }]   # your database subnet
      ports: [{ protocol: TCP, port: 5432 }]
```

Without Den, set the seller details on Finance's **Settings** page (admin).

Internal TLS stays on by default and needs cert-manager, trust-manager and
an issuer in your cluster. Without them, turn it off or bring your own
certificates ([Without cert-manager](#without-cert-manager)). For a managed
database, end `DATABASE_URL` in
`?sslmode=verify-full&sslrootcert=<path to the provider's CA>` and mount
that CA file with `backend.extraVolumes` and `backend.extraVolumeMounts`.

**Back up the database and the PDF bucket yourself** (`pg_dump
--format=custom`, encrypted, kept elsewhere; bucket versioning or a copy to
another region). Invoices must not be lost.

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
| `frontend.securityHeaders.keycloakOrigin`, `.denOrigin`, `.s3Origin`, `.extraConnectSrc` | `""` (Keycloak: scheme and host of the sign-in address) | Origins the browser may contact, for the web app's Content Security Policy; see [Web app security headers](configuration.md#web-app-security-headers). |
| `existingSecret` | `finance-secrets` | The Secret with `DATABASE_URL`, the `S3_*` keys and `DEN_LINK_ENCRYPTION_KEY` (required unless `config.APP_ENV` is `development`; without it the backend pod stays in `CreateContainerConfigError`). |
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
    env_file: /etc/conservices/finance-backend.env   # DATABASE_URL, S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY, DEN_LINK_ENCRYPTION_KEY
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
      OIDC_AUDIENCE: finance-api
      CORS_ALLOWED_ORIGINS: https://finance.con.example.org
      DEN_INTERNAL_URL: http://den-backend:8080
      # Managed S3 for the PDFs (keys in finance-backend.env).
      S3_ENDPOINT: https://fsn1.your-objectstorage.com
      S3_BUCKET: example-finance-pdfs

  finance-frontend:
    image: ghcr.io/aglelectronics/finance-frontend:1.0.0-1
    restart: unless-stopped
    networks: [internal]
    environment:
      # Content Security Policy: the browser may call the sign-in server.
      KEYCLOAK_ORIGIN: https://auth.con.example.org
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

Open <https://finance.conservices.test> (or <http://localhost:3006>). The
dev realm has three Finance users (dev-only passwords): `admin` /
`adminadmin` (Finance admin), `alice` / `alicealice` (approver) and `bob` /
`bobbob` (bookkeeper). Request a payment as `bob`, then approve it as
`alice`. The PDFs go to the dev SeaweedFS bucket `finance-data-dev`. To
check the money loop end to end, run `scripts/smoke-finance.ps1`
([Troubleshooting](#troubleshooting)). On its own:

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
    Finance's `infra/docker-compose.yml` runs the backend with
    `APP_ENV=development` and `AUTH_MODE=dev`, matching the web app's
    `infra/frontend-config/compose.json` (dev sign-in). Finance's
    `.env.example` sets `AUTH_MODE=oidc` against a Keycloak on
    `localhost:8085` for running the backend on the host. `AUTH_MODE=dev`
    works only with `APP_ENV=development`; both default to the safe values
    (`oidc`, `production`). For real sign-in keep `oidc`, copy `compose.json`, set
    `"authMode": "oidc"`, `"oidcAuthority": "http://localhost:8085/realms/conservices"`
    and `"oidcClientId": "finance-spa"`, and point `FRONTEND_CONFIG` in `.env`
    at the copy (see [Web app settings](configuration.md#web-app-settings-configjson)).

## Troubleshooting

**Signed in, but "you don't have access to Finance" (`403`).** None of
your groups grants a Finance role. `GET /api/me` lists your `groups`; give
the person a role in HR or check `FINANCE_*_GROUPS`. Group names match with
or without Keycloak's leading `/`. Only the `OIDC_GROUPS_CLAIM` claim counts
(default `groups`): a role given as a Keycloak *role* instead of a group
no longer works. After the update from the single
`finance-admin` group, move its members to `finance_admin`.

**The backend does not start: `DEN_LINK_ENCRYPTION_KEY is required unless
APP_ENV=development`.** Generate a key (`openssl rand -base64 32`), add it to
`finance-secrets` through your secret manager and restart
([Den link encryption key](../../operations/secrets.md#den-link-encryption-key)).
On Kubernetes the pod shows `CreateContainerConfigError` with
`couldn't find key DEN_LINK_ENCRYPTION_KEY in Secret` instead. For local
work set `APP_ENV=development`.

**The backend does not start: `AUTH_MODE=dev lets anyone sign in as anyone
and is only allowed with APP_ENV=development`.** `APP_ENV` now defaults to
`production`. For local work set `APP_ENV=development`; anywhere else use
`AUTH_MODE=oidc`.

**Every API call answers `401` `invalid token` after the upgrade.** Finance
now accepts only access tokens with the audience `finance-api`. Add the
audience mapper to the `finance-spa` client
([Audiences per API](../../concepts/authentication.md#audiences-per-api)),
then sign out and in again. A script that sends the `id_token` must send the
`access_token` instead.

**Sign-in does not start, and the browser console says *Refused to connect
to 'https://auth…'*.** The web app's Content Security Policy does not list
the sign-in server. Set `KEYCLOAK_ORIGIN` on the web app container (Helm:
`frontend.securityHeaders.keycloakOrigin`, or a correct `oidcAuthority`)
and restart it ([Web app security headers](configuration.md#web-app-security-headers)).

**Pairing fails with `pairing with Den at … is not allowed here`.** The
backend has no `DEN_INTERNAL_URL` and Den's host is not in
`DEN_ALLOWED_HOSTS`. Set one of them; outside development the pasted URL
must use `https://`.

**Settings says *Den rejected this module's credential*.** The Finance
module was removed in Den or its credential revoked. Finance keeps its last
settings from Den but gets no changes. In Den, open **Modules → Pair** on
the Finance row, then paste the new URL under **Settings → Den connection
→ Pair again**. Finance never pairs again by itself.

**The backend does not start: "S3_ENDPOINT is required when any S3_* var is
set".** Set all of `S3_ENDPOINT`, `S3_BUCKET`, `S3_ACCESS_KEY_ID` and
`S3_SECRET_ACCESS_KEY`, or none.

**The backend logs `S3_* not set: invoices and credit notes cannot be
issued`.** Expected without S3; configure it to issue. Issuing answers
`503 storage_unavailable` until then.

**Issuing answers `503 storage_unavailable` with S3 set.** The backend
cannot write to the bucket: wrong endpoint, key without write permission,
bucket missing, or the network policy blocks the S3 port
(`networkPolicy.data.s3`). Nothing was issued; fix it and issue again.
`kubectl logs deploy/finance-backend` shows the S3 answer.

**Issuing answers `422` "the seller name and address are needed".** Set
them in Den → Module settings → Finance or on Finance's Settings page.

**Issuing fails otherwise.** `409` "only drafts can be issued": the invoice
is already issued or void. `409 period_closed`: the issue date is in a
closed month. `422`: no lines yet, or a date out of range.

**A payment answers `202` instead of `201`.** It waits for a second person
on **Approvals** (default threshold `0`). Raise
`FINANCE_APPROVAL_THRESHOLD_CENTS` if small amounts should not need it.

**A payment is refused.** `409`: payments go only on issued invoices, or
the date is in a closed month. `422` "amount exceeds what is still owed":
the amount is more than the open balance (the message gives it in cents).

**Downloading a PDF answers `500`.** The stored file is missing or changed
(its SHA-256 does not match). Restore it from the bucket's backup under the
same key (`invoices/<invoice id>/<number>.pdf`).

**`scripts/smoke-finance.ps1` fails.** It needs the root stack running
(`docker compose up -d`), the dev realm users `bob` and `alice`, and the
`finance-data-dev` bucket. The step that failed is printed with the API's
answer.

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
