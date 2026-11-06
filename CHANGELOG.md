# Changelog

All notable changes to the Con Services suite (the Kubernetes manifests and
Helm charts, the shared Docker stack, Keycloak realm, proxy, scripts and
documentation) are documented in this file. Each module keeps its own
changelog in its repository.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

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
  `conservices-identity`, PostgreSQL and MinIO in `conservices-data` (for
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

### Changed

- Wiki, Desk, Learn and Tasks moved into their own repositories.
- Con Services is now documented and released for Kubernetes with
  published images. The Docker Compose stack is the contributor development
  path.
- The databases, backups and restore guide moved from `docs/operations.md`
  to the documentation site (Operations → Databases, backups and restore)
  and was adapted to Kubernetes. The old file was removed.

### Fixed

- The local DNS setup only touches its own, named proxy certificate.
- Shell scripts and the Caddyfile keep LF line endings on Windows.
