# Desk

**Desk** is the shared-inbox helpdesk of Con Services, modelled on
FreeScout. Attendees and partners write to addresses such as
`support@…` or `registration@…`; each address is a **mailbox** in Desk, and
every email thread becomes a **conversation** that staff assign, answer,
annotate and close in the browser. Customers never sign in: to them it is
plain email.

Source: [AGlElectronics/desk](https://github.com/AGlElectronics/desk)

## Goals

Desk exists so that a convention's support email is answered **once, by the
right person, without anyone being left out**. In terms of the platform
conventions that means:

- **Email stays email.** Customers never sign in or learn a new tool; Desk
  speaks plain IMAP and SMTP to the mail servers you already have.
- **No double work.** One assignee per conversation, a 10-second undo,
  collision warnings and folder counts per person make it obvious who is
  handling what.
- **Access through Keycloak groups, like every module.** People get Desk by
  being in `desk-agent` or `desk-admin`; Desk publishes those roles in its
  [role catalog](api.md#get-apirole-catalog) so HR can grant them during
  onboarding.
- **Secrets never leave the backend.** Mailbox passwords are encrypted at
  rest and never returned by the API ([Secrets](../../operations/secrets.md)).
- **API first.** The web app uses only the public HTTP API, which follows
  the shared [API conventions](../../concepts/api-conventions.md): anything
  an agent can click, a script can do.
- **Branded by Den.** Once [paired](../../concepts/pairing.md), Desk shows
  your organisation's name, logo and theme like every other module.

## What Desk does today

- **Mailboxes:** each one has its own IMAP account (incoming) and optionally
  its own SMTP server (outgoing; otherwise a module-wide fallback). Mailbox
  passwords are stored encrypted with `DESK_SECRET_KEY`. A connection test
  logs in to both without changing anything.
- **Fetching:** every `FETCH_INTERVAL` (60 seconds by default) Desk reads
  new mail over IMAP, threads it into the right conversation, and marks it
  read on the server.
- **Conversations:** statuses `active`, `pending` (waiting on the
  customer), `closed` and `spam`; one assignee; folders **Unassigned**,
  **Mine**, **Assigned**, **Pending**, **Closed**, **Spam** with counts;
  search by subject, customer, text or `#number`.
- **Replies and notes:** replies go out with a per-mailbox signature and
  can be **undone for 10 seconds**; failed sends retry after 1, 5, 15 and
  60 minutes, then show a retry button. Internal notes are never emailed.
  Answering an unassigned conversation assigns it to you.
- **Collision warning:** you see who else is viewing or replying to the
  same conversation.
- **Customers:** name and notes, with their other conversations shown next
  to each ticket.
- **Attachments** are stored in the database and downloaded through the
  backend.

Planned, not built yet (see
[docs/plan.md](https://github.com/AGlElectronics/desk/blob/main/docs/plan.md)):
per-mailbox access grants (today every agent sees every mailbox), tags,
saved replies, auto-replies, merge, forward, attachments in S3.

**Who uses it:** support staff in the Keycloak group `desk-agent` answer
conversations; `desk-admin` also creates and edits mailboxes and pairs Desk
with Den.

## How Desk is built

| Part | Technology | Runs as (Kubernetes) |
| --- | --- | --- |
| Backend | Go 1.25, chi, pgx, go-imap v2, go-mail, zerolog | Deployment `desk-backend`, **one replica** |
| Migrations | Goose, SQL embedded in the binary | initContainer `migrate` in `desk-backend` |
| Frontend | React 19, Rsbuild, TanStack Router and Query, Tailwind | Deployment `desk-frontend` (nginx) |
| Database | PostgreSQL 16, database `desk` | everything, including attachments |
| File storage | none yet | |

## Images

| Image | Built from | Contains |
| --- | --- | --- |
| `ghcr.io/aglelectronics/desk-backend:<tag>` | `infra/Dockerfile.backend` | `/server`, port 8080. |
| `ghcr.io/aglelectronics/desk-migrate:<tag>` | `infra/Dockerfile.migrate` | `/migrate`, applies migrations and exits. |
| `ghcr.io/aglelectronics/desk-frontend:<tag>` | `infra/Dockerfile.frontend` | The web app (nginx; port 80 in the image, 8080 in the Helm chart). |

The web app's sign-in address is built into the frontend image; see
[Configuration](configuration.md#frontend-build-settings).

## How Desk fits the platform

Own namespace `conservices-desk`, own Helm chart `deploy/charts/desk`, own
database `desk`. Its network policies let it reach PostgreSQL, Den, the
sign-in server and **your mail servers** (IMAP and SMTP), and let only HR
call it (for the role catalog). It pairs with Den for the brand and
settings ([Pairing](../../concepts/pairing.md)); Den comes first
([How the platform starts](../../getting-started/how-the-platform-starts.md)).

## Ways to run it

| Posture | Use it for | Guide |
| --- | --- | --- |
| **Kubernetes platform** (recommended) | Production, next to Den | [Setup, option 1](setup.md#option-1-kubernetes-platform-recommended) |
| **Standalone on Kubernetes** | Only Desk, your own PostgreSQL and sign-in | [Setup, option 2](setup.md#option-2-standalone-on-kubernetes) |
| **Production on Docker** | One server, no Kubernetes | [Setup, option 3](setup.md#option-3-production-on-docker) |
| **Development on Docker** | Trying it out with test mail servers | [Setup, option 4](setup.md#option-4-development-on-docker) |

The backend always runs **one replica**: it fetches the mailboxes itself.

## In this section

- [Setup](setup.md): install Desk, add the first mailbox.
- [Configuration](configuration.md): every environment variable.
- [API reference](api.md): all 31 HTTP endpoints (mailboxes and their
  IMAP/SMTP settings, conversations, replies and notes, assignment,
  customers, attachments, Den pairing), with permissions, bodies, errors and
  `curl` examples.
