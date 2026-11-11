# Set up Desk

This page installs Desk and connects its first mailbox. Pick one of five
ways:

| Option | When | Data safe? |
| --- | --- | --- |
| [Production cluster with Argo CD](../../deploy/apps.md) (recommended for production) | Production: the whole suite on a cluster managed from Git | Yes, CloudNativePG backups and Den's operator |
| [1. Kubernetes platform](#option-1-kubernetes-platform-recommended) | A cluster you run yourself, with Den running; also the local trial cluster from the quickstart | Yes, backed up by Den's operator |
| [2. Standalone on Kubernetes](#option-2-standalone-on-kubernetes) | Only Desk | Yes, if **you** back it up |
| [3. Production on Docker](#option-3-production-on-docker) | One server, no Kubernetes | Yes, with care |
| [4. Development on Docker](#option-4-development-on-docker) | Trying it out | **No**: public passwords, test mail servers |

The Argo CD path installs Desk together with Den and the other modules; see [Den and the modules](../../deploy/apps.md). A local Kubernetes cluster (the [quickstart](../../getting-started/den-quickstart.md)) is for trials only.

## What Desk needs

| Needs | Why |
| --- | --- |
| PostgreSQL 16 database and a login that owns it | Conversations, customers, settings, audit log. |
| An S3 bucket (`desk-data`) and keys that can only reach it | Attachments, inline images and the original emails. Required: the backend does not start without it. |
| A random `DESK_SECRET_KEY` of at least 32 characters | Encrypts the IMAP and SMTP passwords stored in the database. Keep it in your secret manager; it can be [rotated](operations.md#rotate-desk_secret_key). |
| Where the mail lives | **Google Workspace** (recommended; Desk creates the mailboxes there, see [Google Workspace](google-workspace.md)), or an IMAP and SMTP account per support address ([IMAP and SMTP](imap.md)). |
| Optionally an SMTP server and a sender address | Module-wide `SMTP_*` for IMAP mailboxes without their own server, and `NOTIFY_FROM` for Desk's own emails (purge reminders, notifications). |
| An OpenID Connect sign-in server (Keycloak) | Public client `desk-spa`, group `desk-admin`, and per mailbox the groups `desk-<slug>-viewer`, `-manager`, `-delete` ([Access](access.md)). |

## Option 1: Kubernetes platform (recommended)

Den must be running first: [How the platform starts](../../getting-started/how-the-platform-starts.md).

1. **Register Desk in Den** (**Admin console → Modules → New module**, short
   name `desk`, tick **Create a database for it**) and copy the database URL
   into your secret manager. It ends in
   `?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt`:
   Desk connects with TLS and checks the database's certificate against
   the platform's internal CA, and the platform's PostgreSQL refuses
   connections without TLS.

2. **Create the bucket and add it to backups.** Create the bucket
   `desk-data` in the platform's S3 and keys that can only reach it. Add
   `desk-data` to the Den operator's `FILES_S3_BUCKETS`, so Den's backups
   include attachments and original emails. The platform's Kustomize base
   (`deploy/kubernetes/base/data/s3.yaml`) already creates `desk-data` for
   the local trial cluster.

3. **Create the namespace.** The `app.kubernetes.io/part-of` label lets
   trust-manager copy the internal CA into it ([Internal TLS](#internal-tls)).

    ```sh
    kubectl create namespace conservices-desk
    kubectl label namespace conservices-desk \
      conservices.io/tier=module conservices.io/module=desk \
      app.kubernetes.io/part-of=conservices \
      pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/warn=restricted
    ```

4. **Store the secrets** in your secret manager and let an `ExternalSecret`
   create `desk-secrets` (see [Secrets](../../operations/secrets.md)):

    ```sh
    vault kv put secret/conservices/desk/backend \
      DATABASE_URL='postgres://desk:change-me@postgres.conservices-data.svc.cluster.local:5432/desk?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt' \
      DESK_SECRET_KEY="$(openssl rand -base64 32)" \
      S3_ACCESS_KEY_ID=change-me S3_SECRET_ACCESS_KEY=change-me \
      SMTP_PASSWORD=change-me
    ```

    `SMTP_PASSWORD` is only needed with a module-wide SMTP server that
    wants a login. For Google Workspace, also store the service account
    key as `desk-google` ([Google Workspace, step 6](google-workspace.md#set-it-up)).

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

5. **Create the access config** from `infra/access-config.toml` in the Desk
   repository (set `organization` to your organization's slug):

    ```sh
    kubectl create configmap desk-access-config -n conservices-desk \
      --from-file=access-config.toml=access-config.toml
    ```

6. **Install the chart.** The default values reach the platform's S3
   (bucket `desk-data`) and allow outbound IMAP and SMTP to any address;
   narrow `networkPolicy.extraEgress` to your mail provider if you can. For
   Google Workspace add the `google` values from
   [Google Workspace, step 7](google-workspace.md#set-it-up).

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
      S3_BUCKET: desk-data
      NOTIFY_FROM: "Desk <desk@example.org>"   # purge reminders, notifications
      SMTP_HOST: smtp.example.org              # for IMAP mailboxes without their own, and NOTIFY_FROM
      SMTP_USERNAME: desk@example.org
    route:
      host: desk.example.org
    ```

    ```sh
    helm install desk deploy/charts/desk -n conservices-desk -f my-desk.yaml
    kubectl get pods -n conservices-desk -w
    ```

    Internal TLS is on by default (`internalTLS.enabled: true`) and the
    chart's `DEN_INTERNAL_URL` is
    `https://den-backend.conservices-den.svc.cluster.local:8080`. The
    cluster needs cert-manager, trust-manager and the platform's internal
    CA; see [Internal TLS](#internal-tls).

7. **Pair with Den:** Den: **Modules → Pair** on the Desk row; Desk (as
   `desk-admin`): **Settings → Den connection**, paste, **Connect**.

8. **Add the first mailbox.** In Desk as `desk-admin`: **Mailboxes → New
   mailbox**. Enter the name and address (for example `Support`,
   `support@example.org`), pick the connector and a signature
   (`{agent.name}` is replaced by the person replying), then **Create
   mailbox**. The details per connector are on
   [Google Workspace](google-workspace.md#set-it-up) (step 9) and
   [IMAP and SMTP](imap.md#add-an-imap-mailbox).

9. **Give people access.** In HR (or Keycloak) add the support staff to
   `desk-support-manager` (answer) and, where needed,
   `desk-support-delete` (delete); see [Access](access.md).

10. **Verify:** send an email to the address. Within `FETCH_INTERVAL`
   (or right away with **Fetch now** on the mailbox card) it appears in the
   **Inbox** under **Unassigned**. Reply; within about 10 seconds (the undo
   window) the reply leaves.

    ```sh
    kubectl get certificate -n conservices-desk
    kubectl exec -n conservices-desk deploy/desk-frontend -- curl -s --cacert /etc/conservices-internal-ca/ca.crt https://desk-backend:8080/api/health
    ```

    ```text
    NAME                READY   SECRET              AGE
    desk-backend-tls    True    desk-backend-tls    60s
    desk-frontend-tls   True    desk-frontend-tls   60s
    ```

    ```json
    {"status":"ok","database":"ok","version":"1.0.0-1","uptime_sec":57}
    ```

    The backend answers over HTTPS. `--cacert` makes `curl` check its

    certificate against the internal CA mounted in the web app pod; nginx

    does the same check on every `/api/` request.

## Option 2: Standalone on Kubernetes

Follow [Run one module on Kubernetes](../../getting-started/standalone-kubernetes.md)
with these Desk values. Desk needs a bucket with keys for it, for example
at Hetzner Object Storage.

```yaml
den: { mode: standalone }   # no Den: do not wait for pairing
config:
  APP_BASE_URL: https://desk.example.org
  OIDC_ISSUER_URL: https://login.example.org/realms/conservices
  CORS_ALLOWED_ORIGINS: https://desk.example.org
  DEN_INTERNAL_URL: ""
  S3_ENDPOINT: https://fsn1.your-objectstorage.com
  S3_BUCKET: example-desk
  S3_REGION: fsn1
networkPolicy:
  den:  { enabled: false }
  data:
    enabled: false
    s3:
      external:
        fqdns: ["fsn1.your-objectstorage.com", "*.fsn1.your-objectstorage.com"]
  allowFromNamespaces: []
  extraEgress:
    - to: [{ ipBlock: { cidr: 10.20.0.0/24 } }]     # your database subnet
      ports: [{ protocol: TCP, port: 5432 }]
    - to: [{ ipBlock: { cidr: 0.0.0.0/0 } }]        # mail servers
      ports:
        - { protocol: TCP, port: 993 }
        - { protocol: TCP, port: 587 }
```

The secret `desk-secrets` holds `DATABASE_URL`, `DESK_SECRET_KEY`,
`S3_ACCESS_KEY_ID` and `S3_SECRET_ACCESS_KEY`. Desk does not create the
bucket outside development: create it first. **Back up the database and
the bucket yourself**; together they hold every email. Without Den,
retention is set under **Settings → Retention** ([Operations](operations.md#retention)).

Internal TLS stays on by default and needs cert-manager, trust-manager and
an issuer in your cluster. Without them, turn it off or bring your own
certificates ([Without cert-manager](#without-cert-manager)). For a managed
database, end `DATABASE_URL` in
`?sslmode=verify-full&sslrootcert=<path to the provider's CA>` and mount
that CA file with `backend.extraVolumes` and `backend.extraVolumeMounts`.

## Internal TLS

On Kubernetes, Desk encrypts the traffic **inside** the cluster as well,
not only between browsers and the Gateway. It is on by default
in the Helm chart. The shared how-to, including the platform setup and
certificate rotation, is [Internal TLS](../../operations/internal-tls.md).
Mail traffic (IMAP, SMTP) is not affected: it uses the mailbox's own
security setting.

What happens:

- **cert-manager** (a Kubernetes add-on that issues and renews
  certificates) issues `desk-backend-tls` and `desk-frontend-tls` from the
  ClusterIssuer `conservices-internal-ca`. They last 90 days and are
  renewed 30 days before they expire. Pods mount them at
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
kubectl get certificate -n conservices-desk
kubectl get configmap conservices-internal-ca -n conservices-desk
kubectl logs -n conservices-desk deploy/desk-backend | grep "tls enabled"
```

Both certificates should be `READY True`, the ConfigMap should exist, and
the backend's `tls enabled` log line carries the certificate's expiry date
in `not_after`.

### Chart values

| Value | Default | What it does |
| --- | --- | --- |
| `internalTLS.enabled` | `true` | Turns internal TLS on or off for the backend, the web app and the Ingress. |
| `internalTLS.createCertificates` | `true` | `true`: the chart asks cert-manager for the two certificates. `false`: you create the Secrets `desk-backend-tls` and `desk-frontend-tls` yourself (keys `tls.crt`, `tls.key`, `ca.crt`). |
| `internalTLS.issuerRef` | ClusterIssuer `conservices-internal-ca` | The cert-manager issuer that signs them. |
| `internalTLS.duration` | `2160h` (90 days) | Certificate lifetime. |
| `internalTLS.renewBefore` | `720h` (30 days) | How long before expiry cert-manager renews. |
| `internalTLS.caConfigMap` | `conservices-internal-ca` | ConfigMap (key `ca.crt`) with the CA the pods trust. |
| `internalTLS.ingressNginxAnnotations` | `false` | Legacy, only with `ingress.enabled: true`: adds the ingress-nginx annotations for HTTPS to the web app (`backend-protocol: HTTPS`, `proxy-ssl-verify`). The Gateway API route uses a `BackendTLSPolicy` instead. ingress-nginx is no longer maintained; do not use it. |
| `route.enabled`, `route.host`, `route.parentRefs`, `route.timeout` | `true`, `desk.conservices.test`, Gateway `public` in `conservices-gateway` (listener `https`), `60s` | Exposes the web app through the Gateway API: an `HTTPRoute` and, with internal TLS, a `BackendTLSPolicy` that makes the gateway check `desk-frontend`'s certificate. See [Exposing the web app](../../operations/helm.md#exposing-the-web-app-gateway-api). |
| `frontend.config` | `{}` | The web app's `/config.json` (sign-in address, client id; see [Web app settings](configuration.md#web-app-settings-configjson)), written to the ConfigMap `<release>-frontend-config`. Keys left out come from `config.AUTH_MODE`, `config.OIDC_ISSUER_URL` and `config.OIDC_CLIENT_ID` (else `desk-spa`). |
| `ingress.enabled` | `false` | Plain `Ingress` for another controller instead of the route. |
| `ha.podDisruptionBudget`, `ha.topologySpread`, `priorityClassName` | `true`, `true`, `""` | PodDisruptionBudget and spreading over nodes for the web app (two replicas); see [High availability](../../operations/helm.md#high-availability). |
| `networkPolicy.gateway.cilium` | `true` | Adds a `CiliumNetworkPolicy` that admits Cilium's gateway to the web app; see [Network policy values](../../operations/helm.md#network-policy-values). |
| `imagePullSecrets` | `[]` | Pull Secrets for private images on every pod, for example `[{name: ghcr-pull}]`; see [Private images](../../operations/helm.md#private-images). |
| `google.enabled`, `google.existingSecret`, `google.secretKey`, `google.mountPath` | `false`, `desk-google`, `service-account.json`, `/etc/desk-google` | Mounts the Google service account key and sets `GOOGLE_SERVICE_ACCOUNT_FILE`; see [Google Workspace](google-workspace.md). |
| `networkPolicy.google.enabled` / `.fqdns` / `.cidrs` / `.port` | `false` / Gmail, Admin SDK, OAuth2 and `www.googleapis.com` / `[]` / `443` | Egress from the backend to Google's APIs: a `CiliumNetworkPolicy` `desk-backend-google` by host name with Cilium, `ipBlock` rules from `cidrs` otherwise. |
| `networkPolicy.data.s3.enabled` | `true` | Egress to the platform's S3 (Garage) for the bucket in `config.S3_BUCKET`. |
| `networkPolicy.extraEgress` | IMAP and SMTP ports to `0.0.0.0/0` | Mail servers of IMAP mailboxes and `SMTP_HOST`. Narrow it, or `[]` with only Google mailboxes. |
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
kubectl create secret generic desk-backend-tls -n conservices-desk \
  --from-file=tls.crt=backend.crt --from-file=tls.key=backend.key --from-file=ca.crt=ca.crt
kubectl create secret generic desk-frontend-tls -n conservices-desk \
  --from-file=tls.crt=frontend.crt --from-file=tls.key=frontend.key --from-file=ca.crt=ca.crt
kubectl create configmap my-internal-ca -n conservices-desk --from-file=ca.crt=ca.crt
```

```yaml
internalTLS:
  createCertificates: false
  caConfigMap: my-internal-ca
```

The backend certificate must be valid for `desk-backend` and
`desk-backend.conservices-desk.svc.cluster.local`, the web app's for
`desk-frontend.conservices-desk.svc.cluster.local`. Replace them before
they expire; the backend picks up new files within a minute, nginx within
six hours.

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
    networks: [internal, egress]               # egress: database, S3, mail servers, Google
    # DATABASE_URL, DESK_SECRET_KEY, S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY, SMTP_PASSWORD
    env_file: /etc/conservices/desk-backend.env
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
      NOTIFY_FROM: "Desk <desk@example.org>"
      S3_ENDPOINT: https://fsn1.your-objectstorage.com
      S3_BUCKET: example-desk
      S3_REGION: fsn1
      DEN_INTERNAL_URL: http://den-backend:8080
      # Google Workspace (optional; see the Google Workspace page):
      # GOOGLE_WORKSPACE_DOMAIN: example.org
      # GOOGLE_ADMIN_USER: desk-admin@example.org
      # GOOGLE_SHARED_MAILBOX: desk@example.org
      # GOOGLE_SERVICE_ACCOUNT_FILE: /etc/desk-google/service-account.json
    volumes:
      - ./desk/access-config.toml:/etc/desk/access-config.toml:ro
      # - /etc/conservices/desk-google.json:/etc/desk-google/service-account.json:ro

  desk-frontend:
    image: ghcr.io/aglelectronics/desk-frontend:1.0.0-1
    restart: unless-stopped
    networks: [internal]
    volumes:
      # infra/nginx.stack.conf from the Desk repository: forwards /api/ to desk-backend:8080.
      - ./desk/nginx.stack.conf:/etc/nginx/conf.d/default.conf:ro
      # The web app's sign-in settings, served as /config.json.
      - ./desk/config.json:/etc/conservices/config.json:ro
```

`./desk/config.json` holds the web app's sign-in settings; the published
image names no domain. Keys: [Web app settings](configuration.md#web-app-settings-configjson).

```json
{
  "authMode": "oidc",
  "oidcAuthority": "https://auth.con.example.org/realms/conservices",
  "oidcClientId": "desk-spa"
}
```

One `desk-backend` container only. Proxy block:
`desk.con.example.org { reverse_proxy desk-frontend:8080 }`. Create the
bucket before the first start, and back it up with the database.

## Option 4: Development on Docker

Never for real data. From the root of the `con-services` repository:

```powershell
docker compose --profile desk up --build -d
```

This also starts **GreenMail**, a test mail server: the mailboxes
`support@conservices.test` (password `support`) and
`registration@conservices.test` (password `registration`) at IMAP
`greenmail:3143`. Replies go out through **Mailpit** (`mailpit:1025`),
where you can read them in a browser. Attachments go to the dev S3 bucket
`desk-data-dev`. Open <https://desk.conservices.test>
(or <http://localhost:3008>). For a mailbox, use IMAP host `greenmail`,
port `3143`, security **None (dev only)**; the stack allows the private
addresses of `greenmail` and `mailpit` with `DESK_ALLOWED_MAIL_HOSTS`.

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
| S3, SeaweedFS (standalone stack only; dev key `desk` / `deskdev`) | 9040 |
| GreenMail SMTP / IMAP (standalone stack: `support@desk.test`) | 3025 / 3143 |

**Try the Google flow without Google:** set `GOOGLE_WORKSPACE_DOMAIN=desk.test`,
`GOOGLE_SHARED_MAILBOX=desk@desk.test` and `GOOGLE_FAKE=true` in the
backend's environment. Desk then uses an in-memory Google Workspace: you can
create `google_user` and `google_group` mailboxes, delete, restore and purge
them. No real mail arrives. `GOOGLE_FAKE` is refused outside
`APP_ENV=development`.

**Smoke test:** with the platform stack running (`--profile desk`), run
from the root of the repository:

```powershell
pwsh scripts/smoke-desk.ps1
```

It signs in as `admin` and `bob`, creates a throwaway IMAP mailbox for
`registration@conservices.test` on GreenMail, sends a customer mail into it,
waits for the conversation, undoes one reply and sends another (visible in
Mailpit), adds a note, checks that `bob` gets `404`, and tries the
conversation trash. Afterwards it moves the mailbox to the trash and purges
it. A good run ends with:

```text
SMOKE OK (8 steps)
```

If it stops at step 2 with `409`, a Desk mailbox for
`registration@conservices.test` already exists; delete and purge it, or
pass another GreenMail user with `-MailboxEmail` and `-MailboxPassword`.
If step 3 fails with *this server is on a private or internal network
address*, the backend runs without `DESK_ALLOWED_MAIL_HOSTS`: recreate it
with `docker compose --profile desk up -d desk-backend`.

## Why the backend runs one replica

The mail fetcher, the reply sender and the daily jobs run inside the
backend process. Two replicas would fetch the same mailboxes twice. The
Helm chart refuses any `backend.replicas` other than 1.

## Troubleshooting

**The backend does not start: "invalid config: …".** The message lists
every setting that is wrong; the fixes are in
[Configuration, Troubleshooting](configuration.md#troubleshooting). The
usual ones after an upgrade are the `S3_*` settings and a `DESK_SECRET_KEY`
shorter than 32 characters.

**The backend does not start: `bucket "desk-data" does not exist; create it
first`.** Create the bucket (step 2). Outside development Desk never
creates it.

**Mailbox passwords stopped working after a redeploy ("the stored password
cannot be decrypted").** `DESK_SECRET_KEY` changed without the old key in
`DESK_SECRET_KEY_PREVIOUS`. Put the old key there, restart and run
`/server reencrypt` ([Rotate DESK_SECRET_KEY](operations.md#rotate-desk_secret_key)).

**The mailbox shows a fetch error / connection test fails.** See
[IMAP and SMTP, Troubleshooting](imap.md#troubleshooting) or
[Google Workspace, Troubleshooting](google-workspace.md#troubleshooting).

**Staff sign in but see no mailboxes.** They need a mailbox's role; see
[Access](access.md).

**Replies stay "queued" or show "Not sent".** No SMTP server: the mailbox
has none and `SMTP_HOST` is empty, or the server refused. The thread shows
the error; Desk retries after 1, 5, 15 and 60 minutes, then offers a retry
button.

**`helm install` fails with "backend.replicas must be 1".** Intended; see
above.

**The backend exits with `tls: TLS_CERT_FILE and TLS_KEY_FILE must be set
together`.** Only one of the two is set, usually because one was added by
hand to `config:` or `backend.extraEnv`. Remove it: the chart sets both
while internal TLS is on, and neither while it is off.

**A pod stays `ContainerCreating`.** It waits for a volume that does not
exist yet: the Secret `desk-backend-tls` or `desk-frontend-tls` (made by
cert-manager) or the ConfigMap `conservices-internal-ca` (made by
trust-manager). `kubectl describe pod` shows `MountVolume.SetUp failed …
not found` under Events. Check:

```sh
kubectl get certificate -n conservices-desk
kubectl describe certificate desk-backend-tls -n conservices-desk
kubectl get configmap conservices-internal-ca -n conservices-desk
```

A certificate that is not `READY True` means cert-manager or the
ClusterIssuer `conservices-internal-ca` is missing; the events of
`kubectl describe certificate` say which. A missing ConfigMap means
trust-manager is not installed, or the namespace lacks the label:
`kubectl label namespace conservices-desk app.kubernetes.io/part-of=conservices`.
Without cert-manager, see [Without cert-manager](#without-cert-manager).

**The web app answers `502 Bad Gateway` and its log shows `upstream SSL
certificate verify error`.** nginx could not check the backend's
certificate. Either the backend serves plain HTTP (its log has no
`tls enabled` line), or its certificate was signed by a CA other than the
one in `conservices-internal-ca` (with your own certificates: put the right
CA in the ConfigMap named by `internalTLS.caConfigMap`). See the error with
`kubectl logs -n conservices-desk deploy/desk-frontend`.

**Pairing or the database fails with `x509: certificate signed by unknown
authority`.** The backend does not trust the internal CA: `SSL_CERT_DIR` is
missing, or a value in `config:` replaced it with another folder. It must
include `/etc/conservices-internal-ca`; separate several folders with `:`.
Check with `kubectl get configmap desk-config -n conservices-desk -o yaml`.

**The backend pod stays in `Init:CrashLoopBackOff` and the migrate log shows
`no pg_hba.conf entry for host "…", user "desk", database "desk", no
encryption`.** `DATABASE_URL` still ends in `sslmode=disable`, and the
platform's PostgreSQL accepts only TLS. Change the end to
`?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt` in
your secret manager, then
`kubectl rollout restart -n conservices-desk deploy/desk-backend`. For a
managed database use `sslmode=verify-full&sslrootcert=<path to the provider's CA>`.
