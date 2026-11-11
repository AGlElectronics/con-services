# Finance

**Finance** is the money module of Con Services: customers, outgoing
invoices with PDFs, credit notes and refunds, payments, expenses, a running
ledger, closed months, four-eyes approval and an audit log. There is no
bank connection yet, so payments and expenses are typed in by hand.

Source: [AGlElectronics/finance](https://github.com/AGlElectronics/finance)

## Goals

Finance exists so a convention **knows what it is owed, what it has
received and what it has spent**, with invoices it can stand behind. In
terms of the platform conventions that means:

- **Records you cannot quietly change.** Issued invoices are numbered
  without gaps (`FIN-0001`), keep a frozen copy of the customer and seller
  details, and have a PDF stored once with its SHA-256. Paid invoices are
  never voided: mistakes are corrected with credit notes (`FIN-CN-0001`) and
  refunds. Expenses are soft-deleted. Closed months cannot change. Every
  change and its audit event are written in one transaction.
- **Two people for money.** Voids, payments, expenses, credit notes and
  refunds above a threshold (default: all of them) wait until a second
  person approves them.
- **Exact money.** All amounts are whole cents with per-line rounding and
  bounded inputs, so totals never drift from what was invoiced.
- **Least privilege.** Four roles (bookkeeper, approver, read-only, admin),
  published in the [role catalog](api.md#get-apirole-catalog) for HR to
  grant and checked on every route.
- **API first.** The web app uses only the public HTTP API, which follows
  the shared [API conventions](../../concepts/api-conventions.md); unlike
  most modules its routes sit under `/api/` without `/v1`.
- **Branded by Den.** Once [paired](../../concepts/pairing.md), Finance
  shows your organisation's name, logo and theme like every other module,
  and takes the seller details from Den's Module settings.
- **Honest about scope.** No bank feed yet; one currency per installation;
  the money defaults are pending review by an accountant.

## What Finance does

- **Customers:** name, email, billing address, tax id, notes. Customers
  with invoices are archived instead of deleted.
- **Invoices:** drafts with lines (quantity, unit price, tax rate), then
  **issue**, which takes the next gap-free number, freezes customer and
  seller and stores the PDF. Status `partial`, `paid` and `credited` follow
  from payments and credit notes; **overdue** is a flag on issued invoices
  past their due date. Only an unpaid invoice without credit notes can be
  **voided**.
- **Credit notes and refunds:** correct an issued invoice in full or in
  part, and pay back what a customer paid too much.
- **Payments:** date, amount, method (`bank_transfer`, `cash`, `card`,
  `other`), reference; never more than what is still owed.
- **Expenses:** money going out, by category (`venue`, `equipment`,
  `travel`, `supplies`, `services`, `fees`, `other`).
- **Ledger:** payments, refunds and expenses as one stream with a running
  balance.
- **Approvals:** the requests waiting for a second person.
- **Closed months:** an approver closes a month; only an admin reopens it.
- **Dashboard:** outstanding, overdue, received and spent this month and in
  total, six months of money in and out, recent invoices, waiting approvals.
- **Audit log:** every change, who made it and the values before and after.

All amounts are whole **cents** in one currency per installation
(`FINANCE_CURRENCY`, default EUR); tax rates are in basis points (21% is
`2100`). Details:
[docs/domain-model.md](https://github.com/AGlElectronics/finance/blob/main/docs/domain-model.md).

**Who uses it:** people with a Finance role. Bookkeepers keep the books,
approvers approve and close months, read-only users (accountants,
auditors) look, admins do everything. Anyone else who signs in sees "you
don't have access to Finance". See [Roles](configuration.md#roles).

## How Finance is built

| Part | Technology | Runs as (Kubernetes) |
| --- | --- | --- |
| Backend | Go 1.27, chi, pgx, zerolog; PDFs rendered in Go | Deployment `finance-backend` |
| Migrations | Goose, SQL embedded in the binary | initContainer `migrate` in `finance-backend` |
| Frontend | React 19, Rsbuild, TanStack Router and Query, Tailwind | Deployment `finance-frontend` (nginx) |
| Database | PostgreSQL 16, database `finance` | shared server, or your own |
| File storage | S3-compatible bucket for the PDFs of issued invoices and credit notes | Garage on the platform, or a managed S3 |

## Images

| Image | Built from | Contains |
| --- | --- | --- |
| `ghcr.io/aglelectronics/finance-backend:<tag>` | `infra/Dockerfile.backend` | `/server`, port 8080. |
| `ghcr.io/aglelectronics/finance-migrate:<tag>` | `infra/Dockerfile.migrate` | `/migrate`, applies migrations and exits. |
| `ghcr.io/aglelectronics/finance-frontend:<tag>` | `infra/Dockerfile.frontend` | The web app (nginx, non-root as UID 101, port 8080). |

The frontend image names no domain: the web app reads its sign-in address
from `/config.json`; see
[Web app settings](configuration.md#web-app-settings-configjson).

## How Finance fits the platform

Own namespace `conservices-finance`, own Helm chart `deploy/charts/finance`,
own database `finance` and bucket. Its network policies let it reach only
PostgreSQL, S3, Den and the sign-in server, and let only HR call it (role
catalog). It pairs with Den for the brand and the seller details
([Pairing](../../concepts/pairing.md)); Den comes first
([How the platform starts](../../getting-started/how-the-platform-starts.md)).

!!! warning "Invoices are legal records"
    Invoices usually have legal retention periods. Make sure the `finance`
    database **and** the PDF bucket are in Den's nightly backups (the bucket
    in Den's `FILES_S3_BUCKETS`), or back them up yourself when Finance runs
    standalone.

## Ways to run it

| Posture | Use it for | Guide |
| --- | --- | --- |
| **Production cluster with Argo CD** (recommended for production) | Production: Den, Keycloak and every module on a cluster managed from Git | [Den and the modules](../../deploy/apps.md) |
| **Kubernetes platform** | A cluster you run yourself, next to Den; also the local trial cluster | [Setup, option 1](setup.md#option-1-kubernetes-platform-recommended) |
| **Standalone on Kubernetes** | Only Finance | [Setup, option 2](setup.md#option-2-standalone-on-kubernetes) |
| **Production on Docker** | One server, no Kubernetes | [Setup, option 3](setup.md#option-3-production-on-docker) |
| **Development on Docker** | Trying it out | [Setup, option 4](setup.md#option-4-development-on-docker) |

A local Kubernetes cluster (the [quickstart](../../getting-started/den-quickstart.md)) is for trials only; production installations use the Argo CD path.

## In this section

- [Setup](setup.md): install Finance in each of the five ways.
- [Configuration](configuration.md): every environment variable, the roles
  and where the seller details come from.
- [Bookkeeping](bookkeeping.md): issuing, correcting, approving and
  closing months, step by step.
- [API reference](api.md): all 48 HTTP endpoints, with permissions, bodies,
  errors and `curl` examples.
