# Set up HR

This page installs HR. Pick the posture that matches what you are building:

| Posture | Database, sign-in | Den | Use it for |
| --- | --- | --- | --- |
| [Production cluster with Argo CD](../../deploy/apps.md) (recommended for production) | CloudNativePG, Keycloak | Paired | Production: the whole suite on a cluster managed from Git |
| [Platform on Kubernetes](#recommended-install-into-the-platform) | Shared platform services | Paired | A cluster you run yourself; also the local trial cluster |
| [Standalone on Kubernetes](#standalone-on-kubernetes) | Your own | Optional | A people register on its own |
| [Production with Docker](#production-with-docker) | Your own or the platform's | Optional | One server, no Kubernetes |
| [Development with Docker](#development-with-docker) | Throwaway containers | Optional | Trying it out, coding. **Never production.** |

The Argo CD path installs HR together with Den and the other modules; see [Den and the modules](../../deploy/apps.md). A local Kubernetes cluster (the [quickstart](../../getting-started/den-quickstart.md)) is for trials only.

!!! info "Words used on this page"
    A **namespace** is a named section of a Kubernetes cluster. A **Helm
    chart** is a package of manifests with settings ("values"). An
    **initContainer** runs to completion before the main container starts;
    HR uses one to migrate its database. **Pairing** connects HR to Den
    ([details](../../concepts/pairing.md)).

## Recommended: install into the platform

You install HR into a running platform: Den, Keycloak and PostgreSQL are
up. If not, start with [How the platform starts](../../getting-started/how-the-platform-starts.md).

!!! warning "First version, not yet tested on a cluster"
    The chart `deploy/charts/hr` (`0.1.0`) is new and no HR images are
    published yet. Build and push `hr-backend`, `hr-migrate` and
    `hr-frontend` yourself (see [Images](index.md#images)) and set the tags.

### 1. Register HR in Den and create its database

In Den: **Admin console → Modules → New module** with short name `hr`,
display name `HR`, your HR address, and **Create a database for it**
ticked. Den shows the connection URL **once**:

```text
postgres://hr:9a1e…77@postgres.conservices-data.svc.cluster.local:5432/hr?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt
```

Copy it into your secret manager straight away. The `sslmode=verify-full`
part makes HR connect with TLS and check the database's certificate
against the platform's internal CA; the platform's PostgreSQL refuses
connections without TLS.

### 2. Prepare Keycloak

HR uses two clients in the `conservices` realm, both already in the
imported realm file:

| Client | Type | Used for |
| --- | --- | --- |
| `hr-spa` | public | Signing in to HR's web app. |
| `hr-provisioner` | confidential, service account | Creating and deleting accounts, setting groups, sending the password-setup email. It can manage users, so treat its secret as sensitive. |

1. In the Keycloak admin console: **Clients → hr-provisioner → Credentials
   → Regenerate**. Copy the new secret (the realm file only has a public
   development value).
2. Make sure the people who run HR are in the group `hr-admin` (or the
   groups you set in `HR_ACCESS_GROUPS`).

### 3. Create the namespace

The `app.kubernetes.io/part-of` label lets trust-manager copy the internal
CA into the namespace ([Internal TLS](#internal-tls)).

```sh
kubectl create namespace conservices-hr
kubectl label namespace conservices-hr \
  conservices.io/tier=module conservices.io/module=hr \
  app.kubernetes.io/part-of=conservices \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted
```

```text
namespace/conservices-hr created
namespace/conservices-hr labeled
```

### 4. Create the secret from your secret manager

HR reads one Secret, `hr-secrets`:

| Key | Required | Value |
| --- | --- | --- |
| `DATABASE_URL` | yes | The URL from step 1. |
| `KEYCLOAK_CLIENT_SECRET` | for real accounts | From step 2. |
| `LEARN_SERVICE_TOKEN` | no | Shared with Learn; turns on training-gated roles. |
| `OFFBOARD_HOOKS` | no | `url|token` list; contains the Wiki's service token. |
| `DEPARTMENT_HOOKS` | no | `url|token` list; contains the Tasks service token. |
| `SMTP_PASSWORD` | no | For HR's own notices. |

```sh
vault kv put secret/conservices/hr/backend \
  DATABASE_URL='postgres://hr:change-me@postgres.conservices-data.svc.cluster.local:5432/hr?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt' \
  KEYCLOAK_CLIENT_SECRET=change-me
```

Create an `ExternalSecret` named `hr-secrets` in `conservices-hr` that
extracts `conservices/hr/backend`, exactly as for Stash
([Secrets](../../operations/secrets.md#recommended-external-secrets-operator)).
Check it:

```sh
kubectl get externalsecret -n conservices-hr
```

```text
NAME         STORE   REFRESH INTERVAL   STATUS         READY
hr-secrets   vault   1h                 SecretSynced   True
```

Also create the TLS Secret `conservices-tls` in the namespace (cert-manager
or `kubectl create secret tls`). That is the public certificate browsers
see; the certificates for traffic inside the cluster (`hr-backend-tls`,
`hr-frontend-tls`) are requested from cert-manager by the chart
([Internal TLS](#internal-tls)).

### 5. Open the network paths HR needs

The chart adds HR's own rules (egress from HR). The **targets** must also
let HR in. This is **not automated** yet:

| Target | Rule needed in the target namespace | Status |
| --- | --- | --- |
| Stash (`conservices-stash`) | ingress from `conservices-hr` backends on 8080 | Already in Stash's manifests and chart. |
| Rally (`conservices-rally`) | the same | In Rally's chart (`allowFromNamespaces`). |
| Keycloak (`conservices-identity`) | ingress from `conservices-hr` backends on 8443 (Keycloak's HTTPS port) | **Missing** from the platform manifests: add it yourself (below). |
| Learn, Wiki, Tasks | the same | Add when those modules are installed. |

Keycloak rule (apply in `conservices-identity`):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: keycloak-from-hr
  namespace: conservices-identity
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: keycloak
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: conservices-hr
          podSelector:
            matchLabels:
              app.kubernetes.io/component: backend
      ports:
        - { protocol: TCP, port: 8443 }
```

More on cross-module rules: [Network policies](../../operations/network-policies.md#calls-between-modules).

### 6. Write your values and install the chart

`hr-values.yaml`:

```yaml
image:
  backend: { tag: "1.0.0-1" }
  migrate: { tag: "1.0.0-1" }
  frontend: { tag: "1.0.0-1" }
route:
  host: hr.example.org
config:
  APP_BASE_URL: https://hr.example.org
  CORS_ALLOWED_ORIGINS: https://hr.example.org
  OIDC_ISSUER_URL: https://auth.example.org/realms/conservices
  KEYCLOAK_SETUP_REDIRECT_URI: https://den.example.org/
  ROLE_CATALOG_SOURCES: >-
    stash=https://stash-backend.conservices-stash.svc.cluster.local:8080/api/role-catalog,events=https://rally-backend.conservices-rally.svc.cluster.local:8080/api/role-catalog
networkPolicy:
  moduleEgressNamespaces: [conservices-stash, conservices-rally]
```

Every in-cluster address uses `https://`: the other modules' backends,
Den (`https://den-backend.conservices-den.svc.cluster.local:8080`) and
Keycloak's admin API
(`https://keycloak.conservices-identity.svc.cluster.local:8443`). Internal
TLS is on by default (`internalTLS.enabled: true`); the cluster needs
cert-manager, trust-manager and the platform's internal CA. See
[Internal TLS](#internal-tls).

```sh
helm install hr deploy/charts/hr -n conservices-hr -f hr-values.yaml
```

```text
NAME: hr
NAMESPACE: conservices-hr
STATUS: deployed
REVISION: 1
NOTES:
HR 1.0.0-1 is installed in namespace conservices-hr.
...
```

### 7. Check the pods

```sh
kubectl get pods -n conservices-hr -w
```

```text
NAME                           READY   STATUS     RESTARTS   AGE
hr-backend-7c9d5b6f4-2xkqp     0/1     Init:0/1   0          5s
hr-backend-7c9d5b6f4-2xkqp     1/1     Running    0          18s
hr-frontend-6d8f7c5b9-m4ntq    1/1     Running    0          18s
hr-frontend-6d8f7c5b9-z7wpl    1/1     Running    0          18s
```

`Init:0/1` is the migration. Its log ends with `migrations applied; exiting`:

```sh
kubectl logs -n conservices-hr deploy/hr-backend -c migrate
```

The backend's log should **not** contain `using FakeIdP`; if it does,
`KEYCLOAK_BASE_URL` or `KEYCLOAK_CLIENT_SECRET` is missing and HR will not
create real accounts.

```sh
kubectl get certificate -n conservices-hr
kubectl exec -n conservices-hr deploy/hr-frontend -- curl -s --cacert /etc/conservices-internal-ca/ca.crt https://hr-backend:8080/readyz
```

```text
NAME              READY   SECRET            AGE
hr-backend-tls    True    hr-backend-tls    40s
hr-frontend-tls   True    hr-frontend-tls   40s
```

```json
{"status":"ready","database":"ok"}
```

The backend answers over HTTPS. `--cacert` makes `curl` check its certificate against the internal CA, which is mounted in the web app pod
at `/etc/conservices-internal-ca`; nginx does the same check on every
`/api/` request.

### 8. Pair HR with Den

1. In Den: **Admin console → Modules → Pair** on the HR row; copy the URL.
2. In HR: **Settings → Den connection**, paste it and confirm.

The organisation name, email domain and the username and email templates
then come from Den and are read-only in HR.

### 9. Sign in and check

Open `https://hr.example.org` as a member of `hr-admin`. The **Access**
step of an onboarding should list the roles of Stash, Rally and the other
sources; a module shown with an error is unreachable (check its
`ROLE_CATALOG_SOURCES` entry and NetworkPolicies).

## Standalone on Kubernetes

Run HR without the rest of the platform. Without Den, HR uses its own
settings (organisation name, email domain, username and email templates on
the **Settings** page) and its own look; themes stay in the browser. Pair
later at any time. The general steps are in
[Run one module on Kubernetes](../../getting-started/standalone-kubernetes.md);
what is specific to HR:

1. **Database:** create it yourself; the migrate initContainer creates the
   tables.

    ```sql
    CREATE ROLE hr LOGIN PASSWORD 'change-me';
    CREATE DATABASE hr OWNER hr;
    ```

2. **Identity provider:** HR's account provisioning is written for the
   **Keycloak** admin API. With another provider, leave `KEYCLOAK_BASE_URL`
   and `KEYCLOAK_CLIENT_SECRET` empty: HR then runs with a fake provisioner
   (it logs `KEYCLOAK_* not set — using FakeIdP`) and creates **no real
   accounts**, so it works as a register only. Sign-in to HR itself works
   with any OIDC provider (`OIDC_ISSUER_URL`, `OIDC_CLIENT_ID`) whose
   tokens carry a `groups` claim containing one of `HR_ACCESS_GROUPS`.
3. **Values:**

    ```yaml
    image:
      backend: { tag: "1.0.0-1" }
      migrate: { tag: "1.0.0-1" }
      frontend: { tag: "1.0.0-1" }
    route:
      host: hr.example.org
    config:
      APP_BASE_URL: https://hr.example.org
      CORS_ALLOWED_ORIGINS: https://hr.example.org
      OIDC_ISSUER_URL: https://login.example.org/realms/example
      OIDC_CLIENT_ID: hr
      OIDC_AUDIENCE: hr
      KEYCLOAK_BASE_URL: https://login.example.org
      KEYCLOAK_REALM: example
      ROLE_CATALOG_SOURCES: ""
      DEN_INTERNAL_URL: ""
    networkPolicy:
      den: { enabled: false }
      data: { enabled: false }
      keycloak: { enabled: false }
      moduleEgressNamespaces: []
      oidcViaIngressController: false
      extraEgress:
        - to: [{ ipBlock: { cidr: 10.20.0.0/24 } }]   # your PostgreSQL
          ports: [{ protocol: TCP, port: 5432 }]
        - to: [{ ipBlock: { cidr: 0.0.0.0/0 } }]      # identity provider, SMTP
          ports: [{ protocol: TCP, port: 443 }, { protocol: TCP, port: 587 }]
    ```

4. **Internal TLS** stays on by default and needs cert-manager,
   trust-manager and an issuer in your cluster. Without them, turn it off
   or bring your own certificates ([Without cert-manager](#without-cert-manager)).
   For a managed database, end `DATABASE_URL` in
   `?sslmode=verify-full&sslrootcert=<path to the provider's CA>` and mount
   that CA file with `backend.extraVolumes` and `backend.extraVolumeMounts`.
5. Namespace, secret and install as in steps 3, 4, 6 and 7.

!!! warning "Backups are your job"
    Standalone, nothing backs HR up. Schedule an encrypted
    `pg_dump --format=custom` of the `hr` database and limit who can read
    it: it contains personal data.

## Internal TLS

On Kubernetes, HR encrypts the traffic **inside** the cluster as well, not
only between browsers and the Gateway. It is on by default in
the Helm chart. The shared how-to, including the platform setup and
certificate rotation, is [Internal TLS](../../operations/internal-tls.md).

What happens:

- **cert-manager** (a Kubernetes add-on that issues and renews
  certificates) issues `hr-backend-tls` and `hr-frontend-tls` from the
  ClusterIssuer `conservices-internal-ca`. They last 90 days and are
  renewed 30 days before they expire. Pods mount them at
  `/etc/conservices-tls` (`tls.crt`, `tls.key`, `ca.crt`).
- **trust-manager** copies the platform's internal CA certificate into the
  ConfigMap `conservices-internal-ca` (key `ca.crt`) in every namespace
  labelled `app.kubernetes.io/part-of: conservices`. Pods mount it at
  `/etc/conservices-internal-ca/ca.crt`.
- The **backend** serves HTTPS on port 8080 (`TLS_CERT_FILE`,
  `TLS_KEY_FILE`) and trusts the internal CA when it calls PostgreSQL,
  Keycloak, Den and the other modules (`SSL_CERT_DIR`). It re-reads its
  certificate every minute, so a renewed one is used without a restart.
- The **web app**'s nginx serves HTTPS on port 8080, forwards `/api/` to the
  backend over HTTPS and checks the backend's certificate. It reloads every
  six hours to pick up a renewed certificate. Its Service listens on port
  443 (port name `https`).
- **The gateway** talks HTTPS to the web app and checks its certificate (a `BackendTLSPolicy`; with the legacy Ingress, the ingress controller does it).

Check it:

```sh
kubectl get certificate -n conservices-hr
kubectl get configmap conservices-internal-ca -n conservices-hr
kubectl logs -n conservices-hr deploy/hr-backend | grep "tls enabled"
```

Both certificates should be `READY True`, the ConfigMap should exist, and
the backend's `tls enabled` log line carries the certificate's expiry date
in `not_after`.

### Chart values

| Value | Default | What it does |
| --- | --- | --- |
| `internalTLS.enabled` | `true` | Turns internal TLS on or off for the backend, the web app and the Ingress. |
| `internalTLS.createCertificates` | `true` | `true`: the chart asks cert-manager for the two certificates. `false`: you create the Secrets `hr-backend-tls` and `hr-frontend-tls` yourself (keys `tls.crt`, `tls.key`, `ca.crt`). |
| `internalTLS.issuerRef` | ClusterIssuer `conservices-internal-ca` | The cert-manager issuer that signs them. |
| `internalTLS.duration` | `2160h` (90 days) | Certificate lifetime. |
| `internalTLS.renewBefore` | `720h` (30 days) | How long before expiry cert-manager renews. |
| `internalTLS.caConfigMap` | `conservices-internal-ca` | ConfigMap (key `ca.crt`) with the CA the pods trust. |
| `internalTLS.ingressNginxAnnotations` | `false` | Legacy, only with `ingress.enabled: true`: adds the ingress-nginx annotations for HTTPS to the web app (`backend-protocol: HTTPS`, `proxy-ssl-verify`). The Gateway API route uses a `BackendTLSPolicy` instead. ingress-nginx is no longer maintained; do not use it. |
| `route.enabled`, `route.host`, `route.parentRefs`, `route.timeout` | `true`, `hr.conservices.test`, Gateway `public` in `conservices-gateway` (listener `https`), `60s` | Exposes the web app through the Gateway API: an `HTTPRoute` and, with internal TLS, a `BackendTLSPolicy` that makes the gateway check `hr-frontend`'s certificate. See [Exposing the web app](../../operations/helm.md#exposing-the-web-app-gateway-api). |
| `frontend.config` | `{}` | The web app's `/config.json` (sign-in address, client id; see [Web app settings](configuration.md#web-app-settings-configjson)), written to the ConfigMap `<release>-frontend-config`. Keys left out come from `config.AUTH_MODE`, `config.OIDC_ISSUER_URL` and `config.OIDC_CLIENT_ID` (else `hr-spa`). |
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
  # In-cluster addresses back to plain HTTP, for example:
  DEN_INTERNAL_URL: http://den-backend.conservices-den.svc.cluster.local:8080
  ROLE_CATALOG_SOURCES: stash=http://stash-backend.conservices-stash.svc.cluster.local:8080/api/role-catalog
```

**Bring your own certificates.** Create the two Secrets with any tool
(your own CA, a secret manager), each with `tls.crt`, `tls.key` and
`ca.crt`, and a ConfigMap with your CA under the key `ca.crt`:

```sh
kubectl create secret generic hr-backend-tls -n conservices-hr \
  --from-file=tls.crt=backend.crt --from-file=tls.key=backend.key --from-file=ca.crt=ca.crt
kubectl create secret generic hr-frontend-tls -n conservices-hr \
  --from-file=tls.crt=frontend.crt --from-file=tls.key=frontend.key --from-file=ca.crt=ca.crt
kubectl create configmap my-internal-ca -n conservices-hr --from-file=ca.crt=ca.crt
```

```yaml
internalTLS:
  createCertificates: false
  caConfigMap: my-internal-ca
```

The backend certificate must be valid for `hr-backend` and
`hr-backend.conservices-hr.svc.cluster.local`, the web app's for
`hr-frontend.conservices-hr.svc.cluster.local`. Replace them before they
expire; the backend picks up new files within a minute, nginx within six
hours.

## Production with Docker

Follow [Full stack on Docker](../../operations/docker-production.md) first:
it sets up the host, the proxy, Keycloak, Den and the hardened
`compose.production.yml`. HR is then added to that file like Den.

| Container | Image | Runs | Needs |
| --- | --- | --- | --- |
| `hr-migrate` | `ghcr.io/aglelectronics/hr-migrate:<tag>` | once per upgrade, must exit 0 | `DATABASE_URL` |
| `hr-backend` | `ghcr.io/aglelectronics/hr-backend:<tag>` | always, port 8080 | the environment below |
| `hr-frontend` | `ghcr.io/aglelectronics/hr-frontend:<tag>` | always, port 8080 | reaches the backend as `hr-backend:8080` |

The published web app image names no domain. Give it two files next to
the compose file: HR's `infra/nginx.stack.conf` as its nginx config (it
forwards `/api/` to `hr-backend:8080`; the image's built-in config expects
a service called `backend`) and its sign-in settings as `config.json`
(keys: [Web app settings](configuration.md#web-app-settings-configjson)):

```sh
mkdir hr-frontend
cp ~/src/hr/infra/nginx.stack.conf hr-frontend/nginx.conf   # from a checkout of the release you run
cat > hr-frontend/config.json <<'EOF'
{
  "authMode": "oidc",
  "oidcAuthority": "https://auth.con.example.org/realms/conservices",
  "oidcClientId": "hr-spa"
}
EOF
```

1. Write the env file. There are no default passwords; replace every
   `change-me`:

    ```text
    # /etc/conservices/hr-backend.env   (mode 600; values from the secret manager)
    DATABASE_URL=postgres://hr:change-me@db.example.org:5432/hr?sslmode=require
    KEYCLOAK_CLIENT_SECRET=change-me
    SMTP_PASSWORD=change-me
    ```

2. Add the services to `compose.production.yml`. HR reaches Keycloak's
   admin API on the internal network:

    ```yaml
      hr-migrate:
        image: ghcr.io/aglelectronics/hr-migrate:1.0.0-1
        <<: *hardening
        restart: "no"
        networks: [internal, egress]
        env_file: /etc/conservices/hr-backend.env
        environment:
          APP_ENV: production

      hr-backend:
        image: ghcr.io/aglelectronics/hr-backend:1.0.0-1
        <<: *hardening
        depends_on:
          hr-migrate: { condition: service_completed_successfully }
        networks: [internal, egress]   # egress: database, SMTP, address lookup
        env_file: /etc/conservices/hr-backend.env
        environment:
          APP_ENV: production
          APP_BASE_URL: https://hr.con.example.org
          HTTP_ADDR: ":8080"
          AUTH_MODE: oidc
          OIDC_ISSUER_URL: https://auth.con.example.org/realms/conservices
          OIDC_CLIENT_ID: hr-spa
          OIDC_AUDIENCE: hr-spa
          HR_ACCESS_GROUPS: hr-admin
          KEYCLOAK_BASE_URL: http://keycloak:8080
          KEYCLOAK_REALM: conservices
          KEYCLOAK_CLIENT_ID: hr-provisioner
          KEYCLOAK_SETUP_CLIENT_ID: den-spa
          KEYCLOAK_SETUP_REDIRECT_URI: https://den.con.example.org/
          ROLE_CATALOG_SOURCES: stash=http://stash-backend:8080/api/role-catalog,events=http://events-backend:8080/api/role-catalog
          DEN_INTERNAL_URL: http://den-backend:8080
          SMTP_HOST: smtp.example.org
          SMTP_USERNAME: hr@con.example.org
          SMTP_FROM: hr@con.example.org
          CORS_ALLOWED_ORIGINS: https://hr.con.example.org

      hr-frontend:
        image: ghcr.io/aglelectronics/hr-frontend:1.0.0-1
        <<: *hardening
        networks: [internal]
        volumes:
          - ./hr-frontend/nginx.conf:/etc/nginx/conf.d/default.conf:ro
          - ./hr-frontend/config.json:/etc/conservices/config.json:ro
    ```

3. Add the host to the `Caddyfile`:

    ```text
    hr.con.example.org {
    	reverse_proxy hr-frontend:8080
    }
    ```

4. Start and check:

    ```sh
    docker compose -f compose.production.yml up -d
    docker compose -f compose.production.yml logs hr-migrate | tail -n 1
    docker compose -f compose.production.yml exec hr-frontend wget -qO- http://hr-backend:8080/readyz
    ```

```json
{"status":"ready","database":"ok"}
```

## Development with Docker

Quick and easy; development passwords; **not for production**.

**Inside the full local stack** (root of `con-services`; HR has no
profile, so it always starts with the stack):

```sh
docker compose up -d --build hr-frontend
```

HR is at <https://hr.conservices.test>, the API at <http://localhost:8110>.
It creates real users in the local Keycloak and sends email to Mailpit.
See [Local development with Docker Compose](../../contributing/local-development.md).

**HR on its own** (from the `hr/` checkout). Its `.env.example` expects the
suite's Keycloak on `localhost:8085`; for a quick start without Keycloak,
set `AUTH_MODE=dev` and remove the `KEYCLOAK_*` lines in `.env` first (the
web app already runs in dev sign-in mode there: Compose mounts
`infra/frontend-config/compose.json` as its `/config.json`):

```sh
cp .env.example .env
docker compose -f infra/docker-compose.yml up --build
curl -s http://localhost:8110/livez
```

```json
{"status":"ok","version":"dev","uptime_sec":3}
```

Open <http://localhost:3003>.

## Troubleshooting

**The backend pod is stuck in `Init:CrashLoopBackOff`.** The migration
failed. `kubectl logs -n conservices-hr deploy/hr-backend -c migrate` shows
why, usually `DATABASE_URL is required` or `ping database: …` (wrong URL or
the NetworkPolicy blocks PostgreSQL). For `no encryption`, see below.

**The backend exits with `tls: TLS_CERT_FILE and TLS_KEY_FILE must be set
together`.** Only one of the two is set, usually because one was added by
hand to `config:` or `backend.extraEnv`. Remove it: the chart sets both
while internal TLS is on, and neither while it is off.

**A pod stays `ContainerCreating`.** It waits for a volume that does not
exist yet: the Secret `hr-backend-tls` or `hr-frontend-tls` (made by
cert-manager) or the ConfigMap `conservices-internal-ca` (made by
trust-manager). `kubectl describe pod` shows `MountVolume.SetUp failed …
not found` under Events. Check:

```sh
kubectl get certificate -n conservices-hr
kubectl describe certificate hr-backend-tls -n conservices-hr
kubectl get configmap conservices-internal-ca -n conservices-hr
```

A certificate that is not `READY True` means cert-manager or the
ClusterIssuer `conservices-internal-ca` is missing; the events of
`kubectl describe certificate` say which. A missing ConfigMap means
trust-manager is not installed, or the namespace lacks the label:
`kubectl label namespace conservices-hr app.kubernetes.io/part-of=conservices`.
Without cert-manager, see [Without cert-manager](#without-cert-manager).

**The web app answers `502 Bad Gateway` and its log shows `upstream SSL
certificate verify error`.** nginx could not check the backend's
certificate. Either the backend serves plain HTTP (its log has no
`tls enabled` line), or its certificate was signed by a CA other than the
one in `conservices-internal-ca` (with your own certificates: put the right
CA in the ConfigMap named by `internalTLS.caConfigMap`). See the error with
`kubectl logs -n conservices-hr deploy/hr-frontend`.

**Calls to Keycloak, Den or other modules fail with `x509: certificate
signed by unknown authority`.** The backend does not trust the internal
CA: `SSL_CERT_DIR` is missing, or a value in `config:` replaced it with
another folder. It must include `/etc/conservices-internal-ca`; separate
several folders with `:`. Check with
`kubectl get configmap hr-config -n conservices-hr -o yaml`.

**The migration fails with `no pg_hba.conf entry for host "…", user "hr",
database "hr", no encryption`.** `DATABASE_URL` still ends in
`sslmode=disable`, and the platform's PostgreSQL accepts only TLS. Change
the end to
`?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt` in
your secret manager, then
`kubectl rollout restart -n conservices-hr deploy/hr-backend`. For a
managed database use `sslmode=verify-full&sslrootcert=<path to the provider's CA>`.

**`invalid config: S3_ENDPOINT is required when any S3_* var is set`.** As
soon as one `S3_*` value is set, all four (`S3_ENDPOINT`, `S3_BUCKET`,
`S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`) are required. HR stores no
files yet: remove them all, or set them all.

**`KEYCLOAK_BASE_URL is required when Keycloak provisioning is enabled`.**
`KEYCLOAK_CLIENT_SECRET` is set without `KEYCLOAK_BASE_URL` (or the other
way round).

**Signed in, but HR says "you don't have access to HR".** The token's
`groups` claim contains none of `HR_ACCESS_GROUPS` (default `hr-admin`).
`GET /api/me` shows the groups HR saw.

**Completing an onboarding fails with a Keycloak error or times out.** HR
cannot reach Keycloak's admin API. Check `KEYCLOAK_BASE_URL` (on the
platform `https://keycloak.conservices-identity.svc.cluster.local:8443`),
the client secret, and the Keycloak ingress rule from step 5.

**"HR's Keycloak service account is not allowed to … (needs manage-users)".**
In Keycloak, open the `hr-provisioner` client → **Service account roles**
and assign the `realm-management` roles `manage-users`, `view-users`,
`query-users`, `view-realm` and `query-groups` (the platform realm import
already does this).

**A module shows "error" in the access step.** HR could not fetch that
module's `/api/role-catalog`. Check the URL in `ROLE_CATALOG_SOURCES` and
both NetworkPolicy rules.

**No password-setup email arrives.** Keycloak sends it, not HR: configure
SMTP in the realm (**Realm settings → Email**). When Keycloak cannot send
it, HR instead sets a temporary password and shows it **once** on the
completed onboarding; hand it over in person. HR's own `SMTP_*` settings
are only for its notices, such as "your account was deleted".
