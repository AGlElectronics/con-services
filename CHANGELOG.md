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

- Development: the `conservices` realm has the groups `hr-viewer` (read-only
  HR) and `hr-lead` (department leads) next to `hr-admin`, and
  `docker-compose.yml` lets the wiki list HR's departments and access groups
  (`HR_DIRECTORY_URL`, and `HR_DIRECTORY_TOKEN` on both backends with the
  dev-only value `hr-directory-dev-token`). An existing dev stack picks up
  the new groups only after the realm is re-imported.
- Stash on Kubernetes (Kustomize): the CiliumNetworkPolicy
  `stash-backend-external` lets `stash-backend` reach `api.telegram.org` on
  443 for Stash's Lost & Found Telegram bot; nothing is sent without
  `TELEGRAM_BOT_TOKEN`. The example overlay's `stash-secrets` has the
  optional keys `TELEGRAM_BOT_TOKEN` and `SMTP_PASSWORD` (empty, dev only).
  See [Network policies](docs/operations/network-policies.md#every-allowed-flow)
  and [Secrets](docs/operations/secrets.md#inventory).
- Docker Compose: `stash-backend` reads `STASH_TELEGRAM_BOT_TOKEN` and
  `STASH_SMTP_PASSWORD` from `.env` (both optional) and runs its background
  jobs (`JOBS_ENABLED=true`). For overdue emails in development, point
  Stash's SMTP settings at `mailpit:1025` with security `none`.
- The development Keycloak realms send **full group paths**. Every web
  app client's groups mapper in `infra/keycloak/realm-conservices.json`
  has `full.path` true, and `infra/keycloak/apply-mvp.sh` sets the same
  on realms that were imported earlier. A top-level group still matches
  its short name (the leading `/` is stripped). Nested groups such as
  `/learn/demo-cohort` match only by full path.
- Learn in the shared Docker stack: `GROUP_DIRECTORY`
  (`LEARN_GROUP_DIRECTORY`, default `keycloak`), `LEARN_LINKABLE_GROUPS`
  (default `/learn/*`) and a dev-only `LEARN_FEEDBACK_PEPPER`. The dev
  Keycloak script (`infra/keycloak/apply-mvp.sh`) creates the
  `learn-manager` group (training managers) and a `/learn` parent group
  with `/learn/demo-cohort` for trainers to link.
- Documentation: user guides for Learn learners, trainers and admins;
  the Learn feedback pepper (`conservices/modules/learn/feedback-pepper`)
  in the secrets inventory and the OpenBao layout; Learn's egress to the
  Telegram Bot API on the network-policy page. `scripts/smoke-learn.ps1`
  now also covers quizzes, media uploads, in-person sessions with QR
  check-in, and certificates.
- Desk's development stack expects access tokens with audience `desk-api` (`OIDC_AUDIENCE` in Compose and the Desk chart). The Desk chart admits `den-backend` from `conservices-den` (portal to-dos and the role catalog), fills the shared nginx security-header snippet on the web app only, and names the Google settings `GOOGLE_WORKSPACE_CREDENTIALS_FILE` and `GOOGLE_WORKSPACE_ADMIN_EMAIL`. The Desk frontend sets `EXTRA_FRAME_SRC=about:srcdoc` (Compose and the chart) and serves `/silent-callback.html` with the shared frame-self headers.

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
- Docker Compose: Finance stores its invoice and credit note PDFs in the
  dev bucket `finance-data-dev`, which Den's operator now copies into its
  backups (`FILES_S3_BUCKETS`). The dev Keycloak realm has Finance's four
  role groups `finance_admin` (user `admin`), `finance_approver` (`alice`)
  and `finance_bookkeeper` (`bob`) and `finance_read-only`, replacing
  `finance-admin`; `FINANCE_APPROVAL_THRESHOLD_CENTS` in `.env` changes
  how much needs a second person. An existing dev realm gets the groups
  from `infra/keycloak/apply-mvp.sh`.
- `scripts/smoke-finance.ps1`: checks Finance's money loop against the
  running stack (roles, issuing with a stored PDF, a payment approved by a
  second person, a credit note and refund, a closed month, the audit log).
- Docs: Finance's [Bookkeeping](docs/modules/finance/bookkeeping.md) guide,
  and the Finance bucket in [Buckets and keys](docs/deploy/data.md#buckets-and-keys),
  the [secrets inventory](docs/operations/secrets.md) and the
  [network policy flows](docs/operations/network-policies.md).
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
- Secrets inventory: `HR_SERVICE_TOKEN` is now read by Rally, with how to
  generate and rotate it ([HR service token](docs/operations/secrets.md#hr-service-token)).
- Docker Compose (`events` profile): the Rally backend sets
  `OIDC_AUDIENCE=events-api`, `ATTENDEE_OIDC_AUDIENCE=events-public-api`
  and a public dev-only `HR_SERVICE_TOKEN`, and the Rally web apps set
  `KEYCLOAK_ORIGIN` and `S3_ORIGIN` for their Content Security Policy.
  Signing in to Rally in the stack needs audience mappers on `events-spa`
  and `rally-submit` in the local realms, which the realm files do not
  contain yet.
- Proposal [Using the convention's existing identity provider](docs/proposals/existing-identity-provider.md)
  (agreed, not implemented yet): reuse a convention's attendee realm
  without moving accounts, staff modes `brokered` (our realm added next to
  theirs in their Keycloak) and `existing` (HR link-only), HR as the only
  source of access with an offboarding warning, a review queue for
  volunteers with self-service data entry, and an `.xlsx`/`.csv`
  importer.
- Shared Go code: `denlink` reads Den's [module settings](docs/concepts/module-settings.md)
  from the bundle (`client.ModuleSettings()`, with helpers for retention,
  SMTP and Finance's seller details and dotted keys such as
  `wiki.revision_retention_days`). They are stored with the bundle, so a
  restarted module has them before it reaches Den, and bundles stored by an
  older Den still load. Modules no longer need their own SQL on
  `den_link.bundle`.
- Shared Go code: a paired module fetches a module-setting secret from Den
  with `ModuleSettingSecret` / `SMTPPassword` (the SMTP password). The
  value stays in memory for at most one minute, is dropped on sync, unpair
  or a rejected credential, and is never written to the module database.
  See [Fetching the SMTP password](docs/concepts/module-settings.md#fetching-the-smtp-password).
- Shared Go code: `denlink.Client.Modules` lists the organisation's
  paired modules from Den (`GET /api/v1/integrations/modules`, with the
  module's pairing credential). Each entry carries the slug, name,
  addresses and `role_catalog_url` HR uses to discover role catalogs.
  The list stays in memory for one minute (`ModulesCacheTTL`), is refused
  when larger than 64 KiB, and is dropped on sync, unpair or a rejected
  credential. Standalone returns `ErrNotPaired`; a rejected credential
  returns `ErrRevoked`. See
  [Paired modules](docs/concepts/shared-code.md#paired-modules).
- Shared Go code: `gworkspace` lists and creates a Gmail label by name
  (`ListLabels`, `CreateLabel`), restores a trashed message
  (`UntrashMessage`), and creates and deletes a send-as alias
  (`CreateSendAs`, `DeleteSendAs`). Send-as calls need the extra scope
  `https://www.googleapis.com/auth/gmail.settings.sharing`
  (`gworkspace.SendAsScope`), authorised in domain-wide delegation only
  for a module that creates aliases (Desk). Other Gmail calls stay on
  `gmail.modify`. See
  [Google Workspace service account](docs/concepts/shared-code.md#google-workspace-service-account).
- Nginx: `shared/nginx/security-headers-frame-self.conf.template` is the
  shared security headers with `frame-ancestors 'self'` and
  `X-Frame-Options: SAMEORIGIN`, for the exact location
  `= /silent-callback.html` only. Silent sign-in (tokens kept in memory)
  loads that page in a hidden iframe of the app itself, which
  `frame-ancestors 'none'` blocks. `EXTRA_FRAME_SRC` (empty by default)
  adds tokens to `frame-src`; Desk sets it to `about:srcdoc` for the
  sandboxed mail frame. See
  [Silent sign-in iframe](docs/concepts/shared-code.md#silent-sign-in-iframe).
- Shared Go code: `RequireDen` checks a call Den makes into a module on
  `GET /api/portal/todos`. It compares the pairing credential in constant
  time and reads the person from `X-Den-User-Issuer` and
  `X-Den-User-Subject`. A missing or wrong credential answers `401`;
  missing identity headers answer `400`. See
  [Portal to-dos](docs/concepts/shared-code.md#portal-to-dos).
- Shared Go code: `authbase` can find the real client behind the Gateway
  from `TRUSTED_PROXY_CIDRS` (the same variable and default every module
  already uses; `X-Forwarded-For` is read only from trusted proxies, right
  to left), and can expose response headers to the web app through CORS
  (`X-Request-ID` by default).
- [Shared code](docs/concepts/shared-code.md#error-codes) documents
  `authbase`'s error codes (`bad_request`, `request_too_large`,
  `unsupported_media_type`, `rate_limited`) as part of the API contract,
  that module tests need `APP_ENV=development` for the dev headers and for
  `denlink`, and that grants cannot be matched with an SQL `=` when
  `OIDC_GROUP_PREFIX` or `OIDC_GROUP_MATCH=last` is set.
  [Authentication](docs/concepts/authentication.md#refusing-id-tokens)
  explains that refusing ID tokens relies on Keycloak's `typ` claim.
- Docker Compose dev stack: healthchecks for Mailpit, GreenMail, Adminer,
  the proxy, Den's backend and operator (`healthcheck` subcommand) and
  every web app; services wait for `healthy` dependencies, and Den's web
  app for a healthy Den backend. Den's backups now include every dev
  bucket (`FILES_S3_BUCKETS` adds `finance-data-dev`, `learn-data-dev`
  and `tasks-data-dev`). `.env.example` documents `COMPOSE_PROFILES`,
  `DEN_MODE` and `TELEGRAM_BOT_TOKEN`
  ([Local development](docs/contributing/local-development.md#how-the-stack-protects-your-computer)).
- Docker production is a supported target: `deploy/docker/` holds a
  tested `compose.production.yml` (pinned images, no dev services,
  healthchecks, non-root users, read-only file systems, only the proxy
  publishes ports, bundled PostgreSQL without a published port, one
  profile per module), a `Caddyfile` with Let's Encrypt, HSTS, Keycloak
  limited to its public paths and the admin console restricted to
  `ADMIN_ALLOWED_CIDRS`, an `.env.example` for secrets written from a
  secret manager, `postgres/init-databases.sh` and the web apps'
  `/config.json` files. The realm comes from the GitOps template's
  `keycloak-realm.py --format json`; the web apps' nginx gets the shared
  security headers. CI renders it (Den only and every profile) and
  validates the Caddyfile
  ([Docker production](docs/operations/docker-production.md)).
- Docs: [Production](docs/operations/production.md#secrets) lists every
  public test value (database logins, S3 keys, Keycloak admin and client
  secrets, service tokens, `DESK_SECRET_KEY`, `DEN_LINK_ENCRYPTION_KEY`,
  the age key, ...) with its replacement and where the Argo CD template
  generates it; the Keycloak section and
  [Identity](docs/deploy/identity.md#den-and-the-realm) describe brute-force
  protection, the password policy, `den-keycloak` reduced to
  `manage-realm` (or nothing) and how to change a running realm.
  [Databases and backups](docs/operations/databases-and-backups.md#where-backups-go)
  documents the warning for backups on the same S3 service and the
  `BACKUP_SAME_STORAGE_AS_DATA` flag Den's operator gets (the dev stack
  sets it to `true`). The secrets inventory lists each module's generated
  `conservices/modules/<module>/den-link` entry in OpenBao.
- Nightly **Smoke** workflow (`.github/workflows/smoke.yml`, also run by
  hand with a module image tag): the Den quickstart cluster on kind with
  Den's pinned images, every module from its Helm chart with published
  images (`scripts/ci/smoke-cluster.sh`), then `smoke-access-catalog.ps1`,
  `smoke-learn.ps1` and `smoke-tasks.ps1` under PowerShell 7 on Ubuntu
  ([Smoke tests](docs/contributing/ci.md#smoke-tests)).
- Smoke scripts read their addresses from `SMOKE_*` variables
  (`scripts/smoke-lib.ps1`, defaults are the Compose dev ports) and run on
  Linux. `smoke-access-catalog.ps1` now checks all nine role catalogs
  (Den, HR, Rally, Stash, Learn, Finance, Desk, Tasks, Wiki), signs in when
  a catalog answers `401`, and takes `-Skip <modules>`.
- Docs: [Wiring a new module](docs/contributing/new-module.md), a checklist
  for adding a module to the dev stack, the Helm charts and Argo CD
  template, Docker production, secrets and docs.
- Finance gets its own S3 bucket for invoice PDFs and receipts: in the
  Argo CD template `<prefix>-conservices-finance` with the key
  `conservices/modules/finance/s3`, backed up by Den
  ([Data](docs/deploy/data.md)); in Docker production
  `FINANCE_S3_BUCKET`, `FINANCE_S3_ACCESS_KEY_ID` and
  `FINANCE_S3_SECRET_ACCESS_KEY` (without them Finance received
  `S3_ENDPOINT` alone and refused to start).
- The `conservices` Keycloak login theme fetches the brand from Den's public
  endpoint in the browser (and caches it), instead of reading a realm
  attribute Den used to write. Set `DEN_PUBLIC_URL` on Keycloak; the Docker
  stack and the Kustomize identity base do.
- Dev realm: group `den-ops` (Den's new ops role for backups and database
  deletion), given to the `admin` account; `alice` stays an admin without
  it.
- Docker stack: healthchecks for `den-backend` and `den-operator` (their
  `healthcheck` subcommand) and `den-frontend`; the web app waits for a
  healthy backend. `den-backend` gets `DEN_OPS_GROUPS`,
  `IDENTITY_STAFF_MODE` and a dev-only `DEN_CREDENTIAL_KEY`.
- Kubernetes: `den-config` gains `DEN_OPS_GROUPS` and `IDENTITY_STAFF_MODE`;
  `den-secrets` gains the optional `DEN_CREDENTIAL_KEY` (dev value in
  `overlays/example`, Vault key `conservices/den/backend` in the External
  Secrets example). The Den backend uses `RollingUpdate` and may run more
  than one replica.
- NetworkPolicies: `den-backend` may reach module backends on 8080 (role
  catalogs, portal to-dos), and Stash admits `den-backend`. Documented on
  [Network policies](docs/operations/network-policies.md#calls-between-modules).
- `scripts/smoke-den-operator.ps1` (roles, managed database, backup, one-time
  download, removal, audit log); `scripts/smoke-den-pairing.ps1` registers
  a missing module and checks that organisation settings reach it.
- Runbooks: [a leaked pairing URL or module credential](docs/operations/disaster-recovery.md#a-pairing-url-or-module-credential-leaked)
  and [a failing Keycloak name sync](docs/operations/disaster-recovery.md#the-keycloak-name-sync-fails).
- `scripts/check-chart-versions.py --base` no longer asks for a version bump
  of a chart whose version was never released (no `<app>/vX.Y.Z` tag yet).
- Desk in the shared stack: the bucket `desk-data-dev` in the Docker
  Compose S3 server (and in the Den operator's `FILES_S3_BUCKETS`, so dev
  backups include it), `desk-data` in the trial S3 server of
  `deploy/kubernetes/base/data/s3.yaml`, and the Desk backend in Compose
  now stores attachments in S3, may reach GreenMail and Mailpit
  (`DESK_ALLOWED_MAIL_HOSTS`) and sends its own emails as
  `Desk <desk@conservices.test>` through Mailpit (`NOTIFY_FROM`).
- `scripts/smoke-desk.ps1`: an end-to-end check of Desk against the dev
  stack (mailbox on GreenMail, incoming mail, reply, undo, note, access per
  mailbox, trash), cleaning up after itself
  ([Desk setup](docs/modules/desk/setup.md#option-4-development-on-docker)).
- Desk documentation: Google Workspace and IMAP setup, access, user guide,
  operations (trash, retention, rotating `DESK_SECRET_KEY`), and the full
  API reference. The secrets inventory lists Desk's S3 key, the previous
  secret key and the Google service account key (Secret `desk-google`, with
  an ExternalSecret example); the network policy flow table lists Desk's
  egress to Google APIs and to mail servers.
- Docker stack: the Tasks backends (`tasks` and `tasks-dev` profiles) send
  email notifications to Mailpit (`SMTP_HOST=mailpit`, port 1025, no TLS,
  dev-only) and link to the web app through `TASKS_PUBLIC_URL`. Open
  Mailpit to see them.
- Docs: [Network policies](docs/operations/network-policies.md) lists the
  HR → Tasks department hook (ingress in the Tasks chart; HR's egress needs
  `conservices-tasks`) and the Tasks backend's egress to the mail server;
  [Secrets](docs/operations/secrets.md) lists Tasks' optional SMTP login.
- Docker stack: the Tasks backends check the access-token audience
  `tasks-api` (`OIDC_AUDIENCE`; `OIDC_CLIENT_ID` is gone), `tasks-backend`
  has a dev-only `HR_SERVICE_TOKEN` for the role catalog, and both Tasks web
  apps set `KEYCLOAK_ORIGIN=https://auth.conservices.test` for their
  Content-Security-Policy. Recreate the Tasks containers to pick it up.
- Docs: [Secrets](docs/operations/secrets.md) lists Tasks'
  `DEN_LINK_ENCRYPTION_KEY` and `HR_SERVICE_TOKEN`; the HR → Tasks row on
  [Network policies](docs/operations/network-policies.md) names the token
  for the role catalog.
- Tasks serves `GET /api/portal/todos` for Den's portal. The Tasks chart
  admits `den-backend` on the backend port (`networkPolicy.den`), and the
  Den chart's `networkPolicy.allowToModules` (default on) lets
  `den-backend` reach module backends on 8080. The same egress is in
  `deploy/kubernetes/base/den`.

### Changed

- HR's chart expects access tokens for audience `hr-api`, lists
  `DEN_LINK_ENCRYPTION_KEY` and `HR_SERVICE_TOKEN` on `existingSecret`,
  fills nginx security-header origins from env (never a filled-in
  ConfigMap), and allows the backend to call Photon
  (`networkPolicy.addressLookup`). `/silent-callback.html` uses the
  frame-self snippet so the app can frame its silent sign-in page;
  `EXTRA_FRAME_SRC` stays empty. The Wiki chart allows its backend to
  call HR's group directory.
- Development Compose sets `OIDC_AUDIENCE=hr-api` on HR and the dev-only
  `HR_SERVICE_TOKEN` (`dev-only-hr-service-token-change-me-0000000000`) on HR and on
  every module that checks role-catalog calls. `scripts/smoke-hr-keycloak.ps1`
  sends the access token.
- [Secrets](docs/operations/secrets.md) records `HR_SERVICE_TOKEN` (shared
  by HR, Wiki, Finance, Rally, Tasks, Stash, Learn and Desk) and
  `HR_DIRECTORY_TOKEN` (HR and Wiki). [Google Workspace](docs/modules/hr/google-workspace.md)
  describes the Cloud and Admin console steps for the connector, which
  runs when the service-account key is mounted.
- Den's Helm chart and Kustomize nginx include the shared
  `security-headers-frame-self.conf` for `/silent-callback.html` (same-origin
  framing for silent sign-in). The image copies that template; it no longer
  builds a `security-headers-frameable.conf` with `sed`. `EXTRA_FRAME_SRC`
  stays empty on Den.
- The [Den API reference](docs/modules/den/api.md#get-apiv1integrationsmodules)
  documents `GET /api/v1/integrations/modules`: a paired module lists the
  organisation's enabled, paired modules and each one's `role_catalog_url`.
  HR's call is already allowed by the module-backend egress to `den-backend`
  and Den's ingress from module backends
  ([Network policies](docs/operations/network-policies.md#calls-between-modules)).
- Rally's chart lets each web app frame `/silent-callback.html` only
  (`frame-ancestors 'self'`). The submission site's policy still uses the
  attendee realm's server (`ATTENDEE_OIDC_ISSUER_URL`) and
  `S3_PUBLIC_BASE_URL`; images may load from that bucket.
  `frontend.cspConnectSrc` is added to `connect-src` only.
- Stash's web app may frame `/silent-callback.html` from Stash itself, so
  a reload can finish silent sign-in. The Helm chart, the Kustomize nginx
  config and the dev Compose service leave `EXTRA_FRAME_SRC` empty. Every
  other page stays unframeable, and both header snippets keep
  `camera=(self)`.
- Finance's web app may frame `/silent-callback.html` from Finance itself,
  so a reload can finish silent sign-in. The Helm chart and the dev
  Compose service leave `EXTRA_FRAME_SRC` empty. Every other page stays
  unframeable.
- Learn's Helm chart admits `den-backend` from `conservices-den` on the
  backend port, so Den can call `GET /api/portal/todos`. Den's egress to
  module backends is still added with Den's release. See
  [Calls between modules](docs/operations/network-policies.md#calls-between-modules).
- Wiki's chart lets the web app frame `/silent-callback.html` only
  (`frame-ancestors 'self'`, `X-Frame-Options: SAMEORIGIN`), using the same
  `frontend.securityHeaders` origins as the rest of the page. Every other
  response stays unframeable, so a reload can sign in again.
- Shared Go code: `gworkspace` reports `google workspace is not configured`
  and `google workspace needs …` with a lowercase first letter, like the
  package's other errors.
- Shared Go code: `denlink` error strings now follow Go's convention
  (`ErrRevoked`, `den refused the pairing URL`, `den returned …` — a
  lowercase first letter, no trailing punctuation). The sentence an admin
  sees is unchanged: the API `message` field and `last_error` on the Den
  connection page still say "Den rejected…", "Den refused the pairing URL"
  and "Den returned …" (`denlink.UserMessage`).
- **BREAKING:** Den's shared SMTP password is the optional secret
  `DEN_SMTP_PASSWORD` (`den-secrets`; empty in the development Compose
  stack and the example overlay, because Mailpit needs no login). The
  production ExternalSecret example lists the key. It is not stored in
  Postgres. Before upgrading a trial that saved the password in Den, copy
  it into the secret; Den's upgrade drops the stored value. See
  [Secrets](docs/operations/secrets.md) and
  [Module settings](docs/concepts/module-settings.md).
- Den's Compose stack and Kubernetes base accept access tokens with
  audience `den-api` (the backend no longer reads `OIDC_CLIENT_ID`). The
  operator sets `BACKUP_SAME_STORAGE_AS_DATA` (true on the local trial,
  where backups share the S3 server with the live data) and the dev backup
  list includes every module bucket, including `finance-data-dev`. The Den
  web app container gets `KEYCLOAK_ORIGIN` for its Content-Security-Policy,
  and `/silent-callback.html` is allowed to be framed by Den itself.
- The [module settings contract](docs/concepts/module-settings.md) now
  includes Tasks' retention and reminders and Rally's submission-site host,
  and its Den API section matches Den: one organisation document at
  `GET`/`PUT /api/v1/module-settings` with `{"data": {…}}`, a read-only
  per-module view, and the SMTP password only from
  `GET /api/v1/integrations/module-settings/secrets` (Den's secret
  `DEN_SMTP_PASSWORD`, not the database).
- **BREAKING:** Stash's Helm chart (still `1.0.0`; there is no chart
  release tag yet), Kustomize manifests and Docker Compose follow the
  token contract. `OIDC_AUDIENCE` is `stash-api`. `stash-secrets` must
  include `DEN_LINK_ENCRYPTION_KEY` or the backend pod does not start,
  unless `APP_ENV` is `development`. The web app container needs
  `KEYCLOAK_ORIGIN` (the chart takes it from the sign-in address when
  `frontend.securityHeaders.keycloakOrigin` is empty).
  `scripts/smoke-stash.ps1` sends access tokens, and its role-catalog
  call is signed in. The OpenBao guide lists `modules/stash/telegram`,
  `modules/stash/smtp` (both optional) and `modules/hr/service-token`
  (generated when HR is enabled; Stash receives it when Stash is enabled
  too). What to change on an
  existing installation is in
  [Stash's changelog](https://github.com/AGlElectronics/stash/blob/main/CHANGELOG.md).
- Network policies: Wiki's egress to HR for the group directory is the
  chart value `networkPolicy.hr` (namespace `conservices-hr`, HR's backend,
  port 8080). It stays off until `networkPolicy.hr.enabled` is set, which
  is what you do together with `HR_DIRECTORY_URL`. HR's chart already
  admits `conservices-wiki`, and HR serves
  `GET /api/internal/directory/groups` when `HR_DIRECTORY_TOKEN` is set.
  The flow table records both sides.
- [Module settings](docs/concepts/module-settings.md): the contract now
  says where every key lives. Settings for one module are under its slug
  (`finance.seller.legal_name`, `stash.lost_found.mode`,
  `wiki.revision_retention_days`), shared ones under `retention.*` and
  `smtp.*`, always inside `module_settings.data`; Den sends only the
  calling module's own section. Adds Wiki's `wiki.revision_retention_days`
  and a full example of every key.
- Shared Go code: `denlink`'s pairing and preferences endpoints answer
  `413 request_too_large` for a body over 64 KiB (was `400 bad_request`)
  and `400 bad_request` for a body with more than one JSON value.
- Nginx security headers: the docs and the template say plainly that
  nothing fills in the origins when the file is copied; the nginx image
  does at every container start from `KEYCLOAK_ORIGIN`, `DEN_ORIGIN`,
  `S3_ORIGIN` and `EXTRA_CONNECT_SRC`. Charts pass these as `env` and
  never ship a filled-in copy. The inline scripts in `index.html` (theme)
  and `silent-callback.html` must move to files; the docs show how.
- Production Compose passes optional `DEN_SMTP_PASSWORD` into
  `den-backend` (empty when unset in `.env`). The shared SMTP password is
  not stored in Den's database. Restart `den-backend` after changing it.
- Shared Go code: `authbase` and `denlink` read `APP_ENV` the same way
  (trimmed, any case, `production` when unset), through the new
  `NormalizeAppEnv` in each package. `APP_ENV=Development` now counts as
  development in `denlink` too, and `denlink.FromEnv` reports an unset
  `APP_ENV` as `production` instead of an empty value.
- Shared Go code: the `authbase` rate limiter counts IPv6 clients per
  `/64` network (`authbase.ClientIP` returns keys such as
  `ip:2001:db8:1:2::/64`), so a client cannot dodge the limit by switching
  addresses inside its own network. IPv4 clients are still counted per
  address.
- Nginx security headers: new `shared/nginx/security-headers.conf.template`
  that the official nginx image fills in at start-up from
  `KEYCLOAK_ORIGIN`, `DEN_ORIGIN`, `S3_ORIGIN` and `EXTRA_CONNECT_SRC`, so
  one frontend image works for any domain. Both forms of the snippet now
  allow an S3 storage origin (`connect-src` and `img-src`) for apps that
  upload straight from the browser. The docs explain the Dockerfile lines,
  why the snippet goes into each serving `location` and never at `server`
  level or into `/api/` (two Content Security Policies), moving inline
  scripts into files, and Stash's `camera=(self)`
  ([Shared code](docs/concepts/shared-code.md#nginx-security-headers)).
- Keycloak development realms: every web app client has an audience mapper
  that adds its API to its access tokens (`den-api`, `hr-api`,
  `stash-api`, `events-api`, `learn-api`, `finance-api`, `desk-api`,
  `tasks-api`, `wiki-api`, and `events-public-api` on `rally-submit` in
  the `attendees` realm). ID tokens are unchanged, so modules that still
  send ID tokens keep working. `infra/keycloak/apply-mvp.sh` adds the
  mappers to existing development realms. A running production realm
  needs the audience mappers and the full group paths added by hand
  before a module that checks its audience is upgraded
  ([Upgrade a realm that already exists](https://github.com/AGlElectronics/con-services-gitops/blob/main/docs/realm-mappers.md#upgrade-a-realm-that-already-exists)).
- Production realms written by the GitOps `keycloak-realm.py` include
  one access-token audience mapper per public client and `groups`
  mappers with full paths (`/den-admin`). Docker production generates
  those JSON files at install time (`--format json`); `deploy/docker/`
  does not commit a realm. A realm Keycloak has already imported keeps
  its previous mappers until you add them with the same steps
  ([The realms](docs/deploy/identity.md#the-realms),
  [Docker production](docs/operations/docker-production.md#the-realm)).
- CI *Chart versions*: a changed chart needs a higher version only once
  its app has a chart release tag `<app>/v*`; before the first release a
  chart may change while staying at its first version.
- [Shared code](docs/concepts/shared-code.md#what-adopting-a-package-involves)
  notes that a module needs an ESLint configuration when its frontend has a
  `lint` script, because the module CI runs `npm run lint`.
- Docker Compose: `finance-backend` checks access tokens with the audience
  `finance-api` (`OIDC_AUDIENCE`), as Finance follows the token contract,
  and `finance-frontend` sets `KEYCLOAK_ORIGIN=https://auth.conservices.test`
  for its Content Security Policy. A dev realm created before the audience
  mappers needs `infra/keycloak/apply-mvp.sh` once, or Finance answers
  `401 invalid token`.
- `scripts/smoke-finance.ps1` signs in with the access token instead of the
  ID token.
- Kustomize: the Den operator's `FILES_S3_BUCKETS` in the base and the
  overlays now says to add each installed module's bucket (for example
  `wiki-data`; Wiki's page bodies exist only in its bucket).
- Root `docker-compose.yml`: `wiki-backend` sets
  `WIKI_REVISION_RETENTION_DAYS` and the (empty) group-picker settings
  `HR_DIRECTORY_URL` and `HR_DIRECTORY_TOKEN`.
- Network policies: the flow table and *Calls between modules* list HR →
  Wiki (role catalog and offboarding hook, with the HR chart values to add),
  Wiki → HR (group picker directory, opt-in) and Wiki → Keycloak admin API
  (group picker when standalone, opt-in). The secrets inventory lists
  Wiki's optional `HR_DIRECTORY_TOKEN` and `IDP_DIRECTORY_CLIENT_SECRET`.
- `scripts/smoke-wiki.ps1` also checks that SVG uploads download as
  sandboxed attachments, that comment-level people start page discussions
  but cannot anchor threads to text, that the people picker hides email
  addresses from non-admins, and sends the issuer to the offboarding hook.
- Keycloak realm (`infra/keycloak/realm-conservices.json`): `wiki-spa` gets
  an audience mapper that adds `wiki-api` to its access tokens (token
  contract). `infra/keycloak/apply-mvp.sh` has a reusable, idempotent
  `api_audience <client> <audience>` helper and calls it for Wiki.
- Root `docker-compose.yml`: `wiki-backend` checks access tokens for
  `OIDC_AUDIENCE=wiki-api`, sets `OIDC_GROUPS_CLAIM` and `OIDC_GROUP_MATCH`,
  and has a dev-only `HR_SERVICE_TOKEN`. Until HR sends that token, HR's
  access picker in the Compose stack shows no Wiki roles (Wiki's catalog now
  needs it).
- Module settings contract: Wiki's key `wiki.revision_retention_days`
  (revision history retention).
- **BREAKING (dev realm):** the Keycloak group `desk-agent` is gone from the
  dev realm (`infra/keycloak/realm-conservices.json`, `apply-mvp.sh`). Desk
  grants access per mailbox with groups `desk-<slug>-viewer`, `-manager`
  and `-delete`; the dev realm has them for the `support` mailbox, and
  `alice` is in `desk-support-manager`. On an existing dev Keycloak, run
  `infra/keycloak/apply-mvp.sh` again and delete the `desk-agent` group.
- `DESK_SECRET_KEY` can be rotated now (with `DESK_SECRET_KEY_PREVIOUS` and
  `/server reencrypt`); the secrets pages no longer say to treat it as
  fixed ([Rotate DESK_SECRET_KEY](docs/modules/desk/operations.md#rotate-desk_secret_key)).

### Fixed

- Docker Compose: GreenMail's healthcheck runs under bash. The image's
  `/bin/sh` cannot open `/dev/tcp`, so the check never passed and Desk
  stayed stopped.
- Desk's web app in Docker Compose sets `KEYCLOAK_ORIGIN`, so the browser
  may talk to the sign-in server. The Helm chart fills that origin from
  the web app's sign-in address when `frontend.securityHeaders.keycloakOrigin`
  is empty.
- The access-catalog smoke signs in with an access token for each module's
  own client. ID tokens are refused, and one module's token is not valid
  for another's API. The person it creates sends `address` as street,
  postal code, city and country, which is what HR stores. Names are letters
  only, and the phone number is one HR's tests accept.

### Fixed

- Den's operator and pairing smokes send access tokens. Den refuses ID
  tokens.

### Fixed

- The Tasks smoke sends an access token. Tasks refuses ID tokens.

### Security

- The shared nginx policy still sends `frame-ancestors 'none'` and
  `X-Frame-Options: DENY` on every page except `/silent-callback.html`,
  which allows framing by the app's own origin only (`frame-ancestors
  'self'`, `X-Frame-Options: SAMEORIGIN`). Other sites still cannot embed
  the app.
- Den no longer needs `view-realm`; the dev realm's `den-keycloak` service
  account keeps only `manage-realm`, used for the optional realm name sync.
  Without that sync, Den needs no access to the realm at all.

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
