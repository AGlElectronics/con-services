# Set up Finance

This page installs Finance. Pick one of four ways:

| Option | When | Data safe? |
| --- | --- | --- |
| [1. Kubernetes platform](#option-1-kubernetes-platform-recommended) (recommended) | Production, with Den running | Yes, backed up by Den's operator |
| [2. Standalone on Kubernetes](#option-2-standalone-on-kubernetes) | Only Finance | Yes, if **you** back it up |
| [3. Production on Docker](#option-3-production-on-docker) | One server, no Kubernetes | Yes, with care |
| [4. Development on Docker](#option-4-development-on-docker) | Trying it out | **No**: public passwords |

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
   database URL into your secret manager.

2. **Create the namespace:**

    ```sh
    kubectl create namespace conservices-finance
    kubectl label namespace conservices-finance \
      conservices.io/tier=module conservices.io/module=finance \
      pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/warn=restricted
    ```

3. **Store the secret** and let an `ExternalSecret` create
   `finance-secrets` (see [Secrets](../../operations/secrets.md)):

    ```sh
    vault kv put secret/conservices/finance/backend \
      DATABASE_URL='postgres://finance:change-me@postgres.conservices-data.svc.cluster.local:5432/finance?sslmode=disable'
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
    ingress:
      host: finance.example.org
    ```

    ```sh
    helm install finance deploy/charts/finance -n conservices-finance -f my-finance.yaml
    kubectl get pods -n conservices-finance -w
    ```

5. **Give people access:** add them to the `finance-admin` group in
   Keycloak, or grant the **Finance admin** role in HR's access picker.

6. **Pair with Den:** Den: **Modules → Pair** on the Finance row; Finance:
   **Settings → Den connection**, paste, **Connect**.

7. **Verify:**

    ```sh
    kubectl exec -n conservices-finance deploy/finance-frontend -- wget -qO- http://finance-backend:8080/readyz
    ```

    ```json
    {"status":"ok","database":"ok"}
    ```

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

**Back up the database yourself** (`pg_dump --format=custom`, encrypted,
kept elsewhere). Invoices must not be lost.

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
    image: registry.example.org/conservices/finance-frontend:1.0.0-1   # your own build
    restart: unless-stopped
    networks: [internal]
    volumes:
      # infra/nginx.stack.conf from the Finance repository: forwards /api/ to finance-backend:8080.
      - ./finance/nginx.stack.conf:/etc/nginx/conf.d/default.conf:ro
```

Proxy block: `finance.con.example.org { reverse_proxy finance-frontend:80 }`.

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

!!! note "The standalone stack defaults to real sign-in"
    Finance's `.env.example` sets `AUTH_MODE=oidc` against a Keycloak on
    `localhost:8085`. For header-only local work set `AUTH_MODE=dev` (and
    `VITE_AUTH_MODE=dev` when building the frontend).

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
