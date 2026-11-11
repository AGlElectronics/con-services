# Set up Wiki

This page installs Wiki. Pick one of five ways:

| Option | When | Data safe? |
| --- | --- | --- |
| [Production cluster with Argo CD](../../deploy/apps.md) (recommended for production) | Production: the whole suite on a cluster managed from Git | Yes, CloudNativePG backups and Den's operator |
| [1. Kubernetes platform](#option-1-kubernetes-platform-recommended) | A cluster you run yourself, with Den already running; also the local trial cluster from the quickstart | Yes, backed up by Den's operator |
| [2. Standalone on Kubernetes](#option-2-standalone-on-kubernetes) | Only Wiki, your own PostgreSQL, S3 and sign-in | Yes, if **you** back it up |
| [3. Production on Docker](#option-3-production-on-docker) | One server without Kubernetes | Yes, with care |
| [4. Development on Docker](#option-4-development-on-docker) | Trying it out, development | **No**: public passwords |

The Argo CD path installs Wiki together with Den and the other modules; see [Den and the modules](../../deploy/apps.md). A local Kubernetes cluster (the [quickstart](../../getting-started/den-quickstart.md)) is for trials only.

Whatever you pick, read [Why the backend must stay at one replica](#why-the-backend-must-stay-at-one-replica).

## What Wiki needs

| Needs | Why |
| --- | --- |
| PostgreSQL 16 database and a login that owns it | Spaces, pages, grants, comments, search text. |
| An S3-compatible bucket and keys for it | **Page content** and uploads. Without it, live editing, uploads, history and duplication answer `503`. |
| An OpenID Connect sign-in server (Keycloak) | A public client `wiki-spa` and the groups `wiki-admin`, `wiki-editor`. |
| A small persistent disk for the backend | The edit buffer (`WIKI_BUFFER_DIR`): the last few seconds of edits before they go to S3. |
| Websocket support in every proxy | Live editing uses a websocket at `/api/v1/pages/<id>/live`. |

## Option 1: Kubernetes platform (recommended)

Wiki joins a running platform as its own namespace with its own Helm chart.
You need Den up and checked first: see
[How the platform starts](../../getting-started/how-the-platform-starts.md).

1. **Register Wiki in Den and create its database.** In Den: **Admin
   console → Modules → New module**, short name `wiki`, display name `Wiki`,
   address `https://wiki.<your-domain>`, and tick **Create a database for
   it**. Den shows the connection URL once:

    ```text
    postgres://wiki:3f9c…e1@postgres.conservices-data.svc.cluster.local:5432/wiki?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt
    ```

    Copy it straight into your secret manager (next step). The
    `sslmode=verify-full` part makes Wiki connect with TLS and check the
    database's certificate against the platform's internal CA; the
    platform's PostgreSQL refuses connections without TLS.

2. **Create the bucket and add it to backups.** Create a bucket (for
   example `wiki-data`) and keys that can only reach it. Wiki also creates
   the bucket on start if the keys allow it. Add the bucket to the Den
   operator's `FILES_S3_BUCKETS`; page bodies exist **only** in the bucket.

3. **Create the namespace** with the labels the platform's network
   policies, trust-manager ([Internal TLS](#internal-tls)) and Pod Security
   expect:

    ```sh
    kubectl create namespace conservices-wiki
    kubectl label namespace conservices-wiki \
      conservices.io/tier=module conservices.io/module=wiki \
      app.kubernetes.io/part-of=conservices \
      pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/warn=restricted
    ```

4. **Store the secrets in your secret manager** and let the External
   Secrets Operator create the Secret `wiki-secrets` (how this works:
   [Secrets](../../operations/secrets.md)). With Vault or OpenBao:

    ```sh
    vault kv put secret/conservices/wiki/backend \
      DATABASE_URL='postgres://wiki:change-me@postgres.conservices-data.svc.cluster.local:5432/wiki?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt' \
      S3_ACCESS_KEY_ID=change-me S3_SECRET_ACCESS_KEY=change-me \
      WIKI_SERVICE_TOKEN="$(openssl rand -hex 32)" \
      DEN_LINK_ENCRYPTION_KEY="$(openssl rand -base64 32)" \
      HR_SERVICE_TOKEN=change-me-same-as-hr
    ```

    `DEN_LINK_ENCRYPTION_KEY` is required: it encrypts the Den credential
    Wiki stores, and the backend refuses to start without it (see
    [Secrets](../../operations/secrets.md#den-link-encryption-key) for
    rotation). `HR_SERVICE_TOKEN` is the token HR sends to read Wiki's role
    catalog; use HR's value, or leave it out when you do not run HR.

    ```yaml
    apiVersion: external-secrets.io/v1
    kind: ExternalSecret
    metadata:
      name: wiki-secrets
      namespace: conservices-wiki
    spec:
      refreshInterval: 1h
      secretStoreRef: { name: vault, kind: SecretStore }
      target: { name: wiki-secrets }
      dataFrom:
        - extract: { key: conservices/wiki/backend }
    ```

    `WIKI_SERVICE_TOKEN` must be the same token HR uses in
    `OFFBOARD_HOOKS` (step 8). Optional, for the share dialog's group
    picker: add `HR_DIRECTORY_TOKEN` (once HR serves the directory, step 8)
    or `IDP_DIRECTORY_CLIENT_SECRET` (Keycloak, see
    [Group picker](configuration.md#group-picker)) to the same entry.

5. **Create the access config.** It maps Keycloak groups to Wiki roles.
   Start from `infra/access-config.toml` in the Wiki repository:

    ```sh
    kubectl create configmap wiki-access-config -n conservices-wiki \
      --from-file=access-config.toml=access-config.toml
    ```

    In Keycloak, `wiki-spa` also needs the **audience mapper** that puts
    `wiki-api` into its access tokens; see
    [Keycloak audience for Wiki's API](#keycloak-audience-for-wikis-api).
    The suite's realm file already has it.

6. **Write your values and install the chart** (`deploy/charts/wiki` in the
   `con-services` repository):

    ```yaml
    # my-wiki.yaml
    image:
      backend:  { tag: "1.0.0-1" }
      frontend: { tag: "1.0.0-1" }
      migrate:  { tag: "1.0.0-1" }
    config:
      APP_BASE_URL: https://wiki.example.org
      OIDC_ISSUER_URL: https://auth.example.org/realms/conservices
      CORS_ALLOWED_ORIGINS: https://wiki.example.org
      S3_BUCKET: wiki-data
    route:
      host: wiki.example.org
    ```

    ```sh
    helm install wiki deploy/charts/wiki -n conservices-wiki -f my-wiki.yaml
    kubectl get pods -n conservices-wiki -w
    ```

    ```text
    NAME                             READY   STATUS     RESTARTS   AGE
    wiki-backend-7d9c6b8f5-x2kqd     0/1     Init:0/1   0          5s
    wiki-backend-7d9c6b8f5-x2kqd     1/1     Running    0          20s
    wiki-frontend-6c8b5d9f7-7wqzm    1/1     Running    0          20s
    wiki-frontend-6c8b5d9f7-p4ncs    1/1     Running    0          20s
    ```

    The chart creates a 1 GiB volume for the edit buffer and refuses any
    `backend.replicas` other than 1.

    Internal TLS is on by default (`internalTLS.enabled: true`), and the
    chart's defaults reach the platform services over HTTPS
    (`S3_ENDPOINT: https://s3.conservices-data.svc.cluster.local:9000`,
    `DEN_INTERNAL_URL: https://den-backend.conservices-den.svc.cluster.local:8080`).
    The cluster needs cert-manager, trust-manager and the platform's
    internal CA; see [Internal TLS](#internal-tls).

    The web app's security headers allow the sign-in server from
    `config.OIDC_ISSUER_URL`; set `frontend.securityHeaders.keycloakOrigin`
    only when the browser reaches Keycloak on another address, and
    `frontend.securityHeaders.denOrigin` to Den's public address if you want
    it in the policy ([Web app security headers](configuration.md#web-app-security-headers)).

7. **Pair Wiki with Den.** In Den: **Admin console → Modules → Pair** on the
   Wiki row; copy the URL (valid 15 minutes, single use). In Wiki, signed in
   as a `wiki-admin`: **Settings → Den connection**, paste it and confirm.
   Wiki shows Den's brand within a minute.

8. **Connect HR** (only if you run HR). HR reads Wiki's role catalog (so
   the Wiki roles appear in HR's access picker) and calls Wiki when an
   account is deleted. HR's chart already allows that call
   (`networkPolicy.moduleEgressNamespaces` includes `conservices-wiki`).
   Point HR at Wiki's catalog and upgrade HR:

    ```yaml
    # my-hr.yaml (HR chart deploy/charts/hr)
    config:
      ROLE_CATALOG_SOURCES: >-
        stash=https://stash-backend.conservices-stash.svc.cluster.local:8080/api/role-catalog,wiki=https://wiki-backend.conservices-wiki.svc.cluster.local:8080/api/role-catalog
    ```

    Setting `ROLE_CATALOG_SOURCES` replaces the whole list, so name every
    module whose roles should appear in HR.

    And in HR's secret (`hr-secrets`), the hook with Wiki's service token:

    ```text
    OFFBOARD_HOOKS=https://wiki-backend.conservices-wiki.svc.cluster.local:8080/api/internal/offboarded|<WIKI_SERVICE_TOKEN>
    ```

    ```sh
    helm upgrade hr deploy/charts/hr -n conservices-hr -f my-hr.yaml
    ```

    The Wiki chart already admits HR's backend
    (`networkPolicy.allowFromNamespaces` lists `conservices-hr`). Check it:
    in HR, **Access** for any person now lists the Wiki roles.
    See [Network policies](../../operations/network-policies.md#calls-between-modules).

    **Group picker from HR.** HR serves
    `GET /api/internal/directory/groups` when `HR_DIRECTORY_TOKEN` is set
    (contract on [Group picker](configuration.md#group-picker)). HR's chart
    already admits Wiki (`networkPolicy.allowFromNamespaces` includes
    `conservices-wiki`). Put the same token in `wiki-secrets`, then open
    Wiki's egress to HR's backend in `conservices-hr` on port 8080:

    ```yaml
    # my-wiki.yaml
    config:
      HR_DIRECTORY_URL: https://hr-backend.conservices-hr.svc.cluster.local:8080
    networkPolicy:
      hr: { enabled: true }
    ```

9. **Verify.**

    ```sh
    kubectl get certificate -n conservices-wiki
    kubectl exec -n conservices-wiki deploy/wiki-frontend -- curl -s --cacert /etc/conservices-internal-ca/ca.crt https://wiki-backend:8080/api/health
    ```

    ```text
    NAME                READY   SECRET              AGE
    wiki-backend-tls    True    wiki-backend-tls    40s
    wiki-frontend-tls   True    wiki-frontend-tls   40s
    ```

    ```json
    {"status":"ok","database":"ok","version":"1.0.0-1","uptime_sec":42}
    ```

    The backend answers over HTTPS. `--cacert` makes `curl` check its

    certificate against the internal CA mounted in the web app pod; nginx

    does the same check on every `/api/` request.

    Then open `https://wiki.<your-domain>`, create a page, and open it in a
    second browser: typing in one shows up in the other within a second.

## Keycloak audience for Wiki's API

The web app sends Keycloak **access tokens** to Wiki's API, and the backend
accepts only tokens whose audience contains `wiki-api` (`OIDC_AUDIENCE`;
the [token contract](../../concepts/authentication.md#tokens-the-10-contract)).
Keycloak adds that audience with a mapper on the `wiki-spa` client. The
suite's realm file (`infra/keycloak/realm-conservices.json`) and
`infra/keycloak/apply-mvp.sh` already create it; for another realm:

1. Keycloak admin console → realm `conservices` → **Clients → wiki-spa →
   Client scopes → wiki-spa-dedicated → Add mapper → By configuration →
   Audience**.
2. Name `wiki-api audience`, **Included Custom Audience** `wiki-api`,
   **Add to access token** on, **Add to ID token** off. Save.
3. Check a token (development realm, password grant):

    ```sh
    curl -s https://auth.example.org/realms/conservices/protocol/openid-connect/token \
      -d grant_type=password -d client_id=wiki-spa -d username=alice -d password=change-me \
      | jq -r .access_token | cut -d. -f2 | base64 -d 2>/dev/null | jq .aud
    ```

    ```json
    ["wiki-api", "account"]
    ```

The group mapper must put the groups into the **access token** as well
("Add to access token" on), because Wiki reads groups from the token it
receives (`OIDC_GROUPS_CLAIM`, default `groups`).

## Option 2: Standalone on Kubernetes

Only Wiki, without Den. Follow
[Run one module on Kubernetes](../../getting-started/standalone-kubernetes.md)
with these Wiki-specific values:

- Create the database and login yourself (Den is not there to do it), and
  a bucket with keys for it.
- Secret `wiki-secrets` with `DATABASE_URL`, `S3_ACCESS_KEY_ID`,
  `S3_SECRET_ACCESS_KEY`; `WIKI_SERVICE_TOKEN` can stay empty (no HR).
- Values for your own services:

    ```yaml
    den: { mode: standalone }   # no Den: do not wait for pairing
    config:
      APP_BASE_URL: https://wiki.example.org
      OIDC_ISSUER_URL: https://login.example.org/realms/conservices
      CORS_ALLOWED_ORIGINS: https://wiki.example.org
      S3_ENDPOINT: https://fsn1.your-objectstorage.com
      S3_BUCKET: example-wiki
      S3_REGION: fsn1
      DEN_INTERNAL_URL: ""            # no Den
      PUBLIC_LINKS_ENABLED: "false"   # standalone switch for share links
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

- The backend still runs **one replica** with a buffer volume.
- Optional: let the share dialog suggest your Keycloak groups. Create the
  read-only client as in [Group picker](configuration.md#group-picker), add
  `IDP_DIRECTORY_CLIENT_SECRET` to `wiki-secrets`, and set
  `config.IDP_DIRECTORY_URL`, `config.IDP_DIRECTORY_CLIENT_ID` and an egress
  rule to Keycloak (`networkPolicy.keycloakAdmin.enabled: true` in-cluster,
  or an `extraEgress` rule for an external Keycloak).
- Internal TLS stays on by default and needs cert-manager, trust-manager
  and an issuer in your cluster. Without them, turn it off or bring your
  own certificates ([Without cert-manager](#without-cert-manager)). For a
  managed database, end `DATABASE_URL` in
  `?sslmode=verify-full&sslrootcert=<path to the provider's CA>` and mount
  that CA file with `backend.extraVolumes` and `backend.extraVolumeMounts`.
- **Back up the database and the bucket yourself**; nothing else does.

You can add Den later and pair Wiki then; nothing has to be reinstalled.

## Internal TLS

On Kubernetes, Wiki encrypts the traffic **inside** the cluster as well,
not only between browsers and the Gateway. It is on by default
in the Helm chart. The shared how-to, including the platform setup and
certificate rotation, is [Internal TLS](../../operations/internal-tls.md).

What happens:

- **cert-manager** (a Kubernetes add-on that issues and renews
  certificates) issues `wiki-backend-tls` and `wiki-frontend-tls` from the
  ClusterIssuer `conservices-internal-ca`. They last 90 days and are
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
- The **web app**'s nginx serves HTTPS on port 8080, forwards `/api/` and
  the live-editing websocket to the backend over HTTPS and checks the
  backend's certificate. It reloads every six hours to pick up a renewed
  certificate. Its Service listens on port 443 (port name `https`).
- **The gateway** talks HTTPS to the web app and checks its certificate (a `BackendTLSPolicy`; with the legacy Ingress, the ingress controller does it).

Check it:

```sh
kubectl get certificate -n conservices-wiki
kubectl get configmap conservices-internal-ca -n conservices-wiki
kubectl logs -n conservices-wiki deploy/wiki-backend | grep "tls enabled"
```

Both certificates should be `READY True`, the ConfigMap should exist, and
the backend's `tls enabled` log line carries the certificate's expiry date
in `not_after`.

### Chart values

| Value | Default | What it does |
| --- | --- | --- |
| `internalTLS.enabled` | `true` | Turns internal TLS on or off for the backend, the web app and the Ingress. |
| `internalTLS.createCertificates` | `true` | `true`: the chart asks cert-manager for the two certificates. `false`: you create the Secrets `wiki-backend-tls` and `wiki-frontend-tls` yourself (keys `tls.crt`, `tls.key`, `ca.crt`). |
| `internalTLS.issuerRef` | ClusterIssuer `conservices-internal-ca` | The cert-manager issuer that signs them. |
| `internalTLS.duration` | `2160h` (90 days) | Certificate lifetime. |
| `internalTLS.renewBefore` | `720h` (30 days) | How long before expiry cert-manager renews. |
| `internalTLS.caConfigMap` | `conservices-internal-ca` | ConfigMap (key `ca.crt`) with the CA the pods trust. |
| `internalTLS.ingressNginxAnnotations` | `false` | Legacy, only with `ingress.enabled: true`: adds the ingress-nginx annotations for HTTPS to the web app (`backend-protocol: HTTPS`, `proxy-ssl-verify`). The Gateway API route uses a `BackendTLSPolicy` instead. ingress-nginx is no longer maintained; do not use it. |
| `route.enabled`, `route.host`, `route.parentRefs`, `route.timeout` | `true`, `wiki.conservices.test`, Gateway `public` in `conservices-gateway` (listener `https`), `60s` | Exposes the web app through the Gateway API: an `HTTPRoute` and, with internal TLS, a `BackendTLSPolicy` that makes the gateway check `wiki-frontend`'s certificate. See [Exposing the web app](../../operations/helm.md#exposing-the-web-app-gateway-api). |
| `frontend.config` | `{}` | The web app's `/config.json` (sign-in address, client id; see [Web app settings](configuration.md#web-app-settings-configjson)), written to the ConfigMap `<release>-frontend-config`. Keys left out come from `config.AUTH_MODE`, `config.OIDC_ISSUER_URL` and `config.OIDC_CLIENT_ID` (else `wiki-spa`). |
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
kubectl create secret generic wiki-backend-tls -n conservices-wiki \
  --from-file=tls.crt=backend.crt --from-file=tls.key=backend.key --from-file=ca.crt=ca.crt
kubectl create secret generic wiki-frontend-tls -n conservices-wiki \
  --from-file=tls.crt=frontend.crt --from-file=tls.key=frontend.key --from-file=ca.crt=ca.crt
kubectl create configmap my-internal-ca -n conservices-wiki --from-file=ca.crt=ca.crt
```

```yaml
internalTLS:
  createCertificates: false
  caConfigMap: my-internal-ca
```

The backend certificate must be valid for `wiki-backend` and
`wiki-backend.conservices-wiki.svc.cluster.local`, the web app's for
`wiki-frontend.conservices-wiki.svc.cluster.local`. Replace them before
they expire; the backend picks up new files within a minute, nginx within
six hours.

## Option 3: Production on Docker

One server, Docker Compose, published images. Read
[Full stack on Docker (production)](../../operations/docker-production.md)
first: it sets up the networks, the proxy and the root-only env files. Then
add Wiki next to Den:

```yaml
# in compose.production.yml (services:)
  wiki-migrate:
    image: ghcr.io/aglelectronics/wiki-migrate:1.0.0-1
    <<: *hardening
    restart: "no"
    networks: [internal, egress]
    env_file: /etc/conservices/wiki-backend.env
    environment:
      APP_ENV: production

  wiki-backend:
    image: ghcr.io/aglelectronics/wiki-backend:1.0.0-1
    <<: *hardening
    depends_on:
      wiki-migrate: { condition: service_completed_successfully }
    stop_grace_period: 45s            # ships buffered edits on shutdown
    networks: [internal, egress]
    # DATABASE_URL, S3_*, WIKI_SERVICE_TOKEN, DEN_LINK_ENCRYPTION_KEY, HR_SERVICE_TOKEN
    env_file: /etc/conservices/wiki-backend.env
    environment:
      APP_ENV: production
      APP_BASE_URL: https://wiki.con.example.org
      HTTP_ADDR: ":8080"
      AUTH_MODE: oidc
      OIDC_ISSUER_URL: https://auth.con.example.org/realms/conservices
      OIDC_CLIENT_ID: wiki-spa
      OIDC_AUDIENCE: wiki-api
      ACCESS_CONFIG_PATH: /etc/wiki/access-config.toml
      CORS_ALLOWED_ORIGINS: https://wiki.con.example.org
      S3_ENDPOINT: https://fsn1.your-objectstorage.com
      S3_BUCKET: example-wiki
      S3_REGION: fsn1
      WIKI_BUFFER_DIR: /var/lib/wiki/buffer
      DEN_INTERNAL_URL: http://den-backend:8080
    volumes:
      - ./wiki/access-config.toml:/etc/wiki/access-config.toml:ro
      - wiki-buffer:/var/lib/wiki/buffer

  wiki-frontend:
    image: ghcr.io/aglelectronics/wiki-frontend:1.0.0-1
    restart: unless-stopped
    networks: [internal]
    volumes:
      # Forwards /api/ (and the live websocket) to wiki-backend:8080.
      - ./wiki/nginx.stack.conf:/etc/nginx/conf.d/default.conf:ro
      # The web app's sign-in settings, served as /config.json.
      - ./wiki/config.json:/etc/conservices/config.json:ro
      # Security headers with your Keycloak (and Den) origins.
      - ./wiki/security-headers.conf:/etc/nginx/snippets/security-headers.conf:ro

# volumes:
  wiki-buffer: {}
```

`./wiki/config.json` holds the web app's sign-in settings; the published
image names no domain. Keys: [Web app settings](configuration.md#web-app-settings-configjson).

```json
{
  "authMode": "oidc",
  "oidcAuthority": "https://auth.con.example.org/realms/conservices",
  "oidcClientId": "wiki-spa"
}
```

- Never scale `wiki-backend`: one container only.
- `nginx.stack.conf` is `infra/nginx.stack.conf` from the Wiki repository.
- `security-headers.conf` is `shared/nginx/security-headers.conf` from
  `con-services` with `KEYCLOAK_ORIGIN` replaced by
  `https://auth.con.example.org` and `DEN_ORIGIN` by
  `https://den.con.example.org` (or removed). The image's own copy only
  knows the development addresses, so without your copy sign-in after a
  reload fails with a CSP error. See
  [Web app security headers](configuration.md#web-app-security-headers).
- The Keycloak client needs the `wiki-api`
  [audience mapper](#keycloak-audience-for-wikis-api).
- Proxy block: `wiki.con.example.org { reverse_proxy wiki-frontend:8080 }`.
  Caddy passes websockets through without extra settings.
- Add `example-wiki` to the operator's `FILES_S3_BUCKETS`.
- Pin exact tags, use no default passwords, and keep secrets only in the
  root-only env file, as the guide describes.

## Option 4: Development on Docker

Quick and easy, **never for real data**: passwords are public and in the
compose files.

In the whole suite (from the root of the `con-services` repository):

```powershell
docker compose --profile wiki up --build -d
```

Open <https://wiki.conservices.test> (or <http://localhost:3007>) and sign
in through the development Keycloak. Pair it under **Settings → Den
connection** if Den runs too (`--profile den`).

On its own, with development sign-in (pick any name, no password):

```powershell
cd wiki
docker compose -f infra/docker-compose.yml up --build
```

| Service | Host port |
| --- | --- |
| backend | 8140 |
| frontend | 3007 |
| PostgreSQL (standalone stack only) | 5439 |
| S3 server, SeaweedFS (standalone stack only) | 9040 |

## Why the backend must stay at one replica

Live editing works like this (details in
[ADR 0001](https://github.com/AGlElectronics/wiki/blob/main/docs/adr/0001-yjs-relay-in-go.md)):
the backend relays every change between the browsers that have a page open,
appends it to a file in `WIKI_BUFFER_DIR`, and ships those files to S3
every 5 seconds. The list of open pages, the people on them and the
one-time tickets that open the websocket all live **in the backend's
memory**.

With two replicas, two people on the same page could land on different
backends. Each backend would relay changes only to its own browsers, so
they would stop seeing each other's edits, and each would number the page's
changes on its own. That is why:

- the backend runs **exactly one replica**, and the Helm chart refuses
  another value;
- deployments use the `Recreate` strategy, so old and new pods never run
  side by side;
- the pod gets **at least 30 seconds** to stop (the chart uses 45): on
  shutdown it closes the live connections and ships the buffer to S3;
- the buffer sits on a volume. If a pod dies without a clean shutdown,
  buffer files left behind are shipped on the next start; with an
  `emptyDir` instead of a volume, at most the last ~5 seconds of edits can
  be lost, and browsers still on the page resend them when they reconnect.

The frontend has no state and can run several replicas.

## Troubleshooting

**Editing or uploads fail with `503` "live editing needs object storage
(S3_ENDPOINT)".** `S3_ENDPOINT` is empty, so storage is off. If it is set
and the backend instead restarts at start-up, it cannot reach the bucket
(it refuses to start then): check the backend log, the S3 keys and the
network policy egress to S3.

**The editor keeps reconnecting.** A proxy in front drops the websocket at
`/api/v1/pages/<id>/live`. Every proxy on the way must pass `Upgrade`
headers and allow a long read timeout (the chart sets 1 hour on nginx, and
the HTTPRoute's websocket rule has no request timeout). Check with your browser's developer tools: the request should
answer `101 Switching Protocols`.

**`helm install` fails with "backend.replicas must be 1".** Intended; see
[above](#why-the-backend-must-stay-at-one-replica).

**The backend pod stays in `Init:0/1` or `Init:CrashLoopBackOff`.** The
migrate step cannot reach the database. Check `DATABASE_URL` in
`wiki-secrets` and `kubectl logs -n conservices-wiki deploy/wiki-backend -c migrate`.
For `no encryption`, see below.

**The backend exits with `tls: TLS_CERT_FILE and TLS_KEY_FILE must be set
together`.** Only one of the two is set, usually because one was added by
hand to `config:` or `backend.extraEnv`. Remove it: the chart sets both
while internal TLS is on, and neither while it is off.

**A pod stays `ContainerCreating`.** It waits for a volume that does not
exist yet: the Secret `wiki-backend-tls` or `wiki-frontend-tls` (made by
cert-manager) or the ConfigMap `conservices-internal-ca` (made by
trust-manager). `kubectl describe pod` shows `MountVolume.SetUp failed …
not found` under Events. Check:

```sh
kubectl get certificate -n conservices-wiki
kubectl describe certificate wiki-backend-tls -n conservices-wiki
kubectl get configmap conservices-internal-ca -n conservices-wiki
```

A certificate that is not `READY True` means cert-manager or the
ClusterIssuer `conservices-internal-ca` is missing; the events of
`kubectl describe certificate` say which. A missing ConfigMap means
trust-manager is not installed, or the namespace lacks the label:
`kubectl label namespace conservices-wiki app.kubernetes.io/part-of=conservices`.
Without cert-manager, see [Without cert-manager](#without-cert-manager).

**The web app answers `502 Bad Gateway` and its log shows `upstream SSL
certificate verify error`.** nginx could not check the backend's
certificate. Either the backend serves plain HTTP (its log has no
`tls enabled` line), or its certificate was signed by a CA other than the
one in `conservices-internal-ca` (with your own certificates: put the right
CA in the ConfigMap named by `internalTLS.caConfigMap`). See the error with
`kubectl logs -n conservices-wiki deploy/wiki-frontend`.

**The backend refuses to start or pairing fails with `x509: certificate
signed by unknown authority`.** The backend does not trust the internal
CA when it calls the S3 server, Den or the database: `SSL_CERT_DIR` is missing, or
a value in `config:` replaced it with another folder. It must include
`/etc/conservices-internal-ca`; separate several folders with `:`. Check
with `kubectl get configmap wiki-config -n conservices-wiki -o yaml`.

**The migrate log shows `no pg_hba.conf entry for host "…", user "wiki",
database "wiki", no encryption`.** `DATABASE_URL` still ends in
`sslmode=disable`, and the platform's PostgreSQL accepts only TLS. Change
the end to
`?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt` in
your secret manager, then
`kubectl rollout restart -n conservices-wiki deploy/wiki-backend`. For a
managed database use `sslmode=verify-full&sslrootcert=<path to the provider's CA>`.

**The backend restarts with `den link: DEN_LINK_ENCRYPTION_KEY is required
unless APP_ENV=development`.** Add the key to `wiki-secrets` (step 4) and
restart the backend.

**Every request answers `401 invalid token` after the upgrade.** The access
tokens lack the `wiki-api` audience: add the
[audience mapper](#keycloak-audience-for-wikis-api) to `wiki-spa`.

**Signed in, but a reload goes back to the sign-in page.** Tokens live only
in memory; after a reload the web app signs in again silently through a
hidden frame. That fails when the security headers do not allow the
sign-in server (`frontend.securityHeaders.keycloakOrigin`) or when the
browser blocks Keycloak's cookies in frames (the sign-in server must share
the site with Wiki, for example `auth.example.org` and `wiki.example.org`).

**HR's access picker lists no Wiki roles.** Wiki's role catalog needs HR's
`HR_SERVICE_TOKEN`: set the same value on Wiki (`wiki-secrets`) and HR.
HR's log shows `401` for Wiki otherwise.

**The Den connection says "Den rejected this module's credential".** Den
revoked the credential or Wiki was removed in Den. Pair again (step 7);
Wiki keeps Den's last brand and settings until then.

**HR's offboarding fails with a timeout.** HR's namespace has no egress rule
to `conservices-wiki` (add it to HR's `networkPolicy.moduleEgressNamespaces`,
step 8). With `401`, `WIKI_SERVICE_TOKEN` and the token in
`OFFBOARD_HOOKS` differ. With `404`, `WIKI_SERVICE_TOKEN` is empty on Wiki.

**The Wiki roles are missing from HR's access picker.** HR's
`ROLE_CATALOG_SOURCES` does not list `wiki=…/api/role-catalog`, or HR cannot
reach Wiki (the same egress rule as above). See step 8.

**The group picker only shows your own groups.** See
[Configuration → Troubleshooting](configuration.md#troubleshooting).

**Public share links answer `404`.** They are off until Den's organisation
setting `wiki_public_links` (or `PUBLIC_LINKS_ENABLED` standalone) is on.

**Signed in, but "no access" to team spaces.** Reading is not a role: a
space must be shared with you, a group you are in, or everyone signed in.
See the [Admin guide](admin-guide.md#sharing).
