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

### Changed

- Shared Go code: `gworkspace` reports `google workspace is not configured`
  and `google workspace needs …` with a lowercase first letter, like the
  package's other errors.
- Shared Go code: `denlink` error strings now follow Go's convention
  (`ErrRevoked`, `den refused the pairing URL`, `den returned …` — a
  lowercase first letter, no trailing punctuation). The sentence an admin
  sees is unchanged: the API `message` field and `last_error` on the Den
  connection page still say "Den rejected…", "Den refused the pairing URL"
  and "Den returned …" (`denlink.UserMessage`).
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
  needs them added by hand before a module that checks its audience is
  upgraded ([Audiences per API](docs/concepts/authentication.md#audiences-per-api)).
- CI *Chart versions*: a changed chart needs a higher version only once
  its app has a chart release tag `<app>/v*`; before the first release a
  chart may change while staying at its first version.
- [Shared code](docs/concepts/shared-code.md#what-adopting-a-package-involves)
  notes that a module needs an ESLint configuration when its frontend has a
  `lint` script, because the module CI runs `npm run lint`.

### Security

- The shared nginx policy still sends `frame-ancestors 'none'` and
  `X-Frame-Options: DENY` on every page except `/silent-callback.html`,
  which allows framing by the app's own origin only (`frame-ancestors
  'self'`, `X-Frame-Options: SAMEORIGIN`). Other sites still cannot embed
  the app.
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
