# Finance

**Finance** is the money module of Con Services: customers, outgoing
invoices, payments, expenses, a running ledger and a dashboard of cash
versus what is still owed. It is a **proof of concept**: there is no bank
connection yet, so payments and expenses are typed in by hand.

Source: [AGlElectronics/finance](https://github.com/AGlElectronics/finance)

## Goals

Finance exists so a convention **knows what it is owed, what it has
received and what it has spent**, with invoices it can stand behind. In
terms of the platform conventions that means:

- **Records you cannot quietly change.** Issued invoices are locked and
  numbered without gaps (`FIN-0001`); they are voided, never deleted, and
  every change is written to an audit log.
- **Exact money.** All amounts are whole cents with per-line rounding, so
  totals never drift from what was invoiced.
- **Few people, full access.** One access group (`finance-admin`, published
  in the [role catalog](api.md#get-apirole-catalog) for HR to grant);
  everyone else is told plainly they have no access.
- **API first.** The web app uses only the public HTTP API, which follows
  the shared [API conventions](../../concepts/api-conventions.md); unlike
  most modules its routes sit under `/api/` without `/v1`.
- **Branded by Den.** Once [paired](../../concepts/pairing.md), Finance
  shows your organisation's name, logo and theme like every other module.
- **Honest about scope.** This is a proof of concept: no bank feed, no PDF
  invoices yet, one currency (EUR).

## What Finance does

- **Customers:** name, email, billing address, tax id, notes. Customers
  with invoices are archived instead of deleted.
- **Invoices:** drafts with lines (quantity, unit price, tax rate), then
  **issue**, which takes the next gap-free number (`FIN-0001`) and locks
  the lines; **void** an issued invoice (the number stays taken). Status
  `partial` and `paid` follow from recorded payments; **overdue** is a flag
  on issued invoices past their due date.
- **Payments:** date, amount, method (`bank_transfer`, `cash`, `card`,
  `other`), reference; never more than what is still owed.
- **Expenses:** money going out, by category (`venue`, `equipment`,
  `travel`, `supplies`, `services`, `fees`, `other`).
- **Ledger:** payments and expenses as one stream with a running balance.
- **Dashboard:** outstanding, overdue, received and spent this month and in
  total, six months of money in and out, recent invoices.
- **Audit log** of every change, in the database.

All amounts are whole **cents** in one currency, **EUR**; tax rates are in
basis points (21% is `2100`). Details:
[docs/domain-model.md](https://github.com/AGlElectronics/finance/blob/main/docs/domain-model.md).

**Who uses it:** only people in a group listed in `FINANCE_ACCESS_GROUPS`
(default `finance-admin`); they have full access. Anyone else who signs in
sees "you don't have access to Finance".

## How Finance is built

| Part | Technology | Runs as (Kubernetes) |
| --- | --- | --- |
| Backend | Go 1.25, chi, pgx, zerolog | Deployment `finance-backend` |
| Migrations | Goose, SQL embedded in the binary | initContainer `migrate` in `finance-backend` |
| Frontend | React 19, Rsbuild, TanStack Router and Query, Tailwind | Deployment `finance-frontend` (nginx) |
| Database | PostgreSQL 16, database `finance` | shared server, or your own |
| File storage | none (the `S3_*` settings are reserved for invoice PDFs later) | |

## Images

| Image | Built from | Contains |
| --- | --- | --- |
| `ghcr.io/aglelectronics/finance-backend:<tag>` | `infra/Dockerfile.backend` | `/server`, port 8080. |
| `ghcr.io/aglelectronics/finance-migrate:<tag>` | `infra/Dockerfile.migrate` | `/migrate`, applies migrations and exits. |
| `ghcr.io/aglelectronics/finance-frontend:<tag>` | `infra/Dockerfile.frontend` | The web app (nginx; port 80 in the image, 8080 in the Helm chart). |

The web app's sign-in address is built into the frontend image; see
[Configuration](configuration.md#frontend-build-settings).

## How Finance fits the platform

Own namespace `conservices-finance`, own Helm chart `deploy/charts/finance`,
own database `finance`. Its network policies let it reach only PostgreSQL,
Den and the sign-in server, and let only HR call it (role catalog). It pairs
with Den for the brand ([Pairing](../../concepts/pairing.md)); Den comes
first ([How the platform starts](../../getting-started/how-the-platform-starts.md)).

!!! warning "Invoices are legal records"
    Invoices usually have legal retention periods. Make sure the `finance`
    database is in Den's nightly backups, or back it up yourself when Finance
    runs standalone.

## Ways to run it

| Posture | Use it for | Guide |
| --- | --- | --- |
| **Kubernetes platform** (recommended) | Production, next to Den | [Setup, option 1](setup.md#option-1-kubernetes-platform-recommended) |
| **Standalone on Kubernetes** | Only Finance | [Setup, option 2](setup.md#option-2-standalone-on-kubernetes) |
| **Production on Docker** | One server, no Kubernetes | [Setup, option 3](setup.md#option-3-production-on-docker) |
| **Development on Docker** | Trying it out | [Setup, option 4](setup.md#option-4-development-on-docker) |

## In this section

- [Setup](setup.md): install Finance in each of the four ways.
- [Configuration](configuration.md): every environment variable.
- [API reference](api.md): all 32 HTTP endpoints (customers, invoices,
  payments, expenses, ledger, dashboard, Den pairing), with bodies, errors
  and `curl` examples.
