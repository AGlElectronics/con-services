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

- **Email stays email.** Customers never sign in or learn a new tool. The
  mailboxes live in **Google Workspace** (Desk creates them there), or on
  any mail server that speaks IMAP and SMTP.
- **No double work.** One assignee per conversation, a 10-second undo,
  collision warnings and folder counts per person make it obvious who is
  handling what.
- **Access per mailbox, through Keycloak groups.** Every mailbox publishes
  three roles (viewer, manager, delete) in Desk's
  [role catalog](api.md#get-apirole-catalog), so HR grants "registration
  staff may answer registration@" during onboarding. See [Access](access.md).
- **Nothing is lost by a misclick.** Deleted emails, conversations and
  mailboxes go to a trash first and are purged after 30 days; every delete
  is in the audit log.
- **Secrets never leave the backend.** Mailbox passwords are encrypted at
  rest with a rotatable key and never returned by the API
  ([Secrets](../../operations/secrets.md)).
- **API first.** The web app uses only the public HTTP API, which follows
  the shared [API conventions](../../concepts/api-conventions.md): anything
  an agent can click, a script can do.
- **Branded by Den.** Once [paired](../../concepts/pairing.md), Desk shows
  your organisation's name, logo and theme like every other module.

## What Desk does

- **Mailboxes in Google Workspace.** A Desk admin types a name and an
  address; Desk creates the mailbox in Google, either as its own licensed
  user or as a free group delivered into one shared account. See
  [Google Workspace setup](google-workspace.md).
- **Mailboxes on any IMAP/SMTP server**, for installations without
  Workspace. See [IMAP and SMTP mailboxes](imap.md).
- **Fetching:** every `FETCH_INTERVAL` (60 seconds by default) Desk imports
  new mail, threads it into the right conversation, and marks it at the
  source (Gmail label `Desk`, or IMAP `\Seen` with an optional move to a
  folder). Attachments and the original message go to S3.
- **Conversations:** statuses `active`, `pending` (waiting on the
  customer), `closed` and `spam`; one assignee; tags and stars; folders
  **Unassigned**, **Mine**, **Assigned**, **Pending**, **Closed**, **Spam**,
  **All**, **Starred** and **Trash** with counts; search by subject,
  customer, text or `#number`.
- **Replies and notes** with a rich text editor, reply-all with editable
  CC, a per-mailbox signature, saved replies and a **10-second undo**;
  failed sends retry after 1, 5, 15 and 60 minutes, then show a retry
  button. Internal notes are never emailed.
- **Forward, merge, move** a conversation; **start** one with any address.
- **Auto-reply** per mailbox, with loop protection.
- **Customers:** name, notes and several addresses, all their
  conversations, merge two customers.
- **Notifications** by email for new conversations and conversations
  assigned to you, if you turn them on.
- **Trash, retention and audit log** for Desk admins; see
  [Operations](operations.md).

**Who uses it:** see [Access](access.md). In short, `desk-admin` sets up
mailboxes and sees everything; everyone else gets the viewer, manager or
delete role of the mailboxes they work on.

## How Desk is built

| Part | Technology | Runs as (Kubernetes) |
| --- | --- | --- |
| Backend | Go 1.27, chi, pgx, go-imap v2, net/smtp, minio-go, zerolog | Deployment `desk-backend`, **one replica** |
| Migrations | Goose, SQL embedded in the binary | initContainer `migrate` in `desk-backend` |
| Frontend | React 19, Rsbuild, TanStack Router and Query, Tailwind, BlockNote | Deployment `desk-frontend` (nginx) |
| Database | PostgreSQL 16, database `desk` | conversations, threads, customers, settings, audit log |
| File storage | S3, bucket `desk-data` | attachments, inline images, original `.eml` |
| Mail | Google Workspace (Gmail API, Admin SDK) or IMAP/SMTP | |

The decisions behind this design are recorded as ADRs in the Desk
repository's [`docs/adr/`](https://github.com/AGlElectronics/desk/tree/main/docs/adr).

## Images

| Image | Built from | Contains |
| --- | --- | --- |
| `ghcr.io/aglelectronics/desk-backend:<tag>` | `infra/Dockerfile.backend` | `/server`, port 8080. `/server reencrypt` rotates the secret key. |
| `ghcr.io/aglelectronics/desk-migrate:<tag>` | `infra/Dockerfile.migrate` | `/migrate`, applies migrations and exits. |
| `ghcr.io/aglelectronics/desk-frontend:<tag>` | `infra/Dockerfile.frontend` | The web app (nginx, non-root as UID 101, port 8080). |

The frontend image names no domain: the web app reads its sign-in address
from `/config.json`; see
[Web app settings](configuration.md#web-app-settings-configjson).

## How Desk fits the platform

Own namespace `conservices-desk`, own Helm chart `deploy/charts/desk`, own
database `desk` and bucket `desk-data`. Its network policies let it reach
PostgreSQL, the platform S3, Den, the sign-in server, **Google's APIs**
(when the Google connector is on) and **your mail servers** (IMAP and
SMTP), and let only HR call it (for the role catalog). It pairs with Den for
the brand, settings and retention
([Pairing](../../concepts/pairing.md)); Den comes first
([How the platform starts](../../getting-started/how-the-platform-starts.md)).

## Ways to run it

| Posture | Use it for | Guide |
| --- | --- | --- |
| **Production cluster with Argo CD** (recommended for production) | Production: Den, Keycloak and every module on a cluster managed from Git | [Den and the modules](../../deploy/apps.md) |
| **Kubernetes platform** | A cluster you run yourself, next to Den; also the local trial cluster | [Setup, option 1](setup.md#option-1-kubernetes-platform-recommended) |
| **Standalone on Kubernetes** | Only Desk, your own PostgreSQL, S3 and sign-in | [Setup, option 2](setup.md#option-2-standalone-on-kubernetes) |
| **Production on Docker** | One server, no Kubernetes | [Setup, option 3](setup.md#option-3-production-on-docker) |
| **Development on Docker** | Trying it out with test mail servers | [Setup, option 4](setup.md#option-4-development-on-docker) |

A local Kubernetes cluster (the [quickstart](../../getting-started/den-quickstart.md)) is for trials only; production installations use the Argo CD path.

The backend always runs **one replica**: it fetches the mailboxes itself.

## In this section

- [Setup](setup.md): install Desk, add the first mailbox.
- [Google Workspace](google-workspace.md): service account, scopes and the
  two Google connectors.
- [IMAP and SMTP mailboxes](imap.md): mailboxes on any other mail server.
- [Access](access.md): Desk admin and the three roles per mailbox.
- [User guide](user-guide.md): folders, replying, shortcuts.
- [Operations](operations.md): trash and purge, retention, audit log,
  rotating `DESK_SECRET_KEY`, backups.
- [Configuration](configuration.md): every environment variable.
- [API reference](api.md): every HTTP endpoint, with permissions, bodies,
  errors and `curl` examples.
