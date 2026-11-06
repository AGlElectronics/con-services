# Set up Learn

This page installs Learn. Pick one of four ways:

| Option | When | Data safe? |
| --- | --- | --- |
| [1. Kubernetes platform](#option-1-kubernetes-platform-recommended) (recommended) | Production, with Den running | Yes, backed up by Den's operator |
| [2. Standalone on Kubernetes](#option-2-standalone-on-kubernetes) | Only Learn | Yes, if **you** back it up |
| [3. Production on Docker](#option-3-production-on-docker) | One server, no Kubernetes | Yes, with care |
| [4. Development on Docker](#option-4-development-on-docker) | Trying it out | **No**: public passwords |

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
   into your secret manager.

2. **Create the bucket** (for example `learn-data`) with keys limited to it,
   allow browser access from your Learn address (CORS on the bucket), and add
   it to the Den operator's `FILES_S3_BUCKETS`.

3. **Create the namespace:**

    ```sh
    kubectl create namespace conservices-learn
    kubectl label namespace conservices-learn \
      conservices.io/tier=module conservices.io/module=learn \
      pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/warn=restricted
    ```

4. **Store the secrets** and let an `ExternalSecret` create `learn-secrets`
   (see [Secrets](../../operations/secrets.md)). Regenerate the
   `learn-provisioner` client secret in Keycloak first (**Clients →
   learn-provisioner → Credentials → Regenerate**); the realm file ships a
   public development value.

    ```sh
    vault kv put secret/conservices/learn/backend \
      DATABASE_URL='postgres://learn:change-me@postgres.conservices-data.svc.cluster.local:5432/learn?sslmode=disable' \
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
    ingress:
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

7. **Let Learn reach Keycloak's admin API.** The chart adds the egress rule
   from Learn to `keycloak` in `conservices-identity` on port 8080.
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
    QUALIFICATION_CATALOG_SOURCES=learn=http://learn-backend.conservices-learn.svc.cluster.local:8080/api/qualification-catalog
    LEARN_HOLDINGS_URL=http://learn-backend.conservices-learn.svc.cluster.local:8080/api/internal/holdings
    LEARN_SERVICE_TOKEN=<the same token as Learn's>
    ```

    The Learn chart already admits HR's backend. HR's namespace needs the
    matching egress rule to `conservices-learn` port 8080.

10. **Verify:**

    ```sh
    kubectl exec -n conservices-learn deploy/learn-frontend -- wget -qO- http://learn-backend:8080/api/health
    ```

    ```json
    {"status":"ok","database":"ok","version":"1.0.0-1","uptime_sec":40}
    ```

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
    image: registry.example.org/conservices/learn-frontend:1.0.0-1   # your own build
    restart: unless-stopped
    networks: [internal]
    volumes:
      # infra/nginx.stack.conf from the Learn repository: forwards /api/ to learn-backend:8080.
      - ./learn/nginx.stack.conf:/etc/nginx/conf.d/default.conf:ro
```

Proxy block: `learn.con.example.org { reverse_proxy learn-frontend:80 }`.
Keep one `learn-backend` container (it migrates through `learn-migrate`
anyway).

## Option 4: Development on Docker

Never for real data. From the root of the `con-services` repository:

```powershell
docker compose --profile den --profile learn up --build -d
```

Learn runs at <https://learn.conservices.test> (or <http://localhost:3005>)
with the development Keycloak, MinIO and Mailpit. On its own, with
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
| MinIO (standalone stack only) | 9030 |
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
