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
   into your secret manager. It ends in
   `?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt`:
   Desk connects with TLS and checks the database's certificate against
   the platform's internal CA, and the platform's PostgreSQL refuses
   connections without TLS.

2. **Create the namespace.** The `app.kubernetes.io/part-of` label lets
   trust-manager copy the internal CA into it ([Internal TLS](#internal-tls)).

    ```sh
    kubectl create namespace conservices-desk
    kubectl label namespace conservices-desk \
      conservices.io/tier=module conservices.io/module=desk \
      app.kubernetes.io/part-of=conservices \
      pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/warn=restricted
    ```

3. **Store the secrets** in your secret manager and let an `ExternalSecret`
   create `desk-secrets` (see [Secrets](../../operations/secrets.md)):

    ```sh
    vault kv put secret/conservices/desk/backend \
      DATABASE_URL='postgres://desk:change-me@postgres.conservices-data.svc.cluster.local:5432/desk?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt' \
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
with these Desk values. Desk needs no bucket.

```yaml
den: { mode: standalone }   # no Den: do not wait for pairing
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
`desk.con.example.org { reverse_proxy desk-frontend:8080 }`.

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
