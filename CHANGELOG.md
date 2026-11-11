# Changelog

All notable changes to the shared pieces of Con Services (the Kubernetes
manifests, the shared Docker stack, Keycloak realm, proxy, CI workflows,
scripts and documentation) are documented in this file. Den and each module
keep their own changelog in their repository; each app's Helm chart in
`deploy/charts/<app>` is released with that app and described in its
changelog.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

First release, `v1.0.0`. Den and every module (HR, Rally, Stash, Finance,
Learn, Wiki, Desk, Tasks) start at `1.0.0` too, each with its own version
led by Den's MAJOR; see
[Versions and upgrades](docs/operations/versioning.md).

### Added

- Versioning: Den and each module have their own `MAJOR.MINOR.PATCH`; a
  module's MAJOR always equals the Den MAJOR it is built for. Den raises
  its MAJOR only for a breaking change and keeps counting (`1.4.2` →
  `2.5.0`); every module then releases the new MAJOR, also when unchanged
  (`1.3.0` → `2.3.0`). A module that uses something new in Den says so on
  its *Needs Den* line.
- The table of current releases on
  [Versions and upgrades](docs/operations/versioning.md#compatibility-table)
  is generated when the docs are built: the latest release of each app comes
  from its chart tag `<app>/vX.Y.Z`, *Needs Den* from that release's
  changelog. *Chart release* rebuilds the site after every chart tag. Images are
  `ghcr.io/aglelectronics/<app>-<component>:MAJOR.MINOR.PATCH-BUILD`, never
  `latest`. Each app's chart is released by the tag `<app>/vX.Y.Z` in this
  repository (for example `hr/v1.0.0`) and carries the annotation
  `conservices.io/den-major`. This repository's own tags `vX.Y.Z` version
  the shared pieces; Kustomize remote bases pin them.
- Helm charts for Den and every module (`deploy/charts/<app>`, `1.0.0`):
  migrations as an initContainer, an existing Secret from your secret
  manager, Gateway API routes (`HTTPRoute` plus `BackendTLSPolicy`),
  internal TLS (`internalTLS.*`), high-availability settings (`ha.*`,
  `priorityClassName`), default-deny NetworkPolicies with Cilium-aware
  rules, egress to an external S3 service, `imagePullSecrets`,
  `frontend.config` rendered as the web app's `/config.json`, and
  `den.mode` (`required` by default, or `standalone`). Den's chart adds
  `preregisterModules`. See [Helm](docs/operations/helm.md).
- Kubernetes manifests in `deploy/kubernetes/` (Kustomize): Keycloak in
  `conservices-identity`, PostgreSQL and a SeaweedFS S3 server in
  `conservices-data` (local trial only), Den in `conservices-den` and
  Stash in `conservices-stash`, published through a Gateway `public` in
  `conservices-gateway` with an `HTTPRoute` and a `BackendTLSPolicy` per
  web app. Overlays `example` and `example-stash` for a local kind cluster
  with Cilium (`deploy/kubernetes/local-cluster/`), and
  `production-external-secrets` with secrets from a secret manager through
  the External Secrets Operator.
- Internal TLS: `deploy/kubernetes/base/pki` holds the internal
  certificate authority (`ClusterIssuer/conservices-internal-ca`) and a
  trust-manager `Bundle` for every Con Services namespace; every connection
  inside the cluster is encrypted and checked. See
  [Internal TLS](docs/operations/internal-tls.md).
- Every module backend on Kubernetes runs with `DEN_MODE=required` and
  waits until it is paired with Den; the deploy validation workflow checks
  this with `scripts/check-den-mode.py`.
- Docker Compose stack for development: shared PostgreSQL (one database per
  module), SeaweedFS as the S3 server (one bucket per module), Keycloak with
  the `conservices` realm and login theme, Mailpit and Adminer, Den with
  its operator, the modules as compose profiles, and local HTTPS at
  `*.conservices.test` through Caddy (`scripts/setup-local-dns.ps1`).
  Module backends default to `DEN_MODE=standalone`; settings are in
  `.env.example`.
- `scripts/workspace.ps1` and `scripts/workspace.sh`: clone, update and
  check the root repository and all module and GitOps repositories in one
  go ([Local development](docs/contributing/local-development.md#the-workspace)).
- CI: the shared `module-ci.yml` workflow (pinned by the modules as
  `ci-v1`) tests, scans, builds, signs and publishes images with SBOMs on
  `vX.Y.Z` tags, and refuses a module release whose MAJOR differs from its
  `den-major` input. *Deploy validate* checks that a changed chart raises
  its version and renders every chart and Kustomize tree; *Chart release*
  checks every `<app>/vX.Y.Z` tag (chart version, Den MAJOR, published
  images, lint). See [CI and releases](docs/contributing/ci.md).
- Documentation site at <https://aglelectronics.github.io/con-services/>:
  getting started, concepts, a guide per module (setup, configuration, API
  reference), deployment with Argo CD, operations (running, Helm,
  versions and upgrades, internal TLS, network policies, secrets,
  databases and backups, disaster recovery, monitoring), contributing,
  proposals, and a *Changelog* page that shows this file and links to
  every app's changelog. Commands are given for bash and PowerShell 5.1.
- Deployment guide for the Argo CD template ([Deploy](docs/deploy/index.md)),
  written for Linux and Windows: every command has a bash and a PowerShell
  tab, and Linux-only steps are marked. It covers installing `age`,
  setting `KUBECONFIG`, cloning into `con-services-gitops`, why there are
  two Gateway IP addresses and how to pin them, why three nodes and the
  `small` profile for one or two, storage sizes as suggestions you can
  lower, the OpenBao layout `conservices/modules` and `conservices/infra`,
  the manual first sync of `openbao-setup`, and publishing through a
  Cloudflare Tunnel (point every public host name at the `public` Gateway;
  never publish `auth-admin`).
- Pairing is documented as an action an admin always takes: an admin
  creates the pairing URL in Den (**Modules → Pair**) and pastes it into
  the module's *Den connection* page. Pre-registered modules
  (`DEN_PREREGISTER_MODULES`) only appear as unpaired; nothing pairs
  automatically ([Pairing](docs/concepts/pairing.md)).
- Shared Go code in `shared/go`, the one source of the packages every
  module copies ([Shared code](docs/concepts/shared-code.md)):
  `groupmatch` (one rule for matching groups, with `OIDC_GROUPS_CLAIM`,
  `OIDC_GROUP_MATCH` and `OIDC_GROUP_PREFIX`), `denlink` (the Den pairing
  client, now with the credential encrypted at rest, a pairing host
  allow-list and a *revoked* state), `authbase` (safe `AUTH_MODE`/`APP_ENV`
  defaults, dev headers only in dev mode, bounded JSON bodies, rate
  limiting, API security headers) and `gworkspace` (Google Workspace
  accounts, groups and Gmail through a service account, with a fake for
  tests). Modules adopt them in their own releases.
- `scripts/sync-shared.ps1` and `scripts/sync-shared.sh` copy those
  packages into a module's `backend/internal/` with the module's import
  path, and with `-Check` / `--check` report every copy that drifted.
- CI: `module-ci.yml` has a new job **Shared code drift** (inputs
  `shared-check`, `shared-ref`, `shared-repository`) that fails a module's
  run when a generated copy differs from `shared/go`. Modules without
  copies pass unchanged. The new workflow **Shared Go** tests `shared/go`
  and builds a scratch module from the synced copies.
- `shared/nginx/security-headers.conf`: the security headers for every web
  app's nginx (Content Security Policy with Keycloak and Den origins,
  `X-Frame-Options`, `nosniff`, `Referrer-Policy`, `Permissions-Policy`);
  HSTS stays at the Gateway.
- Contracts for 1.0, implemented per module later:
  [Role catalog](docs/concepts/role-catalog.md) (dynamic and privileged
  roles, the catalog needs HR's service token or a staff sign-in, HR
  finds modules through Den), [Module settings](docs/concepts/module-settings.md)
  (retention, SMTP, Finance seller details and Stash Lost & Found
  retention set in Den; retention defaults are pending legal review), and
  on [Authentication](docs/concepts/authentication.md) the group matching
  rule, safe defaults, an access token per API kept only in memory, and
  portal to-dos fetched by Den's backend so no user token leaves Den.
- Secrets inventory: `DEN_LINK_ENCRYPTION_KEY` (one per module), its
  rotation with `DEN_LINK_ENCRYPTION_KEY_PREVIOUS`, and the Google
  Workspace service-account key mounted as a file
  ([Secrets](docs/operations/secrets.md#den-link-encryption-key)). The Docker
  Compose module backends and the `example-stash` overlay carry public
  dev-only values of `DEN_LINK_ENCRYPTION_KEY`.
- Proposal [Using the convention's existing identity provider](docs/proposals/existing-identity-provider.md)
  (agreed, not implemented yet): reuse a convention's attendee realm
  without moving accounts, staff modes `brokered` (our realm added next to
  theirs in their Keycloak) and `existing` (HR link-only), HR as the only
  source of access with an offboarding warning, a review queue for
  volunteers with self-service data entry, and an `.xlsx`/`.csv`
  importer.
- Docker Compose dev stack: healthchecks for Mailpit, GreenMail, Adminer,
  the proxy, Den's backend and operator (`healthcheck` subcommand) and
  every web app; services wait for `healthy` dependencies, and Den's web
  app for a healthy Den backend. Den's backups now include every dev
  bucket (`FILES_S3_BUCKETS` adds `finance-data-dev`, `learn-data-dev`
  and `tasks-data-dev`). `.env.example` documents `COMPOSE_PROFILES`,
  `DEN_MODE` and `TELEGRAM_BOT_TOKEN`
  ([Local development](docs/contributing/local-development.md#how-the-stack-protects-your-computer)).

### Security

- Default-deny NetworkPolicies in every namespace with an explicit allow
  list, `restricted` Pod Security on every namespace, resource requests and
  limits on every container, and no service account tokens mounted.
- No image runs as root; the trial PostgreSQL and S3 containers run with a
  read-only root file system. The image policy and its remaining
  exceptions are on [CI and releases](docs/contributing/ci.md#image-policy).
- Module backends read the client address from `X-Forwarded-For` only from
  trusted proxies (`TRUSTED_PROXY_CIDRS`), set to the private ranges in
  the charts, the Kustomize manifests and Docker Compose; see
  [Client IP addresses](docs/operations/production.md#client-ip-addresses).
- Every S3 bucket has its own access key, restricted to that bucket, and
  documented commands never put tokens on the command line.
- Docs recommend pinning both Gateway IPs, so the Keycloak admin console
  can never be exposed through the public Gateway, and never publishing
  `auth-admin` through a Cloudflare Tunnel.
- The shared `denlink` refuses pairing URLs whose host is not in
  `DEN_ALLOWED_HOSTS` when `DEN_INTERNAL_URL` is not set, requires
  `https://` outside development and never follows redirects, so a pasted
  URL cannot make a module's backend call an arbitrary address. A module
  using it refuses to start outside `APP_ENV=development` without
  `DEN_LINK_ENCRYPTION_KEY`, and never re-pairs by itself after Den
  revoked its credential.
- Docker Compose dev stack: every published port is bound to `127.0.0.1`,
  so the public dev passwords are not reachable from your network;
  Adminer, Mailpit, GreenMail and Caddy are pinned to exact versions;
  Mailpit runs as a normal user and the proxy keeps only
  `NET_BIND_SERVICE`. The dev proxy sends `Strict-Transport-Security`
  on every host.
- HSTS at the Gateway: every `HTTPRoute` of the Kustomize manifests
  (Den, Keycloak, Stash) sets `Strict-Transport-Security:
  max-age=31536000; includeSubDomains` with a `ResponseHeaderModifier`
  filter; the app charts do the same through the new value
  `route.responseHeaders` (`{}` turns it off). CSP and frame headers stay
  in each web app's nginx
  ([Security headers](docs/operations/production.md#security-headers)).
