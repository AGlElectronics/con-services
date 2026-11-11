# Learn

**Learn** is the training module of Con Services: its own course package
(not a Moodle embed) with courses of pages, quizzes and in-person sessions,
qualifications with printable certificates, learning paths, reminders and
reports. Together with HR it can make sure people hold a qualification
before they get a role.

Source: [AGlElectronics/learn](https://github.com/AGlElectronics/learn)

## Goals

Learn exists so that **everyone who does a job at the convention has been
trained for it, and the organisation can prove it**. In terms of the
platform conventions that means:

- **Training gates roles.** A qualification earned in Learn can be required
  by HR before it grants a role. HR reads the
  [qualification catalog](api.md#get-apiqualification-catalog) and asks
  [holdings](api.md#get-apiinternalholdings) with a shared service token;
  no other module reads Learn's database.
- **Access through Keycloak groups, like every module.** Staff roles come
  from `learn-admin`, `learn-trainer`, `learn-manager` and
  `learn-coordinator`, published in the
  [role catalog](api.md#get-apirole-catalog). Learners need no role:
  an enrolment is enough, and courses linked to a Keycloak group enrol its
  members automatically.
- **Hidden until ready.** Unpublished courses do not exist for anyone but
  their staff (`404`, not `403`), so drafts never leak.
- **Provable and private.** Certificates carry a public verify code that
  shows only a name, a qualification and dates; team boards show counts per
  group, never names.
- **API first.** The web app uses only the public HTTP API, which follows
  the shared [API conventions](../../concepts/api-conventions.md); Den's
  portal reads Learn to-dos through the same API.
- **Branded by Den.** Once [paired](../../concepts/pairing.md), Learn shows
  your organisation's name, logo and theme like every other module.

## What Learn does

- **Courses:** sections of pages, quizzes and sessions; publish and
  unpublish; a self-enrolment catalog; trainer and learner enrolments;
  progress per learner; copying a course for a new edition.
- **Quizzes:** question banks (single choice, multiple choice, hotspot on a
  picture), random draws, pass marks, attempt limits, a gradebook, question
  statistics, and import from Moodle XML, GIFT, Aiken and CSV.
- **In-person sessions:** dated slots with capacity and waitlist, a rotating
  QR code for check-in at the venue, walk-ins and a roster.
- **Rules:** prerequisites between activities and due dates with overdue
  tracking.
- **Group sync:** courses and paths linked to Keycloak groups (by full
  path) enrol their members automatically (every 5 minutes; members who
  leave are deactivated, never deleted).
- **Media:** pictures, audio and video uploaded to object storage and
  checked by their contents (alt text required for pictures), plus YouTube
  and Vimeo embeds.
- **Archive, audit and privacy:** courses are archived (hidden, read-only,
  reversible), never deleted; an audit log records enrolments, course
  roles, grading, resets and revokes; people can be erased (GDPR) and are
  anonymised after a retention period.
- **Qualifications:** earned by finishing a course or path, with expiry and
  renewal, printable certificates and a public QR verify page.
- **Learning paths:** ordered (optionally sequential) course bundles.
- **Engagement:** email and Telegram reminders (hourly), team progress
  boards, course and session feedback, and to-dos on Den's portal home.
- **Reports:** completion and qualification status, with CSV export.
- **Languages:** courses in several languages with a translation editor;
  the interface is in English and Dutch.

**Who uses it:** everyone enrolled in a course learns in it (there is no
"learner" role: an enrolment gives access). `learn-trainer` creates and
runs courses, `learn-manager` decides who teaches which course,
`learn-coordinator` (the training office) reads every report and manages
qualifications, `learn-admin` does everything. The guides walk through each:
[learners](guides/learner.md), [trainers](guides/trainer.md),
[admins and managers](guides/admin.md).

### HR role gating

HR can require a qualification before granting a role ("only people with
*First aid* get *Medic*"). HR reads Learn's qualification catalog and asks
Learn which qualifications people hold, with a shared service token
(`LEARN_SERVICE_TOKEN`). Without that connection HR grants roles
straight away and shows a warning.

## How Learn is built

| Part | Technology | Runs as (Kubernetes) |
| --- | --- | --- |
| Backend | Go 1.27, chi, pgx, zerolog | Deployment `learn-backend` |
| Migrations | Goose, SQL embedded in the binary | initContainer `migrate` in `learn-backend` |
| Frontend | React 19, Rsbuild, TanStack Router and Query, Tailwind; English and Dutch | Deployment `learn-frontend` (nginx) |
| Database | PostgreSQL 16, database `learn` | shared server, or your own |
| File storage | S3-compatible bucket (`learn-data`; `learn-data-dev` in Compose), optional | course media |

## Images

| Image | Built from | Contains |
| --- | --- | --- |
| `ghcr.io/aglelectronics/learn-backend:<tag>` | `infra/Dockerfile.backend` | `/server`, port 8080. |
| `ghcr.io/aglelectronics/learn-migrate:<tag>` | `infra/Dockerfile.migrate` | `/migrate`, applies migrations and exits. |
| `ghcr.io/aglelectronics/learn-frontend:<tag>` | `infra/Dockerfile.frontend` | The web app (nginx, non-root as UID 101, port 8080). |

The frontend image names no domain: the web app reads its sign-in address
from `/config.json`; see
[Web app settings](configuration.md#web-app-settings-configjson).

## How Learn fits the platform

Own namespace `conservices-learn`, own Helm chart `deploy/charts/learn`, own
database `learn` and bucket `learn-data`. It talks to others only over
HTTP:

| Direction | What |
| --- | --- |
| Learn → Den | Pairing, brand and settings ([Pairing](../../concepts/pairing.md)). |
| Learn → Keycloak admin API | Read-only group and people lookups for group sync and the people picker (client `learn-provisioner`; off with `GROUP_DIRECTORY=off`). |
| Learn → Telegram Bot API | Reminders to people who saved a chat id (`api.telegram.org`, only with `TELEGRAM_BOT_TOKEN`). |
| HR → Learn | Role catalog, qualification catalog, holdings (service token). |
| Browser (Den's web app) → Learn | Portal to-dos and "my learning" widgets, with Den's token (`OIDC_EXTRA_AUDIENCES`). |
| Browser → S3 | Media upload and download through presigned links (`S3_PUBLIC_BASE_URL`). |

Den comes first: [How the platform starts](../../getting-started/how-the-platform-starts.md).

## Ways to run it

| Posture | Use it for | Guide |
| --- | --- | --- |
| **Production cluster with Argo CD** (recommended for production) | Production: Den, Keycloak and every module on a cluster managed from Git | [Den and the modules](../../deploy/apps.md) |
| **Kubernetes platform** | A cluster you run yourself, next to Den and HR; also the local trial cluster | [Setup, option 1](setup.md#option-1-kubernetes-platform-recommended) |
| **Standalone on Kubernetes** | Only Learn | [Setup, option 2](setup.md#option-2-standalone-on-kubernetes) |
| **Production on Docker** | One server, no Kubernetes | [Setup, option 3](setup.md#option-3-production-on-docker) |
| **Development on Docker** | Trying it out | [Setup, option 4](setup.md#option-4-development-on-docker) |

A local Kubernetes cluster (the [quickstart](../../getting-started/den-quickstart.md)) is for trials only; production installations use the Argo CD path.

## In this section

- [Setup](setup.md): install Learn in each of the five ways.
- [Configuration](configuration.md): every environment variable.
- Guides: [for learners](guides/learner.md), [for trainers](guides/trainer.md)
  and [for admins and managers](guides/admin.md).
- [API reference](api.md): all 147 HTTP endpoints (courses, quizzes,
  sessions, media, qualifications, paths, group sync, reports, and the
  HR and portal contracts), with permissions, bodies, errors and `curl`
  examples.

The domain rules (who may do what, how completion and qualifications work)
are in [docs/domain.md](https://github.com/AGlElectronics/learn/blob/main/docs/domain.md).
