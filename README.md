# Con Services

**Self-hosted tools for running a convention** — volunteers and staff, programme and events, inventory, training, finance, helpdesk, wiki and task boards. One sign-in, your brand on every screen, and the convention owns its data.

This repository holds the **shared suite**: documentation, Kubernetes / Helm deploy pieces, the local Docker Compose stack, and Keycloak / proxy / Postgres helpers. Each product module lives in its own repository under [AGlElectronics](https://github.com/AGlElectronics).

---

## Documentation

**Start here:** [https://aglelectronics.github.io/con-services/](https://aglelectronics.github.io/con-services/)

| Section | What you’ll find |
| --- | --- |
| [Getting started](https://aglelectronics.github.io/con-services/getting-started/) | Choose Kubernetes (full or one module), hardened Docker, or this Compose stack for development |
| [How the platform starts](https://aglelectronics.github.io/con-services/getting-started/how-the-platform-starts/) | Den first, then connect storage and database, then add modules |
| [Concepts](https://aglelectronics.github.io/con-services/concepts/) | Architecture, authentication, pairing, API conventions, glossary |
| [Modules](https://aglelectronics.github.io/con-services/modules/) | Setup, configuration and full API reference for every module |
| [Operations](https://aglelectronics.github.io/con-services/operations/) | Helm, secrets, network policies, backups, production hardening |
| [Contributing](https://aglelectronics.github.io/con-services/contributing/) | How we write docs and changelogs |

Sources live in [`docs/`](docs/). Changes are listed in [`CHANGELOG.md`](CHANGELOG.md).

---

## Modules

| Module | Role | Source |
| --- | --- | --- |
| **Den** | Portal, admin console, pairing, branding, backups | [den](https://github.com/AGlElectronics/den) |
| **HR** | People, onboarding, departments, Keycloak accounts | [hr](https://github.com/AGlElectronics/hr) |
| **Rally** | Events, CfP, review, schedule, public programme API | [Rally](https://github.com/AGlElectronics/Rally) |
| **Stash** | Inventory, locations, sign-outs, lost & found | [stash](https://github.com/AGlElectronics/stash) |
| **Finance** | Customers, invoices, expenses, ledger | [finance](https://github.com/AGlElectronics/finance) |
| **Learn** | Courses, quizzes, qualifications | [learn](https://github.com/AGlElectronics/learn) |
| **Wiki** | Spaces, live editing, databases, share links | [wiki](https://github.com/AGlElectronics/wiki) |
| **Desk** | Shared-mailbox helpdesk | [desk](https://github.com/AGlElectronics/desk) |
| **Tasks** | Crew task boards | [tasks](https://github.com/AGlElectronics/tasks) |

Modules are isolated (own database, bucket, namespace). They talk over HTTP APIs only — never a shared application database.

---

## Deploy

Production is **Kubernetes-first**: one namespace per service, NetworkPolicies, pinned image tags `MAJOR.MINOR.PATCH-BUILD`, and a secret manager (not plain Secrets) beyond local trials.

```text
deploy/kubernetes/   reference Kustomize (Den + shared data/identity + Stash example)
deploy/charts/       one Helm chart per module (stubs → production-ready over time)
```

Prefer **Cilium** as CNI, a **load balancer** in front of ingress for large installs, and **AWS S3 or Hetzner Object Storage** instead of in-cluster MinIO.

Full procedures: [Operations](https://aglelectronics.github.io/con-services/operations/) · [Production](https://aglelectronics.github.io/con-services/operations/production/).

---

## Local development (Docker Compose)

This Compose file is the **quick local stack**. It uses well-known development passwords and builds from source. **Do not use it for real attendee or volunteer data.**

### Start

```powershell
# Docker Desktop must be running
docker compose --profile den --profile events --profile learn --profile desk --profile tasks --profile wiki up --build -d
```

Without extra profiles you get Postgres, MinIO, Keycloak, Stash, HR and Finance. First boot can take several minutes (image builds + Keycloak realm import).

### HTTPS hostnames (optional)

With the Caddy proxy and [`scripts/setup-local-dns.ps1`](scripts/setup-local-dns.ps1) (elevated PowerShell once):

| App | URL |
| --- | --- |
| Den | https://den.conservices.test |
| HR | https://hr.conservices.test |
| Stash | https://stash.conservices.test |
| Events (Rally) | https://events.conservices.test |
| Learn | https://learn.conservices.test |
| Desk | https://desk.conservices.test |
| Tasks | https://tasks.conservices.test |
| Wiki | https://wiki.conservices.test |
| Finance | https://finance.conservices.test |
| Keycloak | https://auth.conservices.test |

Direct `localhost` ports still work; sign-in always goes through `auth.conservices.test` when you use the proxy.

### Development sign-in

| Who | Password | Notes |
| --- | --- | --- |
| Keycloak console `admin` | `admin` | http://localhost:8085 — **dev only** |
| App user `admin` | `adminadmin` | Broad admin groups across modules |
| `alice` / `bob` | `alicealice` / `bobbob` | Narrower roles for testing |

Postgres (`postgres` / `postgres`), MinIO (`conservices` / `conservicesdev`) and every `*-dev-*` token in Compose are **local defaults**. Treat them as public examples.

More detail (ports, smoke scripts, pairing, backups): [Local development](https://aglelectronics.github.io/con-services/contributing/local-development/).

### Stop

```powershell
docker compose down
# wipe volumes (fresh databases / MinIO):
docker compose down -v
```

---

## Repository layout

```text
docs/                 MkDocs site (published to GitHub Pages)
deploy/               Kubernetes manifests and Helm charts
infra/                Keycloak realm/theme, Caddy, Postgres/MinIO helpers
scripts/              Smoke tests and local DNS setup
docker-compose.yml    Development stack
```

Module source checkouts (`den/`, `hr/`, `Rally/`, …) are separate git repositories and are ignored here so this repo stays the suite umbrella.

---

## Contributing

See [Contributing](https://aglelectronics.github.io/con-services/contributing/) and [Documentation standards](https://aglelectronics.github.io/con-services/contributing/documentation-standards/) (docs, changelogs, secrets, and what “open-source ready” means for these repos).

### Use of AI tools

We may use AI assistants to speed up routine development and to help draft or polish documentation. **AI is never used for security-sensitive work**: threat models, access control and auth design, secret handling, cryptography, dependency or vulnerability triage, production incident response, or reviewing security-critical changes. Those stay with people who understand the system. AI output is always reviewed before it lands in the tree.

---

## License

License to be confirmed before a formal public release. Until then, treat the code as source-available for evaluation and contribution under the organisation’s direction.
