# Set up Wiki

This page installs Wiki. Pick one of four ways:

| Option | When | Data safe? |
| --- | --- | --- |
| [1. Kubernetes platform](#option-1-kubernetes-platform-recommended) (recommended) | Production, with Den already running | Yes, backed up by Den's operator |
| [2. Standalone on Kubernetes](#option-2-standalone-on-kubernetes) | Only Wiki, your own PostgreSQL, S3 and sign-in | Yes, if **you** back it up |
| [3. Production on Docker](#option-3-production-on-docker) | One server without Kubernetes | Yes, with care |
| [4. Development on Docker](#option-4-development-on-docker) | Trying it out, development | **No**: public passwords |

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
    postgres://wiki:3f9c…e1@postgres.conservices-data.svc.cluster.local:5432/wiki?sslmode=disable
    ```

    Copy it straight into your secret manager (next step).

2. **Create the bucket and add it to backups.** Create a bucket (for
   example `wiki-data`) and keys that can only reach it. Wiki also creates
   the bucket on start if the keys allow it. Add the bucket to the Den
   operator's `FILES_S3_BUCKETS`; page bodies exist **only** in the bucket.

3. **Create the namespace** with the labels the platform's network
   policies and Pod Security expect:

    ```sh
    kubectl create namespace conservices-wiki
    kubectl label namespace conservices-wiki \
      conservices.io/tier=module conservices.io/module=wiki \
      pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/warn=restricted
    ```

4. **Store the secrets in your secret manager** and let the External
   Secrets Operator create the Secret `wiki-secrets` (how this works:
   [Secrets](../../operations/secrets.md)). With Vault or OpenBao:

    ```sh
    vault kv put secret/conservices/wiki/backend \
      DATABASE_URL='postgres://wiki:change-me@postgres.conservices-data.svc.cluster.local:5432/wiki?sslmode=disable' \
      S3_ACCESS_KEY_ID=change-me S3_SECRET_ACCESS_KEY=change-me \
      WIKI_SERVICE_TOKEN="$(openssl rand -hex 32)"
    ```

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
    `OFFBOARD_HOOKS` (step 8).

5. **Create the access config.** It maps Keycloak groups to Wiki roles.
   Start from `infra/access-config.toml` in the Wiki repository:

    ```sh
    kubectl create configmap wiki-access-config -n conservices-wiki \
      --from-file=access-config.toml=access-config.toml
    ```

6. **Write your values and install the chart** (`deploy/charts/wiki` in the
   `con-services` repository):

    ```yaml
    # my-wiki.yaml
    image:
      backend:  { tag: "1.0.0-1" }
      frontend: { tag: "1.0.0-1" }   # or your own build, see Configuration
      migrate:  { tag: "1.0.0-1" }
    config:
      APP_BASE_URL: https://wiki.example.org
      OIDC_ISSUER_URL: https://auth.example.org/realms/conservices
      CORS_ALLOWED_ORIGINS: https://wiki.example.org
      S3_BUCKET: wiki-data
    ingress:
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

7. **Pair Wiki with Den.** In Den: **Admin console → Modules → Pair** on the
   Wiki row; copy the URL (valid 15 minutes, single use). In Wiki, signed in
   as a `wiki-admin`: **Settings → Den connection**, paste it and confirm.
   Wiki shows Den's brand within a minute.

8. **Connect HR** (only if you run HR). HR calls Wiki when an account is
   deleted. In HR's settings:

    ```text
    OFFBOARD_HOOKS=http://wiki-backend.conservices-wiki.svc.cluster.local:8080/api/internal/offboarded|<WIKI_SERVICE_TOKEN>
    ```

    The Wiki chart already admits HR's backend (`networkPolicy.allowFromNamespaces`).
    HR's namespace needs the matching **egress** rule to
    `conservices-wiki` port 8080; see
    [Network policies](../../operations/network-policies.md#calls-between-modules).

9. **Verify.**

    ```sh
    kubectl exec -n conservices-wiki deploy/wiki-frontend -- wget -qO- http://wiki-backend:8080/api/health
    ```

    ```json
    {"status":"ok","database":"ok","version":"1.0.0-1","uptime_sec":42}
    ```

    Then open `https://wiki.<your-domain>`, create a page, and open it in a
    second browser: typing in one shows up in the other within a second.

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
- **Back up the database and the bucket yourself**; nothing else does.

You can add Den later and pair Wiki then; nothing has to be reinstalled.

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
    env_file: /etc/conservices/wiki-backend.env   # DATABASE_URL, S3_*, WIKI_SERVICE_TOKEN
    environment:
      APP_ENV: production
      APP_BASE_URL: https://wiki.con.example.org
      HTTP_ADDR: ":8080"
      AUTH_MODE: oidc
      OIDC_ISSUER_URL: https://auth.con.example.org/realms/conservices
      OIDC_CLIENT_ID: wiki-spa
      OIDC_AUDIENCE: wiki-spa
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
    image: registry.example.org/conservices/wiki-frontend:1.0.0-1   # your own build
    restart: unless-stopped
    networks: [internal]
    volumes:
      # Forwards /api/ (and the live websocket) to wiki-backend:8080.
      - ./wiki/nginx.stack.conf:/etc/nginx/conf.d/default.conf:ro

# volumes:
  wiki-buffer: {}
```

- Never scale `wiki-backend`: one container only.
- `nginx.stack.conf` is `infra/nginx.stack.conf` from the Wiki repository.
- Proxy block: `wiki.con.example.org { reverse_proxy wiki-frontend:80 }`.
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
| MinIO (standalone stack only) | 9040, console 9041 |

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
headers and allow a long read timeout (the chart sets 1 hour on nginx and
the ingress). Check with your browser's developer tools: the request should
answer `101 Switching Protocols`.

**`helm install` fails with "backend.replicas must be 1".** Intended; see
[above](#why-the-backend-must-stay-at-one-replica).

**The backend pod stays in `Init:0/1` or `Init:CrashLoopBackOff`.** The
migrate step cannot reach the database. Check `DATABASE_URL` in
`wiki-secrets` and `kubectl logs -n conservices-wiki deploy/wiki-backend -c migrate`.

**HR's offboarding fails with a timeout.** HR's namespace has no egress rule
to `conservices-wiki`. With `401`, `WIKI_SERVICE_TOKEN` and the token in
`OFFBOARD_HOOKS` differ. With `404`, `WIKI_SERVICE_TOKEN` is empty on Wiki.

**Public share links answer `404`.** They are off until Den's organisation
setting `wiki_public_links` (or `PUBLIC_LINKS_ENABLED` standalone) is on.

**Signed in, but "no access" to team spaces.** Reading is not a role: a
space must be shared with you, a group you are in, or everyone signed in.
See the [Admin guide](admin-guide.md#sharing).
