# Tasks

**Tasks** is the project and task tracker of Con Services: spaces with
lists and boards, in the style of ClickUp but deliberately lighter. Crews
use it as their project task board, and each HR department gets its own
space automatically.

Source: [AGlElectronics/tasks](https://github.com/AGlElectronics/tasks)

## The goal

Organising a convention is hundreds of small jobs spread over months and
dozens of volunteers: book the hall, order badges, print signage, brief the
door team, pack the van, return the radios. Most of them have a deadline,
many depend on another team, and the people doing them change between
planning season and the event weekend. Tasks exists so that **every team
can see what needs doing, who is on it and what is late, and so that work
handed from one person or team to another does not fall through the
cracks**.

Concretely, Tasks aims to:

- **Give each department a ready-made place to work.** When HR creates a
  department, Tasks creates its space, shared with the department's group,
  so a new team lead starts with a board on day one.
- **Stay light enough for volunteers.** A task needs only a title; boards,
  due dates, priorities, checklists and tags are there when wanted, not
  required.
- **Make "what do I do next?" obvious.** My Work lists each person's tasks
  by due date, and the Inbox tells them when they are assigned, mentioned,
  or a task they follow moves.
- **Support hand-offs between teams.** Tasks can move between lists and
  spaces, a single list can be shared with another team, and task keys such
  as `CREW-42` keep working in chats and documents even after a move.
- **Automate the repetitive parts.** Rules like "when a task is done, move
  it to the archive list" or "three days before the due date, notify the
  assignees" run without anyone remembering to.
- **Be safe for many hands.** Version checks stop two people overwriting
  each other, deleted tasks go to a trash first, and destructive actions
  are audit-logged.

## What Tasks does

- **Spaces, folders, lists, tasks, subtasks.** Each space has its own
  statuses (the board columns) and a short key, so tasks get IDs such as
  `CREW-42`.
- **List, board, calendar, timeline and workload views** with drag and
  drop, a sort you choose, filters remembered per list and bulk actions,
  plus a **calendar across every space**.
- **Planning:** custom fields per space, dependencies ("waits for"),
  recurring tasks, estimates and time tracking.
- **Live updates:** boards and task pages refresh within a second when
  someone else changes something.
- **Email** for the notifications each person picks, and due-soon
  reminders.
- **Import** from a CSV, ClickUp or Vikunja.
- **Minimal task creation:** a title is enough; everything else is
  optional.
- **My Work** (your tasks grouped by due date) and an **Inbox** with
  notifications and an unread badge.
- **Collaboration:** comments with `@Full Name` mentions, watchers,
  checklists, tags, favourites, Ctrl+K search with task-ID jump.
- **Attachments** on tasks (25 MB each), stored in S3. Optional: without
  storage, uploads answer `503` and everything else works.
- **Automations:** "when X happens, do Y" rules per space or per list, with
  a visible run history.
- **Safety:** version checks against lost updates, a trash with restore and
  purge, archived lists and spaces, an audit log admins can read, and
  retention settings for old data.
- **Departments:** HR tells Tasks when a department is created, saved or
  archived; Tasks keeps exactly one space per department.

**Who uses it:** everyone works on tasks in spaces and lists shared with
them. Tasks admins (Keycloak group `tasks-admin`) manage every space and
the Den connection; `tasks-creator` may create spaces. See the
[Admin guide](admin-guide.md).

## How Tasks is built

| Part | Technology | Runs as (Kubernetes) |
| --- | --- | --- |
| Backend | Go 1.27, chi, pgx, zerolog | Deployment `tasks-backend`, **one replica** |
| Migrations | Goose, SQL embedded in the binary | initContainer `migrate` in `tasks-backend` |
| Frontend | React 19, Rsbuild, TanStack Router and Query, Tailwind | Deployment `tasks-frontend` (nginx) |
| Database | PostgreSQL 16, database `tasks` | shared server, or your own |
| File storage | S3-compatible bucket (`tasks-data`; `tasks-data-dev` in Compose), optional | attachments |

## Images

| Image | Built from | Contains |
| --- | --- | --- |
| `ghcr.io/aglelectronics/tasks-backend:<tag>` | `infra/Dockerfile.backend` | `/server`, port 8080. |
| `ghcr.io/aglelectronics/tasks-migrate:<tag>` | `infra/Dockerfile.migrate` | `/migrate`, applies database migrations and exits. |
| `ghcr.io/aglelectronics/tasks-frontend:<tag>` | `infra/Dockerfile.frontend` | The web app served by nginx (non-root as UID 101, port 8080). |

All three use the same tag, `MAJOR.MINOR.PATCH-BUILD` (see
[Versions and upgrades](../../operations/versioning.md)). The web app's
sign-in address is not part of the frontend image: the web app reads it
from `/config.json`; see
[Web app settings](configuration.md#web-app-settings-configjson).

## How Tasks fits the platform

On Kubernetes, Tasks is its own namespace (`conservices-tasks`), its own
Helm chart (`deploy/charts/tasks`), its own database (`tasks`) and bucket
(`tasks-data`). Its network policies let it reach only PostgreSQL, S3, Den,
the sign-in server and (when you allow it) your mail server, and let only
HR call it (role catalog and the department hook). It talks to other parts only over HTTP and pairs with Den
for the brand and settings ([Pairing](../../concepts/pairing.md)). Den
comes first: [How the platform starts](../../getting-started/how-the-platform-starts.md).

## Ways to run it

| Posture | Use it for | Guide |
| --- | --- | --- |
| **Production cluster with Argo CD** (recommended for production) | Production: Den, Keycloak and every module on a cluster managed from Git | [Den and the modules](../../deploy/apps.md) |
| **Kubernetes platform** | A cluster you run yourself, next to Den; also the local trial cluster | [Setup, option 1](setup.md#option-1-kubernetes-platform-recommended) |
| **Standalone on Kubernetes** | Only Tasks, your own PostgreSQL, S3 and sign-in | [Setup, option 2](setup.md#option-2-standalone-on-kubernetes) |
| **Production on Docker** | One server, no Kubernetes | [Setup, option 3](setup.md#option-3-production-on-docker) |
| **Development on Docker** | Trying it out; never real data | [Setup, option 4](setup.md#option-4-development-on-docker) |

A local Kubernetes cluster (the [quickstart](../../getting-started/den-quickstart.md)) is for trials only; production installations use the Argo CD path.

The backend always runs **one replica**; [why](setup.md#why-the-backend-runs-one-replica).

## In this section

- [Setup](setup.md): install Tasks in each of the five ways.
- [Admin guide](admin-guide.md): roles, sharing, statuses, automations,
  trash and the Den connection.
- [Configuration](configuration.md): every environment variable.
- [API reference](api.md): every HTTP endpoint, with examples.

The plan and the decisions behind it:
[docs/plan.md](https://github.com/AGlElectronics/tasks/blob/main/docs/plan.md).
