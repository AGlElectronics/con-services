# Modules

A **module** is one application of the Con Services suite. Each module has
its own repository, its own database and bucket, its own Kubernetes
namespace and its own versioned images. Modules can run on their own
(*standalone*) or paired with [Den](den/index.md), the portal that ties them
together; see [Pairing](../concepts/pairing.md).

Each module has a section here with an overview, a setup page, a
configuration reference and an API reference. Modules with an admin console
also have an admin guide.

| Module | What it does | Docs | API | Source |
| --- | --- | --- | --- | --- |
| Den | Portal, admin console, branding, pairing and backups. | [Den](den/index.md) | [API](den/api.md) | [AGlElectronics/den](https://github.com/AGlElectronics/den) |
| HR | People registry, onboarding and accounts. | [HR](hr/index.md) | [API](hr/api.md) | [AGlElectronics/hr](https://github.com/AGlElectronics/hr) |
| Rally (Events) | Editions, calls for papers, review and the schedule. | [Rally](rally/index.md) | [API](rally/api.md) | [AGlElectronics/Rally](https://github.com/AGlElectronics/Rally) |
| Stash | Inventory, sign-outs and lost and found. | [Stash](stash/index.md) | [API](stash/api.md) | [AGlElectronics/stash](https://github.com/AGlElectronics/stash) |
| Finance | Customers, invoices, payments and expenses. | [Finance](finance/index.md) | [API](finance/api.md) | [AGlElectronics/finance](https://github.com/AGlElectronics/finance) |
| Learn | Courses, quizzes, sessions and qualifications. | [Learn](learn/index.md) | [API](learn/api.md) | [AGlElectronics/learn](https://github.com/AGlElectronics/learn) |
| Wiki | Knowledge base with live editing. | [Wiki](wiki/index.md) | [API](wiki/api.md) | [AGlElectronics/wiki](https://github.com/AGlElectronics/wiki) |
| Desk | Helpdesk on shared mailboxes. | [Desk](desk/index.md) | [API](desk/api.md) | [AGlElectronics/desk](https://github.com/AGlElectronics/desk) |
| Tasks | Task boards for the crew. | [Tasks](tasks/index.md) | [API](tasks/api.md) | [AGlElectronics/tasks](https://github.com/AGlElectronics/tasks) |

## What every module has in common

- **Sign-in** through the organisation's Keycloak realm, with access from
  Keycloak groups. See [Authentication](../concepts/authentication.md).
- **The same API conventions**: the same error format, bearer tokens,
  health endpoints and versioning rules. Every API reference above builds
  on [API conventions](../concepts/api-conventions.md).
- **A role catalog** at `GET /api/role-catalog`, so HR can grant its roles.
- **A Den connection** page for pairing with Den.
- **Isolation**: its own database login, bucket, secrets and network
  policy. See [Design principles](../concepts/design-principles.md).

## Running a module

On Kubernetes every module runs in its own namespace, `conservices-<module>`
(for example `conservices-stash`), from images named
`ghcr.io/aglelectronics/<module>-<component>:MAJOR.MINOR.PATCH-BUILD`.
Ready-made Kustomize manifests exist for Den (`deploy/kubernetes/base/den/`)
and Stash (`deploy/kubernetes/modules/stash/`); the plan for the others is in
[`deploy/kubernetes/modules/README.md`](https://github.com/AGlElectronics/con-services/blob/main/deploy/kubernetes/modules/README.md).
How a module is added to a running installation is described in
[How the platform starts](../getting-started/how-the-platform-starts.md#step-4-deploy-a-module-stash).

How to add or extend a module's section is described in
[Contributing](../contributing/index.md#adding-a-modules-docs).
