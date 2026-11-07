# Design principles

Con Services is built for organisations that run events with volunteers:
small paid teams, large crews that change every year, and tools that have
to work on the weekend when nobody from IT is around. The principles on
this page follow from that. They explain why the suite looks the way it
does, and they are the rules every module, every deployment file and every
contribution is held to.

Each principle says what it is, why, and what it means for you when you
run or extend Con Services. The decisions behind them are recorded as
architecture decision records (ADRs) in
[Den's `docs/adr/`](https://github.com/AGlElectronics/den/tree/main/docs/adr).

## The principles in one list

1. [One login, owned by the organisation](#1-one-login-owned-by-the-organisation)
2. [Den first, modules one by one](#2-den-first-modules-one-by-one)
3. [Every module is isolated](#3-every-module-is-isolated)
4. [Modules talk over APIs, never through each other's data](#4-modules-talk-over-apis-never-through-each-others-data)
5. [Den is the hub, but optional](#5-den-is-the-hub-but-optional)
6. [Kubernetes in production, Compose for development](#6-kubernetes-in-production-compose-for-development)
7. [Secrets live in a secret manager](#7-secrets-live-in-a-secret-manager)
8. [Managed storage and real load balancing at scale](#8-managed-storage-and-real-load-balancing-at-scale)
9. [Pinned, predictable versions](#9-pinned-predictable-versions)
10. [Documentation is part of the change](#10-documentation-is-part-of-the-change)

## 1. One login, owned by the organisation

People sign in to the organisation's **identity provider** (Keycloak by
default), never to a module. Every module, Den included, is one more
application that trusts it through OIDC (OpenID Connect, the standard
"sign in with" protocol). Access comes from **groups** in the identity
provider, and each module turns groups into its own roles on every request.

**Why.** Volunteers come and go. One account per person, switched off in one
place when they leave, is the only way to keep a hundred-person crew safe.
It also means you can swap Keycloak for the provider you already have.

**For you.** Give and take access by changing Keycloak groups (or through
HR, which does it for you). No module has its own password database. See
[Authentication](authentication.md) and
[ADR 0001](https://github.com/AGlElectronics/den/blob/main/docs/adr/0001-idp-first-ecosystem.md).

## 2. Den first, modules one by one

An installation comes up in a fixed order: the shared platform (Gateway,
Keycloak, PostgreSQL, storage), then **Den**, then each module, one at a
time, each in its own namespace and paired with Den before the next one
starts.

**Why.** Den creates each module's database through its operator, holds the
brand every module follows and is where you check that a module works.
Bringing modules up one by one means a failure always has one obvious
suspect.

**For you.** Follow
[How the platform starts](../getting-started/how-the-platform-starts.md).
Do not deploy everything at once and debug the result.

## 3. Every module is isolated

Each module gets its own:

| Resource | Example for Stash | Enforced by |
| --- | --- | --- |
| **Namespace** | `conservices-stash` | Kubernetes |
| **Database and login** | database `stash`, login `stash`, which cannot connect to any other database | PostgreSQL grants, set up by Den's operator |
| **Bucket** | `stash` | Separate storage credentials per module |
| **Network policy** | deny all, then allow only the listed flows | The CNI (Cilium recommended) |
| **Secrets** | `stash-secrets` in `conservices-stash` | Kubernetes RBAC and namespaces |
| **Images** | `ghcr.io/aglelectronics/stash-backend:1.0.0-1` | Separate repository and release |

**Why.** A bug, a leaked password or a compromised container in one module
must not become a problem for all of them. Your finance data should not be
one SQL query away from the volunteer task board.

**For you.** Expect to configure each module separately, and expect calls
that are not explicitly allowed to fail. See
[Network policies and isolation](../operations/network-policies.md) and
[Databases, backups and restore](../operations/databases-and-backups.md).

## 4. Modules talk over APIs, never through each other's data

When one module needs something from another, it calls that module's HTTP
API with its own credential. It never reads another module's tables or
bucket. **There is no shared PostgreSQL database**: several module databases
may live on one PostgreSQL *server*, but each has its own login that cannot
see the others.

**Why.** A database is an implementation detail. As soon as two modules
share tables, neither can change without breaking the other, and the
isolation of principle 3 is gone. APIs can be versioned, documented and
protected; tables cannot.

**For you.** Integrations are listed, small and explicit: HR reading role
catalogs, HR telling Learn, Wiki and Tasks about people and departments,
modules pulling the brand from Den. Each one is a row in the network policy
flow table and is described in [API conventions](api-conventions.md#calls-between-modules).
See [ADR 0005](https://github.com/AGlElectronics/den/blob/main/docs/adr/0005-no-shared-postgres.md)
and [ADR 0004](https://github.com/AGlElectronics/den/blob/main/docs/adr/0004-one-bucket-per-module.md).

## 5. Den is the hub, but optional

Den holds what belongs to the organisation rather than to one module: the
brand, the organisation settings, the list of modules, each person's theme
and the suite's backups. Modules **pair** with Den and follow it. A module
that is not paired is **standalone**: it works on its own, with its own
settings and look.

**Why.** A small team that only needs inventory should be able to run just
Stash. A full convention wants one portal, one look and one place for
settings. The same module serves both.

**For you.** You can start with one module and add Den later. A paired
module keeps working, on its last known brand, if Den is down. See
[Pairing](pairing.md) and
[ADR 0002](https://github.com/AGlElectronics/den/blob/main/docs/adr/0002-pairing-url-and-token.md).

## 6. Kubernetes in production, Compose for development

Con Services is deployed on **Kubernetes** from published images. A
production cluster is managed with **Argo CD** from a Git repository
(GitOps), which installs Den and the modules with the Helm charts in
`deploy/charts/`. The Kustomize manifests in `deploy/kubernetes/` run the
same images on a local cluster, for trials. Docker Compose builds
everything from source and is the **development** path. For a single server
without Kubernetes there is a documented Docker production path.

**Why.** Kubernetes gives the suite what isolation needs: namespaces,
network policies, Pod Security, restarts and rolling upgrades. GitOps makes
every change to a production cluster a reviewed commit that can be undone.
Compose is the fastest way to work on the code.

**For you.** Pick one of the five ways to run it in
[Getting started](../getting-started/index.md#choose-your-path); for
production that is [Deploy with Argo CD](../deploy/index.md), and the local
Kubernetes path is for trials. Every change to a service, setting, port,
probe or secret updates the manifests, the charts, `docker-compose.yml` and
the docs together.

## 7. Secrets live in a secret manager

Anything beyond a local trial keeps its secrets (database passwords, storage
keys, service tokens, the operator token, OIDC client secrets) in a **secret
manager**: the External Secrets Operator with your provider, Sealed Secrets
or SOPS. Plain Kubernetes Secrets in Git and `.env` files are for
development only, and their values are public test values such as
`change-me`.

**Why.** Secrets in a repository are leaked secrets. A secret manager also
gives you rotation and an audit trail.

**For you.** Start from the inventory on [Secrets](../operations/secrets.md):
it lists every secret, where it lives, who uses it and how to rotate it.

## 8. Managed storage and real load balancing at scale

The in-cluster PostgreSQL and S3 server (SeaweedFS) are there so a trial
works out of the box. A production installation:

- stores files in a **managed S3 service**. Any S3-compatible service
  works, for example AWS S3, Hetzner Object Storage, Cloudflare R2 or
  Backblaze B2. Object storage inside the cluster (SeaweedFS, MinIO,
  Garage) is not for production (the bundled S3 server is
  [development only](https://github.com/AGlElectronics/den/blob/main/docs/adr/0003-minio-dev-only.md));
- uses **managed PostgreSQL**, or PostgreSQL with failover that you
  operate (CloudNativePG) with backups and monitoring;
- runs **Cilium** as its network plugin, which enforces the network
  policies;
- brings traffic in through a **Gateway** ([Gateway API](glossary.md#gateway-api))
  with a load-balancer address (Cilium LB IPAM, or your cloud's load
  balancer), spread over several nodes.

**Why.** Your attendees' data has to survive a broken disk, and the
schedule has to load when two thousand people open it at the same time.

**For you.** Follow [Production and security](../operations/production.md#the-production-shape).

## 9. Pinned, predictable versions

Every image has an exact tag, `MAJOR.MINOR.PATCH-BUILD`, for example
`den-backend:1.4.2-3`. All images of one module share a tag. `BUILD` counts
rebuilds of the same version and starts at `1` for each new version.
Nothing ever uses `latest`: manifests, charts and docs all pin exact tags.
A change that needs action on upgrade bumps `MAJOR` and comes with a
**BREAKING:** changelog entry that says what to do.

**Why.** You must know exactly what is running, be able to roll back to it,
and never be surprised by an upgrade in the middle of an event.

**For you.** See [Versions and upgrades](../operations/versioning.md). The
same rules apply to APIs; see
[API conventions → Versioning](api-conventions.md#versioning).

## 10. Documentation is part of the change

Con Services is open source, and its operators are often volunteers.
A change is only done when its docs are: the guide that describes the
behaviour, every API change (method, path, who may call it, request,
response, errors and a `curl` example), every new setting in the
configuration table and `.env.example`, and a changelog entry written for
operators.

**Why.** Software nobody can set up does not help anyone.

**For you.** If the docs and the behaviour disagree, that is a bug; please
report it. Contributors, see [Contributing](../contributing/index.md).

## What Con Services is not

Knowing the edges helps you plan:

- **Not a ticketing or payment platform.** Finance tracks invoices,
  payments and expenses; selling tickets stays with a dedicated provider.
- **Not a chat or video tool.** Staff communication stays in the tools your
  crew already uses; see the
  [Staff communications proposal](../proposals/staff-communications.md).
- **Not a hosted product — yet, and not the goal.** The design centre is that
  the convention owns its data and runs the suite itself (or has someone run
  it on infrastructure the convention controls). A managed hosting option is
  not what we are building first. If enough conventions ask for one later, we
  may offer it; that would be an extra way to run the same software, not a
  replacement for self-hosting.
