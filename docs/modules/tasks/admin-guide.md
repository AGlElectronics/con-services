# Tasks admin guide

For the people who look after Tasks: roles, sharing, space settings,
automations, trash and the Den connection. Installing Tasks is on
[Setup](setup.md).

## Roles

Roles come from Keycloak groups through the
[access config file](configuration.md#access-config-file) and are checked
on every request.

| Keycloak group | Role | May do |
| --- | --- | --- |
| `tasks-admin` | `organization_admin` | Manage every space; the Den connection (**Settings**). |
| `tasks-creator` | `space_creator` | Create spaces, and manage the ones they created. |

There is deliberately no "tasks user" group: **working on tasks comes from
sharing**, not from a role. HR can grant the two roles above in its access
picker.

## Access levels

| Level | Can |
| --- | --- |
| **View** | See the space or list and its tasks; watch tasks. |
| **Edit** | View, plus create and change tasks, comment, use checklists and attachments. |
| **Manage** | Edit, plus share, rename, change statuses, tags and folders, manage automations, empty the trash, delete. |

Two shortcuts keep "please handle this one ticket" simple:

- **Being assigned** to a task gives you `edit` on that one task.
- **Watching** a task gives you `view` on it.

Spaces and tasks you cannot see answer "not found".

## Spaces

**Spaces** in the sidebar lists the spaces you can enter. `tasks-creator`
and `tasks-admin` see a **New space** card: give it a name, a **key** (2–6
letters or digits, used in task IDs such as `REG-12`) and a colour. A new
space gets the default statuses and a **General** list.

A space's page has these cards (managers only, except the lists):

| Card | What it does |
| --- | --- |
| **Lists** | Create lists; share a single list with another team. |
| **Sharing** | Who can see the space, and the level for **Everyone in the organization** (or closed). |
| **Statuses** | The board columns, each in a category: not started, active, done. **Save statuses** applies them; tasks keep their place. |
| **Space settings** | Name, key, colour, description; **Archive space** hides it from the sidebar and search without deleting anything (*Spaces → Show archived spaces* finds it again). **Changing the key renames every task ID in this space**; old IDs keep resolving. |
| **Tags** | Coloured tags for this space. Deleting a tag removes it from every task. |
| **Custom fields** | Extra fields for every task in the space: text, number, date, select (with options), checkbox or link. Values are set on the task page and shown in the list view; the list view filters by select fields. Deleting a field deletes its values on every task (audit-logged). |
| **Folders** | Group lists in the sidebar; drag a list onto a folder there. Deleting a folder keeps its lists. |
| **Archive and trash** | Archived lists, and trashed tasks with **Restore** and **Purge** (delete forever). |

## Sharing

Spaces **start closed**. Share them on the space's **Sharing** card with:

- people (by name),
- Keycloak groups (for example `dept-registration`), or
- everyone in the organisation, at a chosen level.

Lists can be shared on their own: another team then works in that one list
without seeing the rest of the space. A **private list** is visible only to
people with an explicit grant on it (and to space managers).

Group grants follow the token's `groups` claim, so removing someone from a
Keycloak group removes their access on their next request. Group names
match regardless of case and of a leading `/` (`/Dept-Registration` and
`dept-registration` are the same group), but the whole path must match:
`departments/registration` is not `registration`.

### Department spaces

With HR connected ([Setup, step 8](setup.md#option-1-kubernetes-platform-recommended)),
every HR department gets exactly **one space**, closed, with the
department's Keycloak group granted `edit`. Renaming the department in HR
renames the space; archiving it in HR archives the space (nothing is
deleted) and saving it again restores it. Everything inside (lists,
statuses, extra grants) stays in the department's hands; Tasks never
changes it again. The contract HR and Tasks share is on the
[API reference](api.md#department-hook-hr).

## Automations

Automations are "when X happens, do Y" rules on a space or on one list.
Space managers manage the space's rules; a manager of a single list can
manage rules scoped to that list.

| Part | Choices |
| --- | --- |
| **Trigger** | Task created, status changed (to a status or category), assignee added, comment added, checklist completed, due date approaching (N days before). |
| **Conditions** (all must hold) | List, status, priority, tag, assignee. |
| **Actions** | Set status, set priority, set due date (today + N days), assign, add tag, move to list (same space), create subtask, add checklist item, add comment, notify followers. |

Rules run in the same transaction as the change that triggered them. A
chain of rules is limited: each rule fires at most once per original change,
and chains stop at depth 5. A broken rule fails on its own without blocking
the user's edit. Every run, including failures, appears in the rule's
**run history**. Due-date rules are checked every minute.

## Trash, archive and audit

- Deleting a task (its creator, or a space manager) moves it to the
  space's trash. Managers restore or purge it under **Archive and trash**.
  Tasks left in the trash longer than the retention setting (default 30
  days) are purged automatically.
- Archiving a list or a space hides it without deleting anything.
- **Settings → Audit log** shows who deleted, purged, archived, imported or
  shared what, and when, newest first, with filters. Entries by the
  retention job or HR's department hook show *System*.

## Importing tasks

Anyone who can edit a list can import into it: the upload icon next to the
list's name opens **Import tasks**.

1. Pick the format: CSV (a header row with at least a *Title* column),
   ClickUp's CSV export, or the `data.json` of a Vikunja export.
2. Choose the file and press **Check**. Tasks shows how many tasks it will
   create and every problem: unknown statuses (mapped to the first
   not-started or done status), people who have never signed in to Tasks
   (left unassigned), dates or priorities it could not read.
3. Press **Import N tasks**. Everything is created at once, or nothing.

Missing tags are created only when you manage the space.

## Settings

Only Tasks admins see **Settings**.

- **Retention, reminders and email**: how long the trash, read
  notifications, the audit log and automation history are kept, and how
  many days before a due date assignees are reminded. Values set in Den's
  module settings show "set in Den" and can only be changed there. The
  defaults are placeholders pending legal review. The email part says
  which mail server is used (Den's or Tasks' own) and has **Send a test
  email to me**. Details: [Configuration](configuration.md#email).
- People choose which notifications they also get by email in
  **Inbox → Email settings**.

## Settings → Den connection

The **Den connection** card pairs Tasks with Den for the brand, theme,
organisation settings, module settings and the mail server:

1. Den: **Admin console → Modules → Pair** on the Tasks row; copy the URL.
2. Tasks: **Settings → Den connection**, paste it, **Connect**.
3. **Sync now** fetches Den's brand immediately (otherwise every minute);
   **Disconnect** returns Tasks to its own look.

See [Pairing](../../concepts/pairing.md).

## Backups

The database holds everything except attachments; the bucket holds the
attachments. With Den's operator, list the bucket in `FILES_S3_BUCKETS`.
Standalone, back up both yourself
([Databases, backups and restore](../../operations/databases-and-backups.md)).

## Troubleshooting

**Someone sees a list but not its space.** The list is shared with them on
its own; that is intended.

**Someone cannot find a task they were told about.** They need access to
its list or space, or to be assigned or watching it.

**A rule did nothing.** Open its run history: every run is listed with its
status and details, including errors. No entry means the trigger or
conditions did not match.

**Task IDs changed.** The space key was renamed; old IDs still open the
same tasks.

**A department space is missing from the sidebar.** It may be archived
because the department is archived in HR: *Spaces → Show archived
spaces*.

**Boards do not update by themselves.** The live-update stream is blocked
by a proxy; the web app then refreshes every 15 seconds. See the
[API troubleshooting](api.md#troubleshooting).
