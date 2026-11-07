# Wiki

**Wiki** is the knowledge base of Con Services: Notion-style pages nested in
spaces, edited live by several people at once. Crews use it for handbooks,
how-tos, meeting notes and anything else that should outlive a chat thread.

Source: [AGlElectronics/wiki](https://github.com/AGlElectronics/wiki)

## The goal

Conventions are run by volunteers who often join for one event, work in a
team they have never met, and leave again. What a team learned (how the
registration desk opens, which radio channel security uses, what to do when
a guest faints, the contact at the venue) usually lives in someone's head,
a chat history or a dozen loose documents, and is lost when that person
moves on. Wiki exists so that **a convention's know-how is written down
once, kept current by the people who do the work, and found in seconds by
whoever needs it next, including next year's crew**.

Concretely, Wiki aims to:

- **Give every team a home for its knowledge.** A team space per
  department or project, with handbooks, checklists and meeting notes
  nested as deeply as needed.
- **Make writing together effortless.** Several people edit the same page
  live, see each other's cursors, and discuss in comment threads instead of
  in side chats.
- **Get the right page to the right person quickly.** Search over titles
  and text, mentions and backlinks, favourites, and templates so a new
  "shift handover" or "incident report" page starts from a proven layout.
- **Share safely.** Access follows the organisation's groups (when someone
  leaves a department in HR, they lose its pages on their next request),
  sensitive pages can be restricted, and a single page can be published
  read-only to guests or vendors with a link that expires.
- **Never lose work.** Page history with restore, a trash, and an
  offboarding flow that hands a departing volunteer's private notes to the
  admins instead of deleting them on the spot.
- **Hold small structured lists too.** Databases (tables, boards,
  calendars) cover the "simple tracker" cases, like a guest-of-honour
  schedule or a supplier list, without another tool.

## What Wiki does

- **Spaces and pages.** Everyone gets a private space on first sign-in.
  Team spaces are closed until shared. Pages nest without limit and can be
  moved by drag and drop, trashed, restored and deleted forever.
- **Live editing.** Several people edit the same page at once and see each
  other's cursors, using a block editor (BlockNote). People with view
  access see the page read-only.
- **Files.** Image and file blocks (25 MB images, 50 MB files), downloaded
  through the backend after the page access check.
- **History.** Automatic revisions (at most one per 10 minutes of editing),
  read-only preview and restore.
- **Search and links.** Ctrl+K search over titles and page text, `@person`
  and `@page` mentions, backlinks, favourites.
- **Comments.** Inline discussion threads with replies, resolve and emoji
  reactions.
- **Public share links.** A read-only page (optionally with its sub-pages)
  for anyone with the link, if the organisation allows it (Den setting
  `wiki_public_links`).
- **Templates and Markdown.** Mark pages as templates, duplicate pages with
  their content, import `.md` files, export pages as Markdown.
- **Databases.** Tables, boards and calendars over child pages with typed
  properties ([ADR 0002](https://github.com/AGlElectronics/wiki/blob/main/docs/adr/0002-databases-as-pages.md)).
- **Offboarding.** When HR deletes someone's account, HR tells Wiki; the
  person's private space is handed to the Wiki admins and deleted after a
  grace period (30 days by default).

**Who uses it:** everyone in the organisation reads and writes pages they
have access to. Wiki admins (Keycloak group `wiki-admin`) see every team
space and pair the module with Den. People in `wiki-editor` may create team
spaces. See the [Admin guide](admin-guide.md).

## How Wiki is built

| Part | Technology | Runs as (Kubernetes) |
| --- | --- | --- |
| Backend | Go 1.27, chi, pgx, `coder/websocket`, zerolog | Deployment `wiki-backend`, **always one replica** |
| Migrations | Goose, SQL embedded in the binary | initContainer `migrate` in `wiki-backend` |
| Frontend | React 19, Rsbuild, TanStack Router and Query, Tailwind, BlockNote and Yjs | Deployment `wiki-frontend` (nginx) |
| Database | PostgreSQL 16, database `wiki` | shared server, or your own |
| File storage | S3-compatible bucket (`wiki-data` on Kubernetes, `wiki-data-dev` in Compose) | page content and uploads |
| Edit buffer | A small disk directory (`WIKI_BUFFER_DIR`) | a volume on the backend pod |

**Page content lives only in the bucket**, not in the database. Back up
both. See [Databases, backups and restore](../../operations/databases-and-backups.md).

## Images

All three images use the same tag for a release (see
[Versions and upgrades](../../operations/versioning.md)):

| Image | Built from | Contains |
| --- | --- | --- |
| `ghcr.io/aglelectronics/wiki-backend:<tag>` | `infra/Dockerfile.backend` | `/server`, listening on port 8080. |
| `ghcr.io/aglelectronics/wiki-migrate:<tag>` | `infra/Dockerfile.migrate` | `/migrate`, a one-shot that applies database migrations and exits. |
| `ghcr.io/aglelectronics/wiki-frontend:<tag>` | `infra/Dockerfile.frontend` | The web app served by nginx (non-root as UID 101, port 8080). |

!!! note "The web app's sign-in address is a setting, not part of the image"
    The published `wiki-frontend` image names no domain: the web app loads
    its sign-in settings from `/config.json` when it starts. See
    [Web app settings](configuration.md#web-app-settings-configjson).

## How Wiki fits the platform

On Kubernetes, Wiki is one self-contained unit:

- its own namespace, `conservices-wiki`;
- its own Helm chart, `deploy/charts/wiki`;
- its own database (`wiki`) and bucket (`wiki-data`);
- network policies that let it reach only PostgreSQL, S3, Den and the
  sign-in server, and let only HR call it (for the role catalog and the
  offboarding hook).

It talks to other parts **only over HTTP**: it pairs with Den (to follow the
organisation's brand and settings, see [Pairing](../../concepts/pairing.md)),
and HR calls it. Den comes first; see
[How the platform starts](../../getting-started/how-the-platform-starts.md).

## Ways to run it

| Posture | Use it for | Guide |
| --- | --- | --- |
| **Production cluster with Argo CD** (recommended for production) | Production: Den, Keycloak and every module on a cluster managed from Git | [Den and the modules](../../deploy/apps.md) |
| **Kubernetes platform** | A cluster you run yourself, next to Den and the other modules; also the local trial cluster | [Setup, option 1](setup.md#option-1-kubernetes-platform-recommended) |
| **Standalone on Kubernetes** | Only Wiki, with your own PostgreSQL, S3 and sign-in | [Setup, option 2](setup.md#option-2-standalone-on-kubernetes) |
| **Production on Docker** | One server, no Kubernetes | [Setup, option 3](setup.md#option-3-production-on-docker) |
| **Development on Docker** | Trying it out and development, never real data | [Setup, option 4](setup.md#option-4-development-on-docker) |

A local Kubernetes cluster (the [quickstart](../../getting-started/den-quickstart.md)) is for trials only; production installations use the Argo CD path.

In every posture the backend runs **one replica**; [why](setup.md#why-the-backend-must-stay-at-one-replica).

## In this section

- [Setup](setup.md): install Wiki in each of the five ways.
- [Admin guide](admin-guide.md): roles, spaces, sharing, share links,
  offboarding and the Den connection.
- [Configuration](configuration.md): every environment variable.
- [API reference](api.md): every HTTP endpoint, with examples.

Design decisions: [ADR 0001, live editing](https://github.com/AGlElectronics/wiki/blob/main/docs/adr/0001-yjs-relay-in-go.md)
and [ADR 0002, databases](https://github.com/AGlElectronics/wiki/blob/main/docs/adr/0002-databases-as-pages.md).
