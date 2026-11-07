# Con Services

**Con Services is a self-hosted suite of tools for running a convention.**
Volunteers and staff, events and the programme, inventory, training,
finance, a helpdesk, a wiki and task boards: one suite, on your own
servers, with one sign-in and your convention's name, logo and colours on
every screen.

## Who it is for

Con Services is for **conventions and other volunteer-run events**: fan
conventions, festivals, conferences, meet-ups. These are organisations
where a small core team and a large, changing crew of volunteers put on an
event once or a few times a year, and where IT is often one or two people
doing it in their spare time.

## The problem

Most events end up running on a patchwork:

- **Scattered tools.** A form builder for volunteer applications, a
  spreadsheet for the schedule, another for the inventory, a shared drive
  for the handbook, a separate helpdesk, a chat group for everything else.
- **Scattered accounts.** Every tool has its own users and passwords. When a
  volunteer leaves, nobody is sure which accounts they still have.
- **Scattered brands.** Every tool looks different, and attendees cannot
  tell the official schedule from a screenshot someone posted.
- **Scattered data.** Who did which training, who signed out which radio,
  who presented what last year: spread over tools that do not know about
  each other, and often hosted by companies on the other side of the world.

## The solution

Con Services replaces the patchwork with one suite you run yourself:

- **The convention owns the data.** You run Con Services on infrastructure
  you control (Kubernetes or a hardened Docker host). That is the goal:
  attendee and volunteer data stays with the con. A managed hosted option is
  not the initial product; if many conventions ask for one later, it may
  appear as another way to run the same suite.
- **One login.** Everyone signs in once, through one identity provider
  (Keycloak by default, or the one you already have) using OIDC, the
  standard "sign in with" protocol. Removing someone from a group takes
  their access away everywhere.
- **One hub.** **Den** is the portal and admin console. It lists every
  service a person can open, holds the brand and organisation settings,
  and backs up the whole suite.
- **Isolated modules that talk over APIs.** Every tool is a separate
  **module** with its own database, its own file storage, its own namespace
  and its own source repository. Modules exchange only what they must,
  through documented HTTP APIs. Run one module on its own, or all of them
  together with Den.

## Design principles

1. **One login, owned by the organisation.** Access comes from groups in
   your identity provider, never from per-app passwords.
2. **Den first, then modules one by one**, each paired with Den.
3. **Every module is isolated**: its own namespace, database, bucket and
   network policy.
4. **APIs, never shared databases.** Modules call each other over HTTP;
   there is no shared PostgreSQL database.
5. **Secrets live in a secret manager** in every real installation.
6. **Production grade at scale**: Cilium for network policy and the
   Gateway in front, managed S3 storage (any S3-compatible service works:
   AWS S3, Hetzner Object Storage, Cloudflare R2, Backblaze B2, ...).
7. **Pinned versions**: every image tag is an exact
   `MAJOR.MINOR.PATCH-BUILD`, never `latest`.

[Read the design principles in full](concepts/design-principles.md).

## The modules

| Module | What it does | Docs | Source |
| --- | --- | --- | --- |
| **Den** | The portal and admin console: sign-in, the list of services people can open, pairing of modules, branding, organisation settings and backups. | [Den](modules/den/index.md) | [AGlElectronics/den](https://github.com/AGlElectronics/den) |
| **HR** | The people registry: applications, onboarding of volunteers and staff, departments, and creating their sign-in accounts. | [HR](modules/hr/index.md) | [AGlElectronics/hr](https://github.com/AGlElectronics/hr) |
| **Rally** (Events) | Conventions and events: editions, calls for papers, the public submission site, review, the schedule builder and the public schedule. | [Rally](modules/rally/index.md) | [AGlElectronics/Rally](https://github.com/AGlElectronics/Rally) |
| **Stash** | Inventory: items, locations, departments, sign-outs and lost and found, with a full audit trail. | [Stash](modules/stash/index.md) | [AGlElectronics/stash](https://github.com/AGlElectronics/stash) |
| **Finance** | Customers, outgoing invoices, payments, expenses and a running ledger. | [Finance](modules/finance/index.md) | [AGlElectronics/finance](https://github.com/AGlElectronics/finance) |
| **Learn** | Training: courses, quizzes, in-person sessions, qualifications and certificates. | [Learn](modules/learn/index.md) | [AGlElectronics/learn](https://github.com/AGlElectronics/learn) |
| **Wiki** | A knowledge base with pages in private and team spaces, edited live by several people at once. | [Wiki](modules/wiki/index.md) | [AGlElectronics/wiki](https://github.com/AGlElectronics/wiki) |
| **Desk** | A helpdesk that works from shared mailboxes. | [Desk](modules/desk/index.md) | [AGlElectronics/desk](https://github.com/AGlElectronics/desk) |
| **Tasks** | Task boards for the crew. | [Tasks](modules/tasks/index.md) | [AGlElectronics/tasks](https://github.com/AGlElectronics/tasks) |

Every module is published as versioned container images
(`ghcr.io/aglelectronics/<module>-<component>:MAJOR.MINOR.PATCH-BUILD`).
The pieces that hold the suite together (Kubernetes manifests and Helm
charts, the Keycloak sign-in configuration, the development stack, scripts
and this documentation) live in the
[con-services](https://github.com/AGlElectronics/con-services) repository.

## Ways to run it

| You want to… | Path | Start here |
| --- | --- | --- |
| Run the **whole suite in production** | **Production cluster with Argo CD** (recommended) | [Deploy with Argo CD](deploy/index.md): k3s, Cilium, Longhorn, OpenBao, PostgreSQL with failover, managed S3, highly available |
| **Try the whole suite** on a local cluster | **Full platform on Kubernetes** | [How the platform starts](getting-started/how-the-platform-starts.md), then [Run Den on Kubernetes](getting-started/den-quickstart.md) |
| Run **one module** without Den | **Standalone module on Kubernetes** | [Run one module on Kubernetes](getting-started/standalone-kubernetes.md) |
| Run the suite on **one server without Kubernetes** | **Full stack on Docker** | [Full stack on Docker](operations/docker-production.md) |
| **Work on the code** | **Docker Compose for development** | [Local development](contributing/local-development.md) |

!!! tip "Read this first: How the platform starts"
    Con Services comes up in a fixed order: **Den first**, then each module,
    one at a time, in its own namespace and paired with Den.
    [How the platform starts](getting-started/how-the-platform-starts.md)
    explains the sequence and which steps are automatic today.

## Where to start

<div class="grid cards" markdown>

-   **New here?**

    Follow [Run Den on Kubernetes](getting-started/den-quickstart.md). It
    takes you from an empty computer to a working Den on a local cluster
    that you can sign in to.

-   **Planning a production installation?**

    Follow [Deploy with Argo CD](deploy/index.md), the tested reference
    setup. Background: [How the platform starts](getting-started/how-the-platform-starts.md),
    [High availability](deploy/high-availability.md),
    [Running on Kubernetes](operations/running.md),
    [Secrets](operations/secrets.md) and
    [Production and security](operations/production.md).

-   **Want to understand how it fits together?**

    Read the [Design principles](concepts/design-principles.md) and
    [Architecture](concepts/architecture.md), then
    [Authentication](concepts/authentication.md) and
    [Pairing](concepts/pairing.md).

-   **Building against the APIs?**

    Start with [API conventions](concepts/api-conventions.md): addresses,
    tokens, errors and health checks shared by every module. Then open the
    module's API reference, for example the
    [Den API reference](modules/den/api.md).

</div>

## Status and roadmap

Con Services is being prepared for its first open-source release. All nine
modules exist and are used together on a development installation; every
module has its own section here with an overview, setup, configuration and
API reference.

Be aware of where things stand:

- **Helm charts** exist for Den and every module in `deploy/charts/`; the
  [GitOps reference repository](https://github.com/AGlElectronics/con-services-gitops)
  installs them with Argo CD. **Kustomize manifests** are complete for Den
  and Stash. See
  [`deploy/kubernetes/modules/README.md`](https://github.com/AGlElectronics/con-services/blob/main/deploy/kubernetes/modules/README.md).
- **Some bring-up steps are manual today**, such as pairing a module with
  Den. [How the platform starts](getting-started/how-the-platform-starts.md)
  marks which.
- **APIs are not fully uniform yet.** A few older modules have no `/v1` in
  their paths; [API conventions](concepts/api-conventions.md) lists the
  differences.
- **Designs that are agreed but not built** live under
  [Proposals](proposals/index.md).

Contributions are welcome: code, documentation, and reports from people
running real events. See [Contributing](contributing/index.md).
