# Set up Rally

This page installs Rally (Events). Pick the posture that matches what you
are building:

| Posture | Database, storage, sign-in | Den | Use it for |
| --- | --- | --- | --- |
| [Platform on Kubernetes](#recommended-install-into-the-platform) (recommended) | Shared platform services | Paired | Production |
| [Standalone on Kubernetes](#standalone-on-kubernetes) | Your own | Optional | A CfP and schedule tool on its own |
| [Production with Docker](#production-with-docker) | Your own or the platform's | Optional | One server, no Kubernetes |
| [Development with Docker](#development-with-docker) | Throwaway containers | Optional | Trying it out, coding. **Never production.** |

!!! info "Words used on this page"
    A **namespace** is a named section of a Kubernetes cluster. A **Helm
    chart** is a package of manifests with settings ("values"). An
    **initContainer** runs to completion before the main container starts;
    Rally uses one to migrate its database. A **realm** is a separate set of
    users and clients in Keycloak. **Pairing** connects Rally to Den
    ([details](../../concepts/pairing.md)). **Presigned URL**: a short-lived
    link that lets a browser upload or download one file directly from S3.

!!! note "Two names"
    In Den, the database, Keycloak and groups, Rally is called `events`. The
    images, chart and namespace use `rally`. Both mean the same module.

## Recommended: install into the platform

You install Rally into a running platform: Den, Keycloak, PostgreSQL and
S3 storage are up. If not, start with
[How the platform starts](../../getting-started/how-the-platform-starts.md).

!!! warning "First version, not yet tested on a cluster"
    The chart `deploy/charts/rally` (`0.1.0`) is new and no Rally images are
    published yet. Build and push `rally-backend`, `rally-migrate` and
    `rally-frontend` (plus the submission site if you want it) yourself and
    set the tags. Rally's own `deploy/kubernetes` folder is an older sketch
    (port 8100, namespace `rally`): do not use it.

### 1. Register Rally in Den and create its database

In Den: **Admin console → Modules → New module** with short name
**`events`**, display name `Events`, your Rally address, and **Create a
database for it** ticked. Den shows the connection URL **once**:

```text
postgres://events:4c2b…19@postgres.conservices-data.svc.cluster.local:5432/events?sslmode=disable
```

Copy it into your secret manager straight away.

### 2. Prepare Keycloak

Staff sign in through the `conservices` realm, which already contains the
client `events-spa` and the groups `events-admin`, `events-organizer`,
`events-programme` and `events-reviewer`. Put your programme team into
those groups (or let HR do it).

Attendees sign in through a **separate realm**, `attendees`, with the
public client `rally-submit`. The platform's Kubernetes manifests only
import the `conservices` realm, so this step is **not automated**:

1. In the Keycloak admin console: **Create realm → Browse** and choose
   `infra/keycloak/realm-attendees.json` from the `con-services` checkout.
2. In the new realm: **Users**, delete the test users `ada@attendee.test`
   and `ben@attendee.test` (their password is `attendee`).
3. **Clients → rally-submit**: replace the `conservices.test` addresses in
   **Valid redirect URIs** and **Web origins** with your submission site's
   address, for example `https://submit.example.org/*`.
4. **Realm settings → Email**: configure SMTP. The realm has
   self-registration, email verification and password reset switched on,
   and all three need email.

### 3. Create the namespace

```sh
kubectl create namespace conservices-rally
kubectl label namespace conservices-rally \
  conservices.io/tier=module conservices.io/module=rally \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted
```

```text
namespace/conservices-rally created
namespace/conservices-rally labeled
```

### 4. Create the secret from your secret manager

Rally reads one Secret, `rally-secrets`:

| Key | Required | Value |
| --- | --- | --- |
| `DATABASE_URL` | yes | The URL from step 1. |
| `S3_ACCESS_KEY_ID` | while `S3_ENABLED=true` | An S3 access key allowed to use the `events-data` bucket (and create it once). |
| `S3_SECRET_ACCESS_KEY` | while `S3_ENABLED=true` | Its secret. |
| `TELEGRAM_BOT_TOKEN` | no | Bot token for live-day announcements. Empty means sends are recorded but nothing is posted. |

```sh
vault kv put secret/conservices/rally/backend \
  DATABASE_URL='postgres://events:change-me@postgres.conservices-data.svc.cluster.local:5432/events?sslmode=disable' \
  S3_ACCESS_KEY_ID=change-me \
  S3_SECRET_ACCESS_KEY=change-me
```

Create an `ExternalSecret` named `rally-secrets` in `conservices-rally`
that extracts `conservices/rally/backend`, exactly as for Stash
([Secrets](../../operations/secrets.md#recommended-external-secrets-operator)).
Check it:

```sh
kubectl get externalsecret -n conservices-rally
```

```text
NAME            STORE   REFRESH INTERVAL   STATUS         READY
rally-secrets   vault   1h                 SecretSynced   True
```

Also create the TLS Secret `conservices-tls` in the namespace (cert-manager
or `kubectl create secret tls`). It must cover the staff host and, if you
run it, the submission host.

### 5. Create the access configuration

The access configuration maps Keycloak groups to Rally roles. Start from
the file in the Rally checkout:

```sh
kubectl create configmap rally-access-config -n conservices-rally \
  --from-file=access-config.toml=Rally/infra/access-config.toml
```

```text
configmap/rally-access-config created
```

The file grants roles in the organisation `demo-org`. Keep that until you
have renamed it ([Admin guide](admin-guide.md#organisations-and-editions)).

### 6. Build the submission site { #build-the-submission-site }

Skip this if you do not want the public submission site. It is the same
frontend source built with `RALLY_APP=submit`; no image is published for
it. Build it from the `Rally/` checkout:

```sh
docker build -f infra/Dockerfile.frontend \
  --build-arg RALLY_APP=submit \
  --build-arg VITE_AUTH_MODE=oidc \
  --build-arg VITE_OIDC_AUTHORITY=https://auth.example.org/realms/attendees \
  --build-arg VITE_OIDC_CLIENT_ID=rally-submit \
  --build-arg VITE_PRODUCT_NAME="Event submissions" \
  --build-arg VITE_PUBLIC_SCHEDULE_KEY=change-me-programme-key \
  -t registry.example.org/rally-submit:1.0.0-1 .
docker push registry.example.org/rally-submit:1.0.0-1
```

`VITE_PUBLIC_SCHEDULE_KEY` must equal the backend's
`PUBLIC_API_BUILTIN_KEY` (step 7). It is compiled into the site and visible
to every visitor, so it is **not** a secret: it only lets you rotate the
key and see its use.

### 7. Write your values and install the chart

`rally-values.yaml`:

```yaml
image:
  backend: { tag: "1.0.0-1" }
  migrate: { tag: "1.0.0-1" }
  frontend: { tag: "1.0.0-1" }
ingress:
  host: events.example.org
submit:
  enabled: true
  image: { repository: registry.example.org/rally-submit, tag: "1.0.0-1" }
  host: submit.example.org
config:
  APP_BASE_URL: https://events.example.org
  CORS_ALLOWED_ORIGINS: https://events.example.org,https://submit.example.org
  OIDC_ISSUER_URL: https://auth.example.org/realms/conservices
  ATTENDEE_OIDC_ISSUER_URL: https://auth.example.org/realms/attendees
  S3_PUBLIC_BASE_URL: https://s3.example.org
  PUBLIC_API_BUILTIN_KEY: change-me-programme-key
```

`S3_PUBLIC_BASE_URL` is the address **browsers** use to reach the S3
storage; Rally rewrites its signed links to it. If it is wrong, uploads
fail in the browser while everything else works.

```sh
helm install rally deploy/charts/rally -n conservices-rally -f rally-values.yaml
```

```text
NAME: rally
NAMESPACE: conservices-rally
STATUS: deployed
REVISION: 1
NOTES:
Rally 1.0.0-1 is installed in namespace conservices-rally.
...
```

### 8. Back up the bucket with the platform

Rally creates its bucket `events-data` on first start. Den's backup job
only copies the buckets listed in its `FILES_S3_BUCKETS` setting: add
`events-data` there and re-apply Den's configuration (**not automated**;
see [Databases and backups](../../operations/databases-and-backups.md)).

### 9. Check the pods

```sh
kubectl get pods -n conservices-rally -w
```

```text
NAME                              READY   STATUS     RESTARTS   AGE
rally-backend-5f7c9d8b6-q2wlx     0/1     Init:0/1   0          5s
rally-backend-5f7c9d8b6-q2wlx     1/1     Running    0          17s
rally-frontend-7d6c5b4f9-h8kzn    1/1     Running    0          17s
rally-frontend-7d6c5b4f9-p3rtv    1/1     Running    0          17s
rally-submit-6b8d7c9f5-x9mjq      1/1     Running    0          17s
rally-submit-6b8d7c9f5-c4ndw      1/1     Running    0          17s
```

`Init:0/1` is the migration; its log ends with `migrations applied`:

```sh
kubectl logs -n conservices-rally deploy/rally-backend -c migrate
kubectl exec -n conservices-rally deploy/rally-frontend -- wget -qO- http://rally-backend:8080/api/health
```

```json
{"status":"ok","database":"ok","version":"1.0.0-1","uptime_sec":42}
```

### 10. Pair Rally with Den

1. In Den: **Admin console → Modules → Pair** on the Events row; copy the
   URL.
2. In Rally: **Organizations → Den connection**, paste it and confirm. You
   need the `org.manage` permission (`events-admin`).

Rally then takes the brand and organisation name from Den, and the Den
setting `events_public_schedule` decides whether the public schedule is
served.

### 11. Sign in and check

1. Open `https://events.example.org` as a member of `events-admin`. You
   should see the edition "Demo Convention — Next Edition".
2. Open `https://submit.example.org`, register an attendee account and
   check that open calls are listed.
3. If you want the website to show the schedule, see
   [Public schedule](admin-guide.md#public-schedule).

## Standalone on Kubernetes

Run Rally without the rest of the platform. Without Den, Rally uses its own
brand (optionally a `brand.json` from `BRAND_LOCAL_PATH`), the public
schedule switch is `PUBLIC_SCHEDULE_ENABLED`, and themes stay in the
browser. Pair later at any time. The general steps are in
[Run one module on Kubernetes](../../getting-started/standalone-kubernetes.md);
what is specific to Rally:

1. **Database:** create it yourself; the migrate initContainer creates the
   tables.

    ```sql
    CREATE ROLE events LOGIN PASSWORD 'change-me';
    CREATE DATABASE events OWNER events;
    ```

2. **Storage:** any S3-compatible service. Give Rally a key for its bucket;
   it creates the bucket if missing. To run without attachments, set
   `S3_ENABLED: "false"` (uploads then fail).
3. **Identity provider:** any OIDC provider whose tokens carry a `groups`
   (or `roles`) claim. Edit the bindings in `access-config.toml` to your
   group names. For the submission site you need a **second** issuer for
   attendees; without `ATTENDEE_OIDC_ISSUER_URL` the site only lists open
   calls.
4. **Values:**

    ```yaml
    image:
      backend: { tag: "1.0.0-1" }
      migrate: { tag: "1.0.0-1" }
      frontend: { tag: "1.0.0-1" }
    ingress:
      host: events.example.org
    config:
      APP_BASE_URL: https://events.example.org
      CORS_ALLOWED_ORIGINS: https://events.example.org
      OIDC_ISSUER_URL: https://login.example.org/realms/example
      OIDC_CLIENT_ID: rally
      OIDC_AUDIENCE: rally
      ATTENDEE_OIDC_ISSUER_URL: ""
      ATTENDEE_OIDC_CLIENT_ID: ""
      S3_ENDPOINT: https://s3.example.org
      S3_BUCKET: example-events
      S3_USE_PATH_STYLE: "false"
      S3_PUBLIC_BASE_URL: ""
      PUBLIC_SCHEDULE_ENABLED: "true"
      DEN_INTERNAL_URL: ""
    networkPolicy:
      den: { enabled: false }
      data: { enabled: false }
      allowFromNamespaces: []
      oidcViaIngressController: false
      extraEgress:
        - to: [{ ipBlock: { cidr: 10.20.0.0/24 } }]   # your PostgreSQL
          ports: [{ protocol: TCP, port: 5432 }]
        - to: [{ ipBlock: { cidr: 0.0.0.0/0 } }]      # S3, identity provider, Telegram
          ports: [{ protocol: TCP, port: 443 }]
    ```

    Leave `S3_PUBLIC_BASE_URL` empty when `S3_ENDPOINT` is already reachable
    from browsers.

5. Namespace, secret, access configuration and install as in steps 3, 4, 5,
   7 and 9.

!!! warning "Backups are your job"
    Standalone, nothing backs Rally up. Schedule an encrypted
    `pg_dump --format=custom` of the `events` database and a copy of the
    bucket.

## Production with Docker

Follow [Full stack on Docker](../../operations/docker-production.md) first:
it sets up the host, the proxy, Keycloak, Den and the hardened
`compose.production.yml`. Rally is then added to that file like Den. Rally
needs these containers:

| Container | Image | Runs | Needs |
| --- | --- | --- | --- |
| `events-migrate` | `ghcr.io/aglelectronics/rally-migrate:<tag>` | once per upgrade, must exit 0 | `DATABASE_URL` |
| `events-backend` | `ghcr.io/aglelectronics/rally-backend:<tag>` | always, port 8080 | the environment below, the access configuration |
| `events-frontend` | your build of the staff app | always, port 80 | reaches the backend as `events-backend:8080` |
| `events-submit` (optional) | your build of the submission site ([step 6](#build-the-submission-site)) | always, port 80 | the same |

Both web apps must be **your own builds**: they read their sign-in
settings when they are built. Build them with
`--build-arg NGINX_CONF=nginx.stack.conf`, whose nginx configuration
proxies to `events-backend:8080` (the default `nginx.conf` expects a
service called `backend`):

```sh
docker build -f infra/Dockerfile.frontend \
  --build-arg NGINX_CONF=nginx.stack.conf \
  --build-arg VITE_AUTH_MODE=oidc \
  --build-arg VITE_OIDC_AUTHORITY=https://auth.con.example.org/realms/conservices \
  --build-arg VITE_OIDC_CLIENT_ID=events-spa \
  -t registry.example.org/conservices/rally-frontend:1.0.0-1 .
```

For the submission site add the same `NGINX_CONF` argument to step 6.

1. Create the attendee realm in Keycloak (step 2 above): put
   `realm-attendees.json` into the `./realm` import folder, or import it in
   the admin console.
2. Write the env file. There are no default passwords; replace every
   `change-me`:

    ```text
    # /etc/conservices/rally-backend.env   (mode 600; values from the secret manager)
    DATABASE_URL=postgres://events:change-me@db.example.org:5432/events?sslmode=require
    S3_ACCESS_KEY_ID=change-me
    S3_SECRET_ACCESS_KEY=change-me
    TELEGRAM_BOT_TOKEN=
    ```

3. Copy `Rally/infra/access-config.toml` to
   `./rally/access-config.toml` next to the compose file.
4. Add the services to `compose.production.yml`:

    ```yaml
      events-migrate:
        image: ghcr.io/aglelectronics/rally-migrate:1.0.0-1
        <<: *hardening
        restart: "no"
        networks: [internal, egress]
        env_file: /etc/conservices/rally-backend.env
        environment:
          APP_ENV: production

      events-backend:
        image: ghcr.io/aglelectronics/rally-backend:1.0.0-1
        <<: *hardening
        depends_on:
          events-migrate: { condition: service_completed_successfully }
        networks: [internal, egress]   # egress: database, S3, Telegram
        env_file: /etc/conservices/rally-backend.env
        environment:
          APP_ENV: production
          APP_BASE_URL: https://events.con.example.org
          HTTP_ADDR: ":8080"
          AUTH_MODE: oidc
          OIDC_ISSUER_URL: https://auth.con.example.org/realms/conservices
          OIDC_CLIENT_ID: events-spa
          OIDC_AUDIENCE: events-spa
          ATTENDEE_OIDC_ISSUER_URL: https://auth.con.example.org/realms/attendees
          ATTENDEE_OIDC_CLIENT_ID: rally-submit
          ACCESS_CONFIG_PATH: /etc/rally/access-config.toml
          S3_ENDPOINT: https://fsn1.your-objectstorage.com
          S3_BUCKET: example-events
          S3_REGION: fsn1
          S3_USE_PATH_STYLE: "false"
          PUBLIC_SCHEDULE_ENABLED: "false"
          PUBLIC_API_BUILTIN_KEY: change-me-programme-key
          DEN_INTERNAL_URL: http://den-backend:8080
          CORS_ALLOWED_ORIGINS: https://events.con.example.org,https://submit.con.example.org
        volumes:
          - ./rally/access-config.toml:/etc/rally/access-config.toml:ro

      events-frontend:
        image: registry.example.org/conservices/rally-frontend:1.0.0-1   # your own build
        restart: unless-stopped
        networks: [internal]

      events-submit:
        image: registry.example.org/conservices/rally-submit:1.0.0-1     # your own build
        restart: unless-stopped
        networks: [internal]
    ```

    With managed S3 reachable from browsers, leave `S3_PUBLIC_BASE_URL`
    unset.

5. Add the hosts to the `Caddyfile`:

    ```text
    events.con.example.org {
    	reverse_proxy events-frontend:80
    }

    submit.con.example.org {
    	reverse_proxy events-submit:80
    }
    ```

6. Add the bucket to Den's operator (`FILES_S3_BUCKETS: example-den,example-stash,example-events`)
   so it is backed up, then start and check:

    ```sh
    docker compose -f compose.production.yml up -d
    docker compose -f compose.production.yml logs events-migrate | tail -n 1
    docker compose -f compose.production.yml exec events-frontend wget -qO- http://events-backend:8080/readyz
    ```

```json
{"status":"ok","database":"ok"}
```

## Development with Docker

Quick and easy; development passwords; **not for production**.

**Inside the full local stack** (root of `con-services`). Rally is in the
`events` profile:

```sh
docker compose --profile events up -d --build
```

| Address | What |
| --- | --- |
| <https://events.conservices.test> or <http://localhost:3002> | Staff app |
| <https://submit.conservices.test> or <http://localhost:3004> | Submission site (test attendees `ada@attendee.test` and `ben@attendee.test`, password `attendee`) |
| <http://localhost:8100> | Backend API |

The public schedule is switched on, and the programme key is
`rsk_programme_dev_key`. See
[Local development with Docker Compose](../../contributing/local-development.md).

**Rally on its own** (from the `Rally/` checkout), with its own PostgreSQL
and MinIO and `AUTH_MODE=dev` (no sign-in; everyone is `dev-admin`):

```sh
docker compose -f infra/docker-compose.yml up --build
curl -s http://localhost:8100/livez
curl -s -H 'X-Dev-User: dev-admin' http://localhost:8100/api/v1/me
```

```json
{"status":"ok"}
```

Open <http://localhost:3002>.

## Troubleshooting

**The backend pod is stuck in `Init:CrashLoopBackOff`.** The migration
failed. `kubectl logs -n conservices-rally deploy/rally-backend -c migrate`
shows why: a wrong `DATABASE_URL`, or the NetworkPolicy blocks PostgreSQL.

**`invalid config: S3_ENDPOINT is required when S3_ENABLED=true`** (or the
same for `S3_BUCKET` and the keys). Set all four, or `S3_ENABLED=false`.

**`ATTENDEE_OIDC_ISSUER_URL must be a different realm than OIDC_ISSUER_URL`.**
Attendees need their own realm or issuer; using the staff realm would let
public accounts act as staff.

**Staff can sign in but see no edition, or get 403 everywhere.** Their
token's groups match no binding in the access configuration, or the
bindings point at an organisation slug that does not exist. Check
`GET /api/v1/me`: `memberships` and `permissions` must not be empty.

**Uploading a file fails in the browser; the network tab shows a failed
request to `minio…` or an internal address.** `S3_PUBLIC_BASE_URL` is
missing or wrong. It must be the S3 address as browsers see it.

**The website gets 404 from `/api/public/v1/schedules`.** The public
schedule is switched off: in Den (**Settings → `events_public_schedule`**)
when paired, otherwise `PUBLIC_SCHEDULE_ENABLED`.

**The website gets 401 from the public schedule.** It sends no key or a
revoked one. Create a key under **Schedule → Setup** and send it as
`Authorization: Bearer <key>` (or `?key=` for calendar feeds).

**The submission site's Programme page shows nothing.** Its
`VITE_PUBLIC_SCHEDULE_KEY` differs from the backend's
`PUBLIC_API_BUILTIN_KEY`, or the public schedule is switched off.

**Announcements are "sent" but nothing appears in Telegram.**
`TELEGRAM_BOT_TOKEN` is empty (dry run), or the NetworkPolicy blocks
`api.telegram.org`: add an `extraEgress` rule for port 443.

**HR shows Events with "error" in the access step.** HR cannot reach
`http://rally-backend.conservices-rally.svc.cluster.local:8080/api/role-catalog`.
Rally's chart already allows `conservices-hr`; check HR's egress rule and
`ROLE_CATALOG_SOURCES`.
