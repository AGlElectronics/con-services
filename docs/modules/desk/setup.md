# Set up Desk

This page installs Desk and connects its first mailbox. Pick one of four
ways:

| Option | When | Data safe? |
| --- | --- | --- |
| [1. Kubernetes platform](#option-1-kubernetes-platform-recommended) (recommended) | Production, with Den running | Yes, backed up by Den's operator |
| [2. Standalone on Kubernetes](#option-2-standalone-on-kubernetes) | Only Desk | Yes, if **you** back it up |
| [3. Production on Docker](#option-3-production-on-docker) | One server, no Kubernetes | Yes, with care |
| [4. Development on Docker](#option-4-development-on-docker) | Trying it out | **No**: public passwords, test mail servers |

## What Desk needs

| Needs | Why |
| --- | --- |
| PostgreSQL 16 database and a login that owns it | Everything, including email attachments. Plan its size accordingly. |
| A long random `DESK_SECRET_KEY` | Encrypts the mailbox passwords stored in the database. **Keep it forever**: with a different key, stored passwords cannot be read and must be typed in again. |
| An IMAP account per support address | Desk reads new mail from it (port 993, or 143 with STARTTLS). |
| An SMTP server | For replies: per mailbox, or the module-wide fallback (`SMTP_*`). |
| An OpenID Connect sign-in server (Keycloak) | Public client `desk-spa`, groups `desk-admin` and `desk-agent`. |

!!! warning "Microsoft 365 and Gmail"
    Desk logs in to IMAP and SMTP with a username and password. Microsoft 365
    and Gmail increasingly refuse passwords (they want OAuth2, which Desk
    does not support yet). Use an app password where your provider allows
    it, or a mail host that accepts IMAP passwords.

## Option 1: Kubernetes platform (recommended)

Den must be running first: [How the platform starts](../../getting-started/how-the-platform-starts.md).

1. **Register Desk in Den** (**Admin console → Modules → New module**, short
   name `desk`, tick **Create a database for it**) and copy the database URL
   into your secret manager.

2. **Create the namespace:**

    ```sh
    kubectl create namespace conservices-desk
    kubectl label namespace conservices-desk \
      conservices.io/tier=module conservices.io/module=desk \
      pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/warn=restricted
    ```

3. **Store the secrets** in your secret manager and let an `ExternalSecret`
   create `desk-secrets` (see [Secrets](../../operations/secrets.md)):

    ```sh
    vault kv put secret/conservices/desk/backend \
      DATABASE_URL='postgres://desk:change-me@postgres.conservices-data.svc.cluster.local:5432/desk?sslmode=disable' \
      DESK_SECRET_KEY="$(openssl rand -hex 32)" \
      SMTP_PASSWORD=change-me
    ```

    ```yaml
    apiVersion: external-secrets.io/v1
    kind: ExternalSecret
    metadata:
      name: desk-secrets
      namespace: conservices-desk
    spec:
      refreshInterval: 1h
      secretStoreRef: { name: vault, kind: SecretStore }
      target: { name: desk-secrets }
      dataFrom:
        - extract: { key: conservices/desk/backend }
    ```

4. **Create the access config** from `infra/access-config.toml` in the Desk
   repository:

    ```sh
    kubectl create configmap desk-access-config -n conservices-desk \
      --from-file=access-config.toml=access-config.toml
    ```

5. **Install the chart.** The default values allow outbound IMAP and SMTP to
   any address; narrow `networkPolicy.extraEgress` to your mail provider if
   you can.

    ```yaml
    # my-desk.yaml
    image:
      backend:  { tag: "1.0.0-1" }
      frontend: { tag: "1.0.0-1" }
      migrate:  { tag: "1.0.0-1" }
    config:
      APP_BASE_URL: https://desk.example.org
      OIDC_ISSUER_URL: https://auth.example.org/realms/conservices
      CORS_ALLOWED_ORIGINS: https://desk.example.org
      SMTP_HOST: smtp.example.org      # fallback for mailboxes without their own
      SMTP_USERNAME: desk@example.org
    ingress:
      host: desk.example.org
    ```

    ```sh
    helm install desk deploy/charts/desk -n conservices-desk -f my-desk.yaml
    kubectl get pods -n conservices-desk -w
    ```

6. **Pair with Den:** Den: **Modules → Pair** on the Desk row; Desk (as
   `desk-admin`): **Settings → Den connection**, paste, **Connect**.

7. **Add the first mailbox.** In Desk as `desk-admin`: **Mailboxes**. Enter
   the name and address (for example `Support`, `support@example.org`), a
   signature (`{agent.name}` is replaced by the person replying), the
   **Incoming mail (IMAP)** server, port, security and login, and optionally
   the **Outgoing mail (SMTP)** server. Click **Create mailbox**, then test
   the connection on the mailbox card. The result shows whether IMAP and
   SMTP logins worked, and which SMTP server is used.

8. **Verify:** send an email to the address. Within `FETCH_INTERVAL`
   (or right away with "fetch now" on the mailbox card) it appears in the
   **Inbox** under **Unassigned**. Reply; within about 10 seconds (the undo
   window) the reply leaves through SMTP.

    ```sh
    kubectl exec -n conservices-desk deploy/desk-frontend -- wget -qO- http://desk-backend:8080/api/health
    ```

    ```json
    {"status":"ok","database":"ok","version":"1.0.0-1","uptime_sec":57}
    ```

## Option 2: Standalone on Kubernetes

Follow [Run one module on Kubernetes](../../getting-started/standalone-kubernetes.md)
with these Desk values. Desk needs no bucket.

```yaml
config:
  APP_BASE_URL: https://desk.example.org
  OIDC_ISSUER_URL: https://login.example.org/realms/conservices
  CORS_ALLOWED_ORIGINS: https://desk.example.org
  DEN_INTERNAL_URL: ""
networkPolicy:
  den:  { enabled: false }
  data: { enabled: false }
  allowFromNamespaces: []
  extraEgress:
    - to: [{ ipBlock: { cidr: 10.20.0.0/24 } }]     # your database subnet
      ports: [{ protocol: TCP, port: 5432 }]
    - to: [{ ipBlock: { cidr: 0.0.0.0/0 } }]        # mail servers
      ports:
        - { protocol: TCP, port: 993 }
        - { protocol: TCP, port: 587 }
```

The secret `desk-secrets` holds `DATABASE_URL` and `DESK_SECRET_KEY`.
**Back up the database yourself**; it contains every email.

## Option 3: Production on Docker

Read [Full stack on Docker (production)](../../operations/docker-production.md),
then add:

```yaml
# in compose.production.yml (services:)
  desk-migrate:
    image: ghcr.io/aglelectronics/desk-migrate:1.0.0-1
    <<: *hardening
    restart: "no"
    networks: [internal, egress]
    env_file: /etc/conservices/desk-backend.env
    environment:
      APP_ENV: production

  desk-backend:
    image: ghcr.io/aglelectronics/desk-backend:1.0.0-1
    <<: *hardening
    depends_on:
      desk-migrate: { condition: service_completed_successfully }
    networks: [internal, egress]               # egress: database and mail servers
    env_file: /etc/conservices/desk-backend.env  # DATABASE_URL, DESK_SECRET_KEY, SMTP_PASSWORD
    environment:
      APP_ENV: production
      APP_BASE_URL: https://desk.con.example.org
      HTTP_ADDR: ":8080"
      AUTH_MODE: oidc
      OIDC_ISSUER_URL: https://auth.con.example.org/realms/conservices
      OIDC_CLIENT_ID: desk-spa
      OIDC_AUDIENCE: desk-spa
      ACCESS_CONFIG_PATH: /etc/desk/access-config.toml
      CORS_ALLOWED_ORIGINS: https://desk.con.example.org
      SMTP_HOST: smtp.example.org
      SMTP_PORT: "587"
      SMTP_SECURITY: starttls
      SMTP_USERNAME: desk@example.org
      DEN_INTERNAL_URL: http://den-backend:8080
    volumes:
      - ./desk/access-config.toml:/etc/desk/access-config.toml:ro

  desk-frontend:
    image: registry.example.org/conservices/desk-frontend:1.0.0-1   # your own build
    restart: unless-stopped
    networks: [internal]
    volumes:
      # infra/nginx.stack.conf from the Desk repository: forwards /api/ to desk-backend:8080.
      - ./desk/nginx.stack.conf:/etc/nginx/conf.d/default.conf:ro
```

One `desk-backend` container only. Proxy block:
`desk.con.example.org { reverse_proxy desk-frontend:80 }`.

## Option 4: Development on Docker

Never for real data. From the root of the `con-services` repository:

```powershell
docker compose --profile desk up --build -d
```

This also starts **GreenMail**, a test mail server: the mailboxes
`support@conservices.test` (password `support`) and
`registration@conservices.test` (password `registration`) at IMAP
`greenmail:3143`. Replies go out through **Mailpit** (`mailpit:1025`),
where you can read them in a browser. Open <https://desk.conservices.test>
(or <http://localhost:3008>). For a mailbox, use IMAP host `greenmail`,
port `3143`, security **None (dev only)**.

On its own, with development sign-in:

```powershell
cd desk
docker compose -f infra/docker-compose.yml up --build
```

| Service | Host port |
| --- | --- |
| backend | 8150 |
| frontend | 3008 |
| PostgreSQL (standalone stack only) | 5440 |

## Why the backend runs one replica

The IMAP fetcher and the reply sender run inside the backend process. Two
replicas would fetch the same mailboxes twice and race over the same queued
replies. The Helm chart refuses any `backend.replicas` other than 1.

## Troubleshooting

**The backend does not start: "DESK_SECRET_KEY is required outside
APP_ENV=development".** Set the key in `desk-secrets`.

**Mailbox passwords stopped working after a redeploy.** `DESK_SECRET_KEY`
changed. Put the old key back, or type every mailbox password in again.

**The mailbox shows a fetch error / connection test fails with a timeout.**
The network policy blocks the mail server: check `extraEgress` ports
(993, 143, 465, 587) and addresses. With "authentication failed", check the
login, and whether your provider needs an app password.

**Replies stay "queued" or show "Not sent".** No SMTP server: the mailbox
has none and `SMTP_HOST` is empty, or the server refused. The thread shows
the error; Desk retries after 1, 5, 15 and 60 minutes, then offers a retry
button.

**`helm install` fails with "backend.replicas must be 1".** Intended; see
above.
