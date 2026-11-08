# Changelog

All notable changes to the Con Services suite (the Kubernetes manifests and
Helm charts, the shared Docker stack, Keycloak realm, proxy, scripts and
documentation) are documented in this file. Each module keeps its own
changelog in its repository.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Documentation site: a *Changelog* page in the top navigation shows this
  changelog and links to the changelogs of every module and of the Argo CD
  template. The site now rebuilds when `CHANGELOG.md` changes.

### Changed

- Deployment docs: *Secrets with OpenBao* describes the new flow of the
  GitOps template. The OpenBao administrator grants a narrow role once.
  Argo CD then waits at `openbao-setup` until you review and sync it.
  External Secrets creates the random secrets, and you enter only your
  provider credentials. A new table lists every OpenBao entry with its keys,
  the kind of value and who creates it. *Argo CD*, *Prerequisites*,
  *Data*, *Identity*, *DNS and certificates*, *Secrets* and *Network
  policies* follow the same flow (new flow: the setup Job to OpenBao).
- Deployment docs: the prerequisites now allow tainted control-plane nodes
  as long as at least 3 nodes accept workloads, and list what we expect of
  how the cluster is run (HA control plane, etcd backups, encryption at
  rest, OS updates, monitoring).
- Deployment docs: the GitOps template (`con-services-gitops`) now installs
  only Con Services itself (Den, the modules, PostgreSQL, Keycloak, and the
  issuers, gateways and secret references they need). Argo CD,
  cert-manager with trust-manager, External Secrets Operator with OpenBao,
  the CloudNativePG operator with the Barman Cloud plugin, load balancer
  IPs and the CoreDNS rewrite for Keycloak are
  documented as cluster prerequisites, with tested versions and checks but
  no setup walkthrough. *Prerequisites* lists them;
  *Secrets with OpenBao* now covers preparing an existing OpenBao
  (`openbao-configure.sh`) instead of installing, unsealing and backing it
  up; *Sizing* counts these services separately. Upgrading an existing
  installation: follow the **BREAKING** entries in the template's
  `CHANGELOG.md`.
- Internal TLS docs: cert-manager and trust-manager are described as
  cluster prerequisites with a check, instead of install steps (the local
  trial in *Run Den on Kubernetes* still installs them).
- Contributing docs: *CI and releases* now describes what the project's
  self-hosted runners provide (runner image, BuildKit and test database
  sidecars) and how to fix missing arm64 emulation on their nodes.

### Removed

- Deployment docs: the pages *Example: a k3s cluster*, *Self-hosted CI
  runners* and *Kubernetes distributions*. Building a cluster and running
  CI runners are not part of a Con Services installation; the template no
  longer contains them either (see its `CHANGELOG.md`). *Prerequisites*
  links to the upstream installation guides, and *DNS and certificates*
  shows the CoreDNS rewrite for Keycloak inline.
- Deployment and operations docs: the remaining install commands for
  cluster services (Argo CD, the Gateway API CRDs, Cilium, Cilium
  WireGuard) and the Argo CD login steps. The docs now say only what
  Con Services needs from each service: *Prerequisites* has a new
  *Argo CD* section with the required Application health check, step 3
  of *Argo CD and cluster.yaml* checks for it instead of installing Argo
  CD, and *Network policies* lists what Con Services needs from Cilium.

### Fixed

- The deploy validation workflow no longer fails silently on Kustomize
  directories that read no `local/` files (for example `base`).

## [1.1.0] - 2026-11-07

### Added

- Helm charts (every module, version 0.3.0): `den.mode` (`required` by
  default, or `standalone`), rendered as `DEN_MODE` into the backend's
  ConfigMap. With `required`, a module waits for Den until it is paired:
  its API answers `503 den_pairing_required` and its web app shows
  *Waiting for Den*. `helm template` stops on any other value and when
  `config.DEN_MODE` is set as well. See
  [Required or standalone](docs/concepts/pairing.md#required-or-standalone).
- Den's Helm chart (version 0.2.0): `preregisterModules` (default `[]`),
  rendered as JSON into `DEN_PREREGISTER_MODULES` when not empty. Den lists
  these modules as unpaired on its Modules page from the first start, so an
  admin only clicks **Pair**. See
  [Modules registered at start-up](docs/modules/den/configuration.md#modules-registered-at-start-up).
- Docker Compose: every module backend gets `DEN_MODE`, default
  `standalone`; set `DEN_MODE=required` in `.env` to try the Kubernetes
  behaviour. Documented in `.env.example`.
- CI: the deploy validation workflow runs `scripts/check-den-mode.py` and
  fails when a module backend rendered from a chart with default values, or
  from a Kustomize tree (including the production overlay), does not get
  `DEN_MODE=required`.
- Documentation: the `GET /api/den/state` endpoint and the
  `503 den_pairing_required` error with `curl` examples, a *Waiting for Den*
  state in the pairing state diagram, `DEN_MODE` on every module's
  configuration page, `DEN_PREREGISTER_MODULES` on Den's, the `Den mode`
  values on [Helm](docs/operations/helm.md#den-mode), and the
  select → sync → pair → unlock steps with troubleshooting on
  [Den and the modules](docs/deploy/apps.md).

### Changed

- **BREAKING:** Every Kubernetes setup now makes modules wait for Den: the Helm charts
  default to `den.mode: required`, and the Kustomize Stash base
  (`deploy/kubernetes/modules/stash`) sets `DEN_MODE=required`. After the
  upgrade, a module that was never paired shows *Waiting for Den* until
  you pair it (Den → Modules → Pair). Modules already paired keep working.
  A module you run **without Den** must now set `den.mode: standalone`
  (Helm) or `DEN_MODE=standalone` in its ConfigMap (Kustomize); see
  [Run one module on Kubernetes](docs/getting-started/standalone-kubernetes.md).
  The code default and Docker Compose stay `standalone`.
- The GitOps template pins the charts to `v1.1.0` (`charts.targetRevision`),
  makes every module opt-in, always deploys modules with
  `den.mode: required` and fills Den's `preregisterModules` from the enabled
  modules; see its CHANGELOG.
- Documentation: the standalone Helm examples on every module's setup page
  set `den.mode: standalone`, and the Argo CD, Kustomize remote base and
  Helm GitOps examples pin `v1.1.0`.

### Security

- The trial PostgreSQL and S3 (SeaweedFS) containers in
  `deploy/kubernetes/base/data/` run with a read-only root file system and
  a writable `/tmp`. The trial Keycloak (`start-dev`) cannot, because it
  rebuilds into its own image at startup; it has a dated waiver in
  `.trivyignore.yaml`. Production runs Keycloak through the Keycloak
  Operator.
- The CI runner image (`ghcr.io/aglelectronics/ci-runner:2.338.2-1`) no
  longer contains the unused npm of the runner's Node 20, which carried
  node-tar 6.2.1 (CVE-2026-59873, critical).

## [1.0.0] - 2026-11-07

### Added

- `scripts/workspace.ps1` and `scripts/workspace.sh`: clone, update
  (`pull`) and check (`status`) the root repository and all module and
  GitOps repositories in one go. The workspace layout is documented on
  [Local development](docs/contributing/local-development.md#the-workspace).
- Draft proposal [Staff communications](docs/proposals/staff-communications.md):
  split notices, chat and meetings; build Herald for official notices and
  thin meeting cards; keep Telegram/Discord (and similar) external with
  optional bridges and one-click join links. Self-hosted chat and A/V are
  explicit non-goals. Linked from the docs site under Proposals.
- Documentation site at <https://aglelectronics.github.io/con-services/>,
  built with MkDocs Material and published by GitHub Actions: getting
  started, concepts, Den's admin guide, configuration and API reference,
  operations and contributing.
- Kubernetes manifests in `deploy/kubernetes/` (Kustomize): Keycloak in
  `conservices-identity`, PostgreSQL and an S3 server in `conservices-data` (for
  local trials), Den in `conservices-den`, and Stash in `conservices-stash`
  as the first module. Images are pinned `MAJOR.MINOR.PATCH-BUILD` tags,
  never `latest`.
- Default-deny NetworkPolicies in every namespace with an explicit allow
  list, `restricted` Pod Security on every namespace, resource requests and
  limits on every container, and no service account tokens mounted.
- Overlays: `example` and `example-stash` for a local cluster with
  public, development-only Secrets, and `production-external-secrets`
  showing secrets from a secret manager through the External Secrets
  Operator.
- A first Helm chart for Stash (`deploy/charts/stash`, version `0.1.0`) for
  running one module on its own.
- First Helm charts for Wiki, Desk, Learn, Tasks and Finance
  (`deploy/charts/<module>`, version `0.1.0`, not yet tested on a cluster):
  migrations as an initContainer, an existing Secret from your secret
  manager, default-deny NetworkPolicies that admit HR's backend. Wiki, Desk
  and Tasks refuse more than one backend replica; Wiki gets a volume for its
  live-editing buffer and websocket-ready proxy settings.
- Documentation sections for Wiki, Desk, Learn, Tasks and Finance: overview,
  setup in the four ways to run them, configuration and API reference, and
  admin guides for Wiki and Tasks.
- Operations guides for installing modules with Helm (install, upgrade,
  rollback, Argo CD), disaster recovery (one module, the database server,
  the whole cluster, lost backups or key, leaked secrets) and logs, health
  and monitoring (health endpoints, JSON logs, what to scrape, example
  alerts). Existing operations, getting-started and contributing pages
  gained step-by-step procedures (own overlay, adding a module, Cilium
  install, secret rotation with External Secrets and Vault, go-live) and a
  Troubleshooting section each.
- Documentation for the four ways to run Con Services: the full platform
  on Kubernetes (Den first), a standalone module on Kubernetes, the full
  stack on one Docker host in production, and Docker Compose for
  development. New pages on the platform bring-up order, network policies,
  secrets, versions and upgrades, and production (load balancer, Cilium,
  managed S3 such as AWS S3 or Hetzner Object Storage).
- Docker Compose stack for the whole suite: shared PostgreSQL (one database
  per module), MinIO (one bucket per module), Keycloak with the
  `conservices` realm, Mailpit and Adminer, all for development only.
- Den, Rally (Events), Learn, Desk, Tasks and Wiki as compose profiles.
- Local HTTPS at `*.conservices.test` through a Caddy proxy with its own
  certificate authority, and `scripts/setup-local-dns.ps1` to add the hosts
  entries and trust it.
- `conservices` Keycloak login theme that draws the brand Den pushes into
  the realm, in light and dark mode; the same look on the Keycloak admin
  console's sign-in page.
- Den pairing in the stack: `DEN_INTERNAL_URL` for every module and
  `scripts/smoke-den-pairing.ps1`.
- Den's operator in the stack, with a development backup key and the
  `conservices-backups` bucket.
- Keycloak user profile attributes and SMTP for HR, role groups for Events
  and Stash, and smoke scripts for the modules.
- Tasks board tooling, backlog seed and department backfill scripts.
- `deploy/kubernetes/base/pki`: the internal certificate authority
  (`ClusterIssuer/conservices-internal-ca`) and a trust-manager `Bundle`
  that puts its certificate in every Con Services namespace. Certificates
  for PostgreSQL, MinIO, Keycloak, Den and Stash, renewed automatically;
  PostgreSQL and nginx reload them without a restart.
- `internalTLS` settings in every module's Helm chart.
- Documentation: [Internal TLS](docs/operations/internal-tls.md) (setup,
  renewal, CA rotation, managed databases, Traefik, troubleshooting),
  Cilium WireGuard encryption in Production, and the TLS Secrets in the
  secrets inventory.
- Helm chart for Den (`deploy/charts/den`, version `0.1.0`): backend,
  web app and operator, with the same routing, TLS, network policy and
  high-availability settings as the module charts.
- Gateway API support in every chart: `route.*` creates an `HTTPRoute`
  plus a `BackendTLSPolicy`, so a Gateway (Cilium's in the reference
  setup) checks the web app's internal certificate. Default request
  timeout 120 s, matching the web app's nginx.
- High-availability settings in every chart (`ha.*`, `priorityClassName`):
  web apps run 2 replicas with a PodDisruptionBudget and are spread over
  nodes; backends that must stay single stay single.
- Cilium-aware network policies in every chart
  (`networkPolicy.gateway.cilium`, `networkPolicy.oidc.inCluster`,
  `networkPolicy.data.*`) for traffic from the Gateway, to Keycloak and to
  the database.
- `imagePullSecrets` in every chart, for private images on GHCR.
- Egress to an external S3 service in every chart
  (`networkPolicy.data.s3.external.fqdns` for Cilium, `.cidrs` for plain
  NetworkPolicy), for managed object storage such as Hetzner Object
  Storage.
- Documentation section [Deploy with Argo CD](docs/deploy/index.md): the
  production reference setup on k3s with Cilium, Longhorn, Argo CD,
  OpenBao, CloudNativePG, Keycloak and managed S3, from empty machines to
  running modules, plus a [High availability](docs/deploy/high-availability.md)
  page that lists what survives which failure.
- `deploy/kubernetes/local-cluster/`: a kind cluster configuration and
  Cilium Helm values (Gateway API, kube-proxy replacement) for the local
  trial.
- Kustomize: Service `keycloak-public` (port 443 to Keycloak's 8443) that
  backends use to reach the OIDC issuer inside the cluster, and the pod
  label `app: keycloak` that the Helm charts' default OIDC network policy
  selects.
- Helm charts: `frontend.config` (and Rally's `submit.config`) becomes the
  web app's `/config.json`, rendered to the ConfigMap
  `<release>-frontend-config` (`<release>-submit-config`) and mounted read-only
  at `/etc/conservices`. Keys left out are filled in from the chart's
  `config` (`AUTH_MODE`, `OIDC_ISSUER_URL`, `OIDC_CLIENT_ID`; Rally's
  submission site from the `ATTENDEE_OIDC_*` settings and
  `PUBLIC_API_BUILTIN_KEY`; Stash's claim page from
  `PUBLIC_LOSTFOUND_CLAIM_ENABLED`), so existing values keep working. A
  checksum annotation restarts the web app pods when it changes. Chart
  versions: Den 0.1.2, the others 0.2.2.
- Kustomize: the ConfigMaps `den-frontend-config` and
  `stash-frontend-config` (from `frontend-config.json`) are mounted into the
  web apps as `/config.json`. The production overlay replaces Den's with
  `den-frontend-config.json` instead of pointing at a custom image.
- Every nginx configuration (images, chart ConfigMaps, Kustomize) serves
  `location = /config.json` from `/etc/conservices/config.json` with
  `Cache-Control: no-store`.
- Docker Compose: each web app in the root `docker-compose.yml` mounts
  `infra/frontend-config/<app>.json` (`*.conservices.test` dev values)
  instead of receiving OIDC build arguments.

### Changed

- **BREAKING:** The Kustomize manifests (`deploy/kubernetes/`) now publish
  Den, Keycloak and Stash with the Gateway API instead of ingress-nginx
  `Ingress` objects: an `HTTPRoute` and a `BackendTLSPolicy` per web app,
  attached to the listener `https` of a Gateway `public` in the namespace
  `conservices-gateway`, plus a `CiliumNetworkPolicy` that admits Cilium's
  Envoy. ingress-nginx is no longer maintained. What to do on upgrade:
    1. Install the Gateway API CRDs v1.6.3 (standard channel) and Cilium
       with `gatewayAPI.enabled: true` and `kubeProxyReplacement: true`
       (see [Network policies](docs/operations/network-policies.md#what-con-services-needs-from-cilium)).
    2. Provide the Gateway `public` in `conservices-gateway`. The
       `example` overlay brings one (`overlays/example/gateway.yaml`); in
       your own overlay create it or patch the routes' `parentRefs`.
    3. Move the public TLS Secret (`conservices-tls`) to
       `conservices-gateway`; the module namespaces no longer need it.
    4. Make `auth.<domain>` resolve to `keycloak-public` inside the
       cluster: a CoreDNS rewrite in production, or the `hostAliases`
       to `10.96.0.100` that the example overlays add.
    5. Patch the host names on the HTTPRoutes instead of the Ingresses
       (see `overlays/production-external-secrets`).
    6. After the routes are `Accepted`, delete the old Ingresses
       (`kubectl delete ingress -n conservices-den den`, and likewise in
       `conservices-identity` and `conservices-stash`) and uninstall
       ingress-nginx.
- The local trial ([Run Den on Kubernetes](docs/getting-started/den-quickstart.md))
  now runs on kind with Cilium and its Gateway instead of Docker Desktop's
  Kubernetes and ingress-nginx.
- Documentation: five ways to run Con Services, led by the production
  cluster with Argo CD; the local Kubernetes cluster is described as a
  trial only. Every module's overview and setup page links the Argo CD
  path. Operations pages (Running on Kubernetes, Production, Internal TLS,
  Network policies, Logs and monitoring) describe the Gateway instead of
  an ingress controller; Traefik remains the documented `Ingress`
  alternative. Glossary entries for Argo CD, BackendTLSPolicy, Gateway
  API, GitOps, HTTPRoute and kind.
- Documentation: production object storage is always a managed S3 service
  (any S3-compatible service works: AWS S3, Hetzner Object Storage,
  Cloudflare R2, Backblaze B2, ...); object storage inside the cluster is
  for local trials only.

- **BREAKING:** The Helm charts no longer create an Ingress by default
  (`ingress.enabled: false`) and no longer add ingress-nginx annotations
  (`internalTLS.ingressNginxAnnotations: false`); ingress-nginx is no
  longer maintained. Instead they create a Gateway API `HTTPRoute`
  (`route.enabled: true`), which needs the Gateway API CRDs and a
  Gateway in the cluster. What to do on upgrade: either switch to the Gateway
  API (`route.enabled: true`, `route.host`, `route.parentRefs`; see
  [Helm](docs/operations/helm.md)), or keep your Ingress by setting
  `ingress.enabled: true` and, for ingress-nginx,
  `internalTLS.ingressNginxAnnotations: true`.

- **BREAKING:** Internal TLS. The Kubernetes manifests and every module's
  Helm chart now encrypt every connection inside the cluster with
  certificates from a private certificate authority. What to do on
  upgrade:
    1. Install cert-manager and trust-manager before applying the platform
       or a chart (steps on the new
       [Internal TLS](docs/operations/internal-tls.md) page).
    2. Change every database URL in your secret manager from
       `sslmode=disable` to
       `sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt`;
       the in-cluster PostgreSQL now refuses unencrypted connections.
       In HR's Secret, also change the addresses in `OFFBOARD_HOOKS` and
       `DEPARTMENT_HOOKS` from `http://` to `https://`.
    3. Keycloak listens on port 8443 (HTTPS) instead of 8080 inside the
       cluster: update `KEYCLOAK_ADMIN_URL` and any own NetworkPolicies.
    4. With another ingress controller than ingress-nginx, set
       `internalTLS.ingressNginxAnnotations: false` and configure HTTPS to
       the web apps (Traefik example on the Internal TLS page).
- Web app Services listen on port 443 (`https`) instead of 80, and backend
  Service ports are named `https`.
- Rally's Helm chart creates a separate Ingress `rally-submit` (with its own
  certificate `rally-submit-tls`) for the public submission site when
  `submit.enabled` is on; the `rally` Ingress now only serves the staff
  app. Helm moves the rule on upgrade; nothing to do unless you patch the
  Ingress yourself.
- Wiki, Desk, Learn and Tasks moved into their own repositories.
- Con Services is now documented and released for Kubernetes with
  published images. The Docker Compose stack is the contributor development
  path.
- The databases, backups and restore guide moved from `docs/operations.md`
  to the documentation site (Operations → Databases, backups and restore)
  and was adapted to Kubernetes. The old file was removed.
- **BREAKING:** Every web app image (`<module>-frontend`, `rally-submit`)
  now listens on port 8080 inside the container instead of 80, because
  nginx no longer runs as root. The root `docker-compose.yml` publishes the
  same host ports as before (`3000`–`3010`) on container port 8080, and
  `infra/proxy/Caddyfile` proxies to `<module>-frontend:8080`. If you keep
  your own Compose file or Caddyfile, change `:80` to `:8080` for every web
  app, then run `docker compose up -d --build`. Kubernetes manifests and
  Helm charts already used port 8080 and keep their ports and Services.
- Helm charts Den 0.1.1, and Desk, Finance, HR, Learn, Rally, Stash, Tasks
  and Wiki 0.2.1: the web app pods get a writable `/tmp` (`emptyDir`) for
  nginx's pid file and temporary files, which the new non-root web app
  images need with the read-only root filesystem. The Kustomize manifests
  for Den and Stash (`deploy/kubernetes/base/den`,
  `deploy/kubernetes/modules/stash`) get the same volume. No values change.
- The reference production Compose file
  ([Docker production](docs/operations/docker-production.md)) runs
  `den-frontend` with the same hardening as the other services
  (`read_only`, `cap_drop: ALL`, `no-new-privileges`, `/tmp` as `tmpfs`).
- **BREAKING:** The S3 server for development and the Kubernetes local
  trial is now [SeaweedFS](https://github.com/seaweedfs/seaweedfs) 4.52
  (`chrislusf/seaweedfs:4.52`, single-process `mini` mode) instead of
  MinIO, which no longer publishes community images. SeaweedFS was chosen
  because one container covers everything Con Services needs: a static
  key from `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`, buckets created at
  start (`-bucket=`), path-style requests, presigned GET and PUT, browser
  POST uploads, CORS, multipart uploads and Den's operator backups (all
  tested with the backends' `minio-go` client and the AWS CLI). It serves
  TLS itself and runs as a non-root user, so the local trial keeps
  internal TLS from `conservices-internal-ca` without a sidecar. Garage
  was also tested but needs generated keys, a cluster layout and a key
  bootstrap through its admin API before the first bucket exists.
  Production is unchanged: use a managed S3 service. Details:
    - Docker Compose: the service is `s3` (container `conservices-s3`,
      volume `conservices-s3-data`), still on `localhost:9000` and
      `https://s3.conservices.test`, with the same dev key
      `conservices` / `conservicesdev` and the same bucket names. There is
      no init job; backends wait until `s3` is healthy, which means every
      bucket exists. There is no web console; use any S3 client
      ([Local development](docs/contributing/local-development.md#object-storage-s3)).
      Stash and Den now set `S3_PUBLIC_BASE_URL: https://s3.conservices.test`.
    - The module stacks (`<module>/infra/docker-compose.yml` of Den, Stash,
      Rally, Learn and Wiki) use the same server as service `s3` on their
      reserved host ports (9010, 9000, 9020, 9030, 9040); the console ports
      (9011, 9001, 9021, 9031, 9041) are gone.
    - Kubernetes: Deployment, Service and PVC `s3` / `s3-data` in
      `conservices-data`, Certificate and Secret `s3-tls`, admin key in
      the Secret `s3-secrets` with the keys `AWS_ACCESS_KEY_ID` and
      `AWS_SECRET_ACCESS_KEY` (was `minio-secrets` with `MINIO_ROOT_*`).
      Every endpoint is now `https://s3.conservices-data.svc.cluster.local:9000`,
      and the NetworkPolicies select `app.kubernetes.io/name: s3`. The
      Helm charts' example `S3_ENDPOINT` values point at the same address.
      SeaweedFS reads its certificate only at start, so its liveness check
      restarts it when cert-manager renews `s3-tls`.

    What to do on upgrade:

    1. Docker Compose: if you need old uploads, export them from the
       running `conservices-minio` first
       ([how](docs/contributing/local-development.md#moving-from-minio)).
       Then run `docker compose up -d --remove-orphans` and remove the old
       volume with `docker volume rm conservices_conservices-minio-data`.
       Standalone module stacks leave volumes such as `stash_minio-data`
       and `rally_rally-minio-data`; remove them the same way.
    2. Kubernetes local trial: in your secret manager or overlay, create
       `s3-secrets` with `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`
       (the `production-external-secrets` example now reads the Vault path
       `conservices/data/s3` instead of `conservices/data/minio`). Apply
       the overlay, then delete the old objects:
       `kubectl delete deployment,service,serviceaccount,networkpolicy,pvc -n conservices-data minio minio-data --ignore-not-found`
       and `kubectl delete certificate,secret -n conservices-data minio-tls minio-secrets --ignore-not-found`.
       Trial data in MinIO is not migrated.
- Den, Stash, Rally and Learn rewrite presigned links to `localhost` only
  when the storage host is exactly `s3` or `minio` (before: any host
  containing `minio`) and `S3_PUBLIC_BASE_URL` is unset, so a production
  host name can never be rewritten by accident.
- **BREAKING:** the frontend images no longer contain an installation's
  sign-in settings, and the Kustomize production overlay no longer uses a
  custom `den-frontend` build. If you run your own frontend builds, switch to
  the published images and set `frontend.config` (Helm) or the
  `*-frontend-config` ConfigMap (Kustomize). See
  [Web app settings](https://aglelectronics.github.io/con-services/modules/den/configuration/#web-app-settings-configjson).
- Rally chart: `submit.image.repository` defaults to
  `ghcr.io/aglelectronics/rally-submit` and an empty `submit.image.tag` to
  `image.frontend.tag`; the image is published with every release.
- The GitOps template sets every web app's `frontend.config` from
  `cluster.yaml`'s `domain` (see its CHANGELOG). No new `cluster.yaml` keys.

### Removed

- MinIO, from the development Docker Compose stack (services `minio` and
  `minio-init`, volume `conservices-minio-data`, the web console on port
  9001), from the Kubernetes local trial (`deploy/kubernetes/base/data/minio.yaml`,
  Secret `minio-secrets`, Certificate `minio-tls`) and the unused
  `infra/minio/create-buckets.sh`. MinIO no longer publishes community
  images, so the pinned `quay.io/minio/minio` image could no longer be
  pulled. It is replaced by SeaweedFS (see Changed).

### Fixed

- The local DNS setup only touches its own, named proxy certificate.
- Shell scripts and the Caddyfile keep LF line endings on Windows.

### Security

- Rate limits can no longer be bypassed by sending a fake `X-Forwarded-For`
  header. Every module backend now reads the client address from
  `X-Forwarded-For` only when the connection comes from a trusted proxy,
  configured with the new `TRUSTED_PROXY_CIDRS` setting. The Helm charts
  (`config.TRUSTED_PROXY_CIDRS`), the Kustomize manifests for Den and Stash
  and the development `docker-compose.yml` set it to the private and loopback
  ranges, which covers the Gateway, nginx and Caddy. No action is needed
  unless a proxy in front of a backend has a public address; see
  [Client IP addresses](docs/operations/production.md#client-ip-addresses).
- No image runs as root any more: the module CI pipelines no longer allow a
  root exception for the web app images (`"allow-root": false`). The web
  apps run on `nginxinc/nginx-unprivileged` as UID 101; Den's operator runs
  on Alpine with only the PostgreSQL 16 client tools, without `gosu`. All
  images are built with Go 1.27.3 and pass the CI image scan (Trivy, HIGH
  and CRITICAL issues that have a fix). The image policy and the exceptions
  that remain (a shell in the web app and operator images) are documented
  on [CI and releases](docs/contributing/ci.md#image-policy).
