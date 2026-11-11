# Set up Rally

This page installs Rally (Events). Pick the posture that matches what you
are building:

| Posture | Database, storage, sign-in | Den | Use it for |
| --- | --- | --- | --- |
| [Production cluster with Argo CD](../../deploy/apps.md) (recommended for production) | CloudNativePG, Keycloak, managed S3 | Paired | Production: the whole suite on a cluster managed from Git |
| [Platform on Kubernetes](#recommended-install-into-the-platform) | Shared platform services | Paired | A cluster you run yourself; also the local trial cluster |
| [Standalone on Kubernetes](#standalone-on-kubernetes) | Your own | Optional | A CfP and schedule tool on its own |
| [Production with Docker](#production-with-docker) | Your own or the platform's | Optional | One server, no Kubernetes |
| [Development with Docker](#development-with-docker) | Throwaway containers | Optional | Trying it out, coding. **Never production.** |

The Argo CD path installs Rally together with Den and the other modules; see [Den and the modules](../../deploy/apps.md). A local Kubernetes cluster (the [quickstart](../../getting-started/den-quickstart.md)) is for trials only.

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
    The chart `deploy/charts/rally` (released with Rally as
    `rally/vX.Y.Z`) has not been installed on a real cluster yet. It ships
    empty image tags: set the tags of `rally-backend`, `rally-migrate`,
    `rally-frontend` (and `rally-submit` if you want the submission site)
    to the release you install, for example `1.0.0-1`. Rally's own
    `deploy/kubernetes` folder is an unmaintained sketch (port 8100,
    namespace `rally`): do not use it.

### 1. Register Rally in Den and create its database

In Den: **Admin console → Modules → New module** with short name
**`events`**, display name `Events`, your Rally address, and **Create a
database for it** ticked. Den shows the connection URL **once**:

```text
postgres://events:4c2b…19@postgres.conservices-data.svc.cluster.local:5432/events?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt
```

Copy it into your secret manager straight away. The `sslmode=verify-full`
part makes Rally connect with TLS and check the database's certificate
against the platform's internal CA; the platform's PostgreSQL refuses
connections without TLS.

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

The `app.kubernetes.io/part-of` label lets trust-manager copy the internal
CA into the namespace ([Internal TLS](#internal-tls)).

```sh
kubectl create namespace conservices-rally
kubectl label namespace conservices-rally \
  conservices.io/tier=module conservices.io/module=rally \
  app.kubernetes.io/part-of=conservices \
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
  DATABASE_URL='postgres://events:change-me@postgres.conservices-data.svc.cluster.local:5432/events?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt' \
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
run it, the submission host. That is the public certificate browsers see;
the certificates for traffic inside the cluster (`rally-backend-tls`,
`rally-frontend-tls`) are requested from cert-manager by the chart
([Internal TLS](#internal-tls)).

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

### 6. Decide on the submission site { #build-the-submission-site }

Skip this if you do not want the public submission site. It is the same
frontend source built with `RALLY_APP=submit` and published as
`ghcr.io/aglelectronics/rally-submit` with the same tag as the other Rally
images. Like the staff app it names no domain: the chart gives it its own
`/config.json` (`submit.config`), filled in from
`config.ATTENDEE_OIDC_ISSUER_URL`, `config.ATTENDEE_OIDC_CLIENT_ID` and
`config.PUBLIC_API_BUILTIN_KEY`. So step 7 only needs `submit.enabled: true`
and those settings.

`PUBLIC_API_BUILTIN_KEY` becomes the site's `publicScheduleKey`, the key
its Programme page sends to the public schedule API. Every visitor can read
it, so it is **not** a secret: it only lets you rotate the key and see its
use.

### 7. Write your values and install the chart

`rally-values.yaml`:

```yaml
image:
  backend: { tag: "1.0.0-1" }
  migrate: { tag: "1.0.0-1" }
  frontend: { tag: "1.0.0-1" }
route:
  host: events.example.org
submit:
  enabled: true   # image ghcr.io/aglelectronics/rally-submit, tag of image.frontend
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

The chart's defaults already point at the platform services over HTTPS
(`S3_ENDPOINT: https://s3.conservices-data.svc.cluster.local:9000`,
`DEN_INTERNAL_URL: https://den-backend.conservices-den.svc.cluster.local:8080`),
and internal TLS is on (`internalTLS.enabled: true`). The cluster needs
cert-manager, trust-manager and the platform's internal CA; see
[Internal TLS](#internal-tls).

With `submit.enabled: true` the chart creates two HTTPRoutes: `rally` for
the staff app and `rally-submit` for the submission site. Each web app has
its own internal certificate (`rally-frontend-tls`, `rally-submit-tls`)
and its own `BackendTLSPolicy`, so the Gateway checks each one
separately.

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
kubectl get certificate -n conservices-rally
kubectl exec -n conservices-rally deploy/rally-frontend -- curl -s --cacert /etc/conservices-internal-ca/ca.crt https://rally-backend:8080/api/health
```

```text
NAME                 READY   SECRET               AGE
rally-backend-tls    True    rally-backend-tls    40s
rally-frontend-tls   True    rally-frontend-tls   40s
```

```json
{"status":"ok","database":"ok","version":"1.0.0-1","uptime_sec":42}
```

The backend answers over HTTPS. `--cacert` makes `curl` check its certificate against the internal CA, which is mounted in the web app pod
at `/etc/conservices-internal-ca`; nginx does the same check on every
`/api/` request.

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
    route:
      host: events.example.org
    den: { mode: standalone }   # no Den: do not wait for pairing
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

5. **Internal TLS** stays on by default and needs cert-manager,
   trust-manager and an issuer in your cluster. Without them, turn it off
   or bring your own certificates ([Without cert-manager](#without-cert-manager)).
   For a managed database, end `DATABASE_URL` in
   `?sslmode=verify-full&sslrootcert=<path to the provider's CA>` and mount
   that CA file with `backend.extraVolumes` and `backend.extraVolumeMounts`.
6. Namespace, secret, access configuration and install as in steps 3, 4, 5,
   7 and 9.

!!! warning "Backups are your job"
    Standalone, nothing backs Rally up. Schedule an encrypted
    `pg_dump --format=custom` of the `events` database and a copy of the
    bucket.

## Internal TLS

On Kubernetes, Rally encrypts the traffic **inside** the cluster as well,
not only between browsers and the Gateway. It is on by default
in the Helm chart. The shared how-to, including the platform setup and
certificate rotation, is [Internal TLS](../../operations/internal-tls.md).

What happens:

- **cert-manager** (a Kubernetes add-on that issues and renews
  certificates) issues `rally-backend-tls` and `rally-frontend-tls` from
  the ClusterIssuer `conservices-internal-ca`. They last 90 days and are
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
- The **web app**'s nginx serves HTTPS on port 8080, forwards `/api/` to the
  backend over HTTPS and checks the backend's certificate. It reloads every
  six hours to pick up a renewed certificate. Its Service listens on port
  443 (port name `https`).
- **The gateway** talks HTTPS to the web app and checks its certificate (a `BackendTLSPolicy`; with the legacy Ingress, the ingress controller does it).

Check it:

```sh
kubectl get certificate -n conservices-rally
kubectl get configmap conservices-internal-ca -n conservices-rally
kubectl logs -n conservices-rally deploy/rally-backend | grep "tls enabled"
```

Both certificates should be `READY True`, the ConfigMap should exist, and
the backend's `tls enabled` log line carries the certificate's expiry date
in `not_after`. The chart values are listed in
[Configuration → Helm values](configuration.md#helm-values).

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
kubectl create secret generic rally-backend-tls -n conservices-rally \
  --from-file=tls.crt=backend.crt --from-file=tls.key=backend.key --from-file=ca.crt=ca.crt
kubectl create secret generic rally-frontend-tls -n conservices-rally \
  --from-file=tls.crt=frontend.crt --from-file=tls.key=frontend.key --from-file=ca.crt=ca.crt
kubectl create configmap my-internal-ca -n conservices-rally --from-file=ca.crt=ca.crt
```

```yaml
internalTLS:
  createCertificates: false
  caConfigMap: my-internal-ca
```

The backend certificate must be valid for `rally-backend` and
`rally-backend.conservices-rally.svc.cluster.local`, the web app's for
`rally-frontend.conservices-rally.svc.cluster.local`. Replace them before
they expire; the backend picks up new files within a minute, nginx within
six hours. The `BackendTLSPolicy` that the Gateway API route renders checks
the web app's certificate against `internalTLS.caConfigMap` and
`rally-frontend.conservices-rally.svc.cluster.local` (and `rally-submit…`
for the submission site), so those names must be in your certificates.
With the legacy Ingress (`ingress.enabled: true`), configure your
controller to use HTTPS to port 443 of `rally-frontend` and check its
certificate, for example Traefik as in
[Other ingress controllers](../../operations/internal-tls.md#other-ingress-controllers).
ingress-nginx is no longer maintained; do not use it.

## Production with Docker

Follow [Full stack on Docker](../../operations/docker-production.md) first:
it sets up the host, the proxy, Keycloak, Den and the hardened
`compose.production.yml`. Rally is then added to that file like Den. Rally
needs these containers:

| Container | Image | Runs | Needs |
| --- | --- | --- | --- |
| `events-migrate` | `ghcr.io/aglelectronics/rally-migrate:<tag>` | once per upgrade, must exit 0 | `DATABASE_URL` |
| `events-backend` | `ghcr.io/aglelectronics/rally-backend:<tag>` | always, port 8080 | the environment below, the access configuration |
| `events-frontend` | `ghcr.io/aglelectronics/rally-frontend:<tag>` | always, port 8080 | reaches the backend as `events-backend:8080` |
| `events-submit` (optional) | `ghcr.io/aglelectronics/rally-submit:<tag>` | always, port 8080 | the same |

The published web app images name no domain. Give each two files next to
the compose file: Rally's `infra/nginx.stack.conf` as its nginx config (it
forwards `/api/` to `events-backend:8080`; the images' built-in config
expects a service called `backend`) and its sign-in settings as
`config.json` (keys: [Web app settings](configuration.md#web-app-settings-configjson)):

```sh
mkdir rally-web
cp ~/src/Rally/infra/nginx.stack.conf rally-web/nginx.conf   # from a checkout of the release you run
cat > rally-web/staff.json <<'EOF'
{
  "authMode": "oidc",
  "oidcAuthority": "https://auth.con.example.org/realms/conservices",
  "oidcClientId": "events-spa"
}
EOF
cat > rally-web/submit.json <<'EOF'
{
  "authMode": "oidc",
  "oidcAuthority": "https://auth.con.example.org/realms/attendees",
  "oidcClientId": "rally-submit",
  "productName": "Event submissions",
  "publicScheduleKey": "change-me-programme-key"
}
EOF
```

`publicScheduleKey` must equal the backend's `PUBLIC_API_BUILTIN_KEY`
below.

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
        image: ghcr.io/aglelectronics/rally-frontend:1.0.0-1
        <<: *hardening
        networks: [internal]
        volumes:
          - ./rally-web/nginx.conf:/etc/nginx/conf.d/default.conf:ro
          - ./rally-web/staff.json:/etc/conservices/config.json:ro

      events-submit:
        image: ghcr.io/aglelectronics/rally-submit:1.0.0-1
        <<: *hardening
        networks: [internal]
        volumes:
          - ./rally-web/nginx.conf:/etc/nginx/conf.d/default.conf:ro
          - ./rally-web/submit.json:/etc/conservices/config.json:ro
    ```

    With managed S3 reachable from browsers, leave `S3_PUBLIC_BASE_URL`
    unset.

5. Add the hosts to the `Caddyfile`:

    ```text
    events.con.example.org {
    	reverse_proxy events-frontend:8080
    }

    submit.con.example.org {
    	reverse_proxy events-submit:8080
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
and S3 server (SeaweedFS, `localhost:9020`) and `AUTH_MODE=dev` (no sign-in; everyone is `dev-admin`):

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
For `no encryption`, see below.

**The backend exits with `tls: TLS_CERT_FILE and TLS_KEY_FILE must be set
together`.** Only one of the two is set, usually because one was added by
hand to `config:` or `backend.extraEnv`. Remove it: the chart sets both
while internal TLS is on, and neither while it is off.

**A pod stays `ContainerCreating`.** It waits for a volume that does not
exist yet: the Secret `rally-backend-tls` or `rally-frontend-tls` (made by
cert-manager) or the ConfigMap `conservices-internal-ca` (made by
trust-manager). `kubectl describe pod` shows `MountVolume.SetUp failed …
not found` under Events. Check:

```sh
kubectl get certificate -n conservices-rally
kubectl describe certificate rally-backend-tls -n conservices-rally
kubectl get configmap conservices-internal-ca -n conservices-rally
```

A certificate that is not `READY True` means cert-manager or the
ClusterIssuer `conservices-internal-ca` is missing; the events of
`kubectl describe certificate` say which. A missing ConfigMap means
trust-manager is not installed, or the namespace lacks the label:
`kubectl label namespace conservices-rally app.kubernetes.io/part-of=conservices`.
Without cert-manager, see [Without cert-manager](#without-cert-manager).

**The web app answers `502 Bad Gateway` and its log shows `upstream SSL
certificate verify error`.** nginx could not check the backend's
certificate. Either the backend serves plain HTTP (its log has no
`tls enabled` line), or its certificate was signed by a CA other than the
one in `conservices-internal-ca` (with your own certificates: put the right
CA in the ConfigMap named by `internalTLS.caConfigMap`). See the error with
`kubectl logs -n conservices-rally deploy/rally-frontend`.

**Calls to Den, storage or the database fail with `x509: certificate signed
by unknown authority`.** The backend does not trust the internal CA:
`SSL_CERT_DIR` is missing, or a value in `config:` replaced it with another
folder. It must include `/etc/conservices-internal-ca`; separate several
folders with `:`. Check with
`kubectl get configmap rally-config -n conservices-rally -o yaml`.

**The migration fails with `no pg_hba.conf entry for host "…", user
"events", database "events", no encryption`.** `DATABASE_URL` still ends in
`sslmode=disable`, and the platform's PostgreSQL accepts only TLS. Change
the end to
`?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt` in
your secret manager, then
`kubectl rollout restart -n conservices-rally deploy/rally-backend`. For a
managed database use `sslmode=verify-full&sslrootcert=<path to the provider's CA>`.

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
request to `s3:9000`, `s3.conservices-data…` or another internal address.** `S3_PUBLIC_BASE_URL` is
missing or wrong. It must be the S3 address as browsers see it.

**The website gets 404 from `/api/public/v1/schedules`.** The public
schedule is switched off: in Den (**Settings → `events_public_schedule`**)
when paired, otherwise `PUBLIC_SCHEDULE_ENABLED`.

**The website gets 401 from the public schedule.** It sends no key or a
revoked one. Create a key under **Schedule → Setup** and send it as
`Authorization: Bearer <key>` (or `?key=` for calendar feeds).

**The submission site's Programme page shows nothing.** The
`publicScheduleKey` in its `/config.json` differs from the backend's
`PUBLIC_API_BUILTIN_KEY`, or the public schedule is switched off. Compare
`curl -s https://submit.example.org/config.json` with the backend setting.

**Announcements are "sent" but nothing appears in Telegram.**
`TELEGRAM_BOT_TOKEN` is empty (dry run), or the NetworkPolicy blocks
`api.telegram.org`: add an `extraEgress` rule for port 443.

**HR shows Events with "error" in the access step.** HR cannot reach
`https://rally-backend.conservices-rally.svc.cluster.local:8080/api/role-catalog`.
Rally's chart already allows `conservices-hr`; check HR's egress rule and
`ROLE_CATALOG_SOURCES`.
