# Set up Tasks

This page installs Tasks. Pick one of four ways:

| Option | When | Data safe? |
| --- | --- | --- |
| [1. Kubernetes platform](#option-1-kubernetes-platform-recommended) (recommended) | Production, with Den already running | Yes, backed up by Den's operator |
| [2. Standalone on Kubernetes](#option-2-standalone-on-kubernetes) | Only Tasks, your own PostgreSQL, S3 and sign-in | Yes, if **you** back it up |
| [3. Production on Docker](#option-3-production-on-docker) | One server without Kubernetes | Yes, with care |
| [4. Development on Docker](#option-4-development-on-docker) | Trying it out, development | **No**: public passwords |

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
   connection URL Den shows once straight into your secret manager.

2. **Create the bucket** (for example `tasks-data`) with keys limited to it,
   and add it to the Den operator's `FILES_S3_BUCKETS` so attachments are
   backed up.

3. **Create the namespace:**

    ```sh
    kubectl create namespace conservices-tasks
    kubectl label namespace conservices-tasks \
      conservices.io/tier=module conservices.io/module=tasks \
      pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/warn=restricted
    ```

4. **Store the secrets in your secret manager** and let an `ExternalSecret`
   create `tasks-secrets` (see [Secrets](../../operations/secrets.md)):

    ```sh
    vault kv put secret/conservices/tasks/backend \
      DATABASE_URL='postgres://tasks:change-me@postgres.conservices-data.svc.cluster.local:5432/tasks?sslmode=disable' \
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
    ingress:
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

7. **Pair with Den.** Den: **Admin console → Modules → Pair** on the Tasks
   row. Tasks (as `tasks-admin`): **Settings → Den connection**, paste the
   URL, **Connect**.

8. **Connect HR** (only if you run HR). HR tells Tasks about departments.
   In HR's settings:

    ```text
    DEPARTMENT_HOOKS=http://tasks-backend.conservices-tasks.svc.cluster.local:8080/api/internal/departments|<TASKS_SERVICE_TOKEN>
    ```

    The Tasks chart already admits HR's backend; HR's namespace needs the
    matching egress rule to `conservices-tasks` port 8080 (see
    [Network policies](../../operations/network-policies.md#calls-between-modules)).
    Departments that existed before can be seeded with
    `scripts/backfill-department-spaces.ps1` from the `con-services`
    repository.

9. **Verify:**

    ```sh
    kubectl exec -n conservices-tasks deploy/tasks-frontend -- wget -qO- http://tasks-backend:8080/api/health
    ```

    ```json
    {"status":"ok","database":"ok","version":"1.0.0-1","uptime_sec":31}
    ```

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

- **Back up the database (and bucket) yourself.**

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
    image: registry.example.org/conservices/tasks-frontend:1.0.0-1   # your own build
    restart: unless-stopped
    networks: [internal]
    volumes:
      # infra/nginx.stack.conf from the Tasks repository: forwards /api/ to tasks-backend:8080.
      - ./tasks/nginx.stack.conf:/etc/nginx/conf.d/default.conf:ro
```

- One `tasks-backend` container only.
- Proxy block: `tasks.con.example.org { reverse_proxy tasks-frontend:80 }`.
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
