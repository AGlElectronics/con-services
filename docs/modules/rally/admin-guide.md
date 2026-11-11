# Rally admin guide

This page is for the people who run the programme in Rally (Events): the
events lead, the programme team and reviewers. For installing Rally see
[Setup](setup.md).

## Roles and groups

Rally gives people **roles**; each role is a set of **permissions**. Roles
come from Keycloak groups through the access configuration
(`access-config.toml`). With the platform's file:

| Keycloak group | Role | Can |
| --- | --- | --- |
| `events-admin` | Organization admin | Everything, including the Den connection (`org.manage`) and members. |
| `events-organizer` | Edition organizer | Run editions and calls for papers, decide on submissions, build and publish the schedule. |
| `events-programme` | Programme manager | Decide on submissions, build and publish the schedule. |
| `events-reviewer` | Reviewer | Read, comment on and score submissions. The lead decides. |

The permissions behind them:

| Permission | Allows |
| --- | --- |
| `org.view`, `org.manage` | See the organisation; manage it and the Den connection. |
| `edition.view`, `edition.edit` | See editions; change their dates and timezone. |
| `member.view`, `member.manage`, `audit.view` | See and manage members; read the audit log. |
| `cfp.manage` | Create and edit calls for papers and event types. |
| `submission.review` | Read every submission, add notes, score. |
| `submission.decide` | Accept or reject. |
| `schedule.edit` | Rooms, schedule settings, placing items, restoring versions. |
| `schedule.publish` | Publish, live-day changes, announcements, Telegram chats, public API keys. |

**Giving someone access:** add them to the group in Keycloak, or give them
the Events role in HR (HR adds the group). Group changes apply on their
next request; removing someone from the group removes the role.

**Changing the roles:** edit `access-config.toml` (in the platform: the
`rally-access-config` ConfigMap) and restart the backend. Group names are
compared with the platform's shared rule: without case, without Keycloak's
leading `/`, by default as whole paths (`/departments/events` is not the
same as `/teams/events`), and only from the token's `groups` claim, never
from realm roles. The operator can change the claim, compare only the last
path segment or remove a parent group such as `/con2026`
(`OIDC_GROUPS_CLAIM`, `OIDC_GROUP_MATCH`, `OIDC_GROUP_PREFIX`; see
[How groups are matched](../../concepts/authentication.md#how-groups-are-matched)).
A permission name Rally does not know stops it from starting, with the
error in the log.

**Privileged roles in HR.** HR asks for confirmation before it assigns a
*privileged* role and lists those roles separately on the person. In Rally
every role that can change settings, grant access or read other people's
submissions is privileged, reviewers included. To change that for a role,
set `privileged = true` or `false` under it in `access-config.toml`:

```toml
[roles.reviewer]
description = "Reads, comments on and scores submissions; the lead decides."
permissions = ["org.view", "edition.view", "submission.review"]
privileged = true
```

```sh
kubectl create configmap rally-access-config -n conservices-rally \
  --from-file=access-config.toml=access-config.toml --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deploy/rally-backend -n conservices-rally
```

## Organisations and editions

An **organisation** is who runs the events (your association). A
**convention** is the recurring event; an **edition** is one year of it,
with its own calls, submissions and schedule.

!!! warning "No screen for this yet"
    Rally cannot create organisations or editions in the app yet. Its first
    migration creates the organisation `demo-org` with the convention
    `demo-con` and the edition `next`. Until there is a screen, rename them
    and add editions with SQL, as below. Do this before you open a call.

Open a database shell (platform PostgreSQL shown; use your own server when
standalone):

```sh
kubectl exec -n conservices-data -it statefulset/postgres -- psql -U postgres -d events
```

Rename the starting organisation, convention and edition:

```sql
UPDATE organizations SET slug = 'example-con-ev', display_name = 'Example Con e.V.'
 WHERE id = '00000000-0000-0000-0000-000000000010';
UPDATE conventions SET slug = 'example-con', name = 'Example Con'
 WHERE id = '00000000-0000-0000-0000-000000000020';
UPDATE editions SET slug = '2027', title = 'Example Con 2027', timezone = 'Europe/Vienna'
 WHERE id = '00000000-0000-0000-0000-000000000030';
```

```text
UPDATE 1
UPDATE 1
UPDATE 1
```

If you changed the organisation's slug, set the same value at the top of
`access-config.toml` (`organization = "example-con-ev"`) and restart the
backend. Otherwise the group bindings point at an organisation that no
longer exists and staff see nothing.

Add the next year later:

```sql
INSERT INTO editions (organization_id, convention_id, slug, title, timezone, status)
VALUES ('00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000020',
        '2028', 'Example Con 2028', 'Europe/Vienna', 'planning');
```

Slugs are lowercase letters, digits and `-`. The first and last day are set
in the app (**Schedule → Setup**).

The same migration also creates a "Dev Admin" user for development sign-in.
It cannot sign in when `AUTH_MODE=oidc`.

## Calls for papers

A **call for papers** (CfP) collects proposals for one edition. Open
**Calls for papers**, create a call, and set:

- **Form**: the questions submitters answer, beyond title and abstract.
- **Settings**: opening and closing time, the event types it accepts
  (talk, workshop, …; managed under **Event types**), the names shown for
  each status, and the **review mode**:
    - `lead`: reviewers comment, the lead decides;
    - `scored`: reviewers also give scores; the average is shown.
- **Status**: `draft` (hidden), `open` (takes submissions), `closed`
  (readable, no new submissions).

Attendees see open calls on the submission site, where they sign in with
their own attendee account, save drafts, invite co-presenters by presenter
code or email, upload attachments and submit.

## Reviewing and deciding

Open a call's **Submissions** tab. On a submission:

- **Notes** are a discussion among staff; submitters never see them.
- **Scores** (scored mode) can be given by anyone with `submission.review`,
  except on their own submission.
- **Accept** or **Reject** (`submission.decide`) with an optional note. The
  note **is** shown to the submitter.

Only submitted proposals can be decided. A submitter may withdraw even
after acceptance.

## Building and publishing the schedule

Open **Schedule**. It has four tabs:

| Tab | What you do there |
| --- | --- |
| **Setup** | Edition dates and timezone, rooms with capacity and order, grid hours and rules, Telegram chats, public API keys. |
| **Build** | Drag accepted submissions onto the grid. Rule violations (overlaps, a presenter in two places) show as conflicts; blocking rules refuse the change. |
| **Versions** | Every published version; open one or restore it into the draft. |
| **Live day** | Delay, move, cancel or restore items on the **published** schedule, and post announcements. |

**Publish** creates a new version from the draft. The public schedule and
the submission site's Programme page always show the latest version plus
any live-day changes.

## Public schedule

Websites, info screens and calendar apps can read the published schedule
from `/api/public/v1/schedules` ([API](api.md#get-apipublicv1schedules-and-get-apipublicv1schedulesedition)).

1. **Switch it on.** When paired with Den: in Den, set the organisation
   setting `events_public_schedule` to on. Otherwise the operator sets
   `PUBLIC_SCHEDULE_ENABLED=true`. While it is off, the API answers 404.
2. **Give each consumer its own key.** **Schedule → Setup → API keys**:
   create a key named after the consumer ("Convention website"). The value
   is shown **once**; copy it to the consumer. Revoke a key there when a
   consumer should stop; each key shows when it was last used.
3. Consumers send it as `Authorization: Bearer <key>`, or append
   `?key=<key>` to the calendar feed address
   (`…/schedules/2027/calendar.ics?key=…`).

The submission site's Programme page uses the built-in key
"programme-page", which the operator sets with `PUBLIC_API_BUILTIN_KEY`.
It is visible to every visitor of that site, so treat it as public.

## Live day and announcements

On **Live day**, delaying or moving an item changes the published schedule
straight away; you can push the following items in the same room. To tell
people, write an announcement and **Send** it: it goes to every enabled
Telegram chat set up under **Setup**.

Without a Telegram bot token, sending is a **dry run**: the announcement is
marked as sent in Rally but nothing reaches Telegram. Ask the operator to
set `TELEGRAM_BOT_TOKEN` and to allow traffic to Telegram.

## Den connection

**Organizations → Den connection** (needs `org.manage`). Paste the pairing
URL from Den. Once paired, Rally uses Den's brand and organisation name,
and Den's `events_public_schedule` setting decides the public schedule.
See [Pairing](../../concepts/pairing.md).

If Den rejects Rally's credential (the module was removed or re-registered
in Den), admins see **Den rejected this module's credential: pair again** at
the top of every page, and the Den connection panel asks for a new pairing
URL. Rally keeps Den's last brand and settings until then. Create a new
pairing URL in Den (**Admin → Modules → Pair**) and paste it.

## Troubleshooting

**A staff member sees no edition.** None of their groups is bound in the
access configuration, or the binding's organisation slug does not exist.
Have them open `/api/v1/me`: `memberships` must not be empty. A role that
only exists as a Keycloak *realm role* (in the `roles` claim) grants
nothing; put the person into the group instead.

**"Edition not found" for someone who clearly has a role.** Draft
schedules, rooms and event types are only shown to programme and CfP staff;
for everyone else Rally answers "not found". Give them a role with the
needed permission.

**Accept or Reject answers "cannot accept a draft submission".** The
submitter has not submitted yet, or has withdrawn.

**Uploads fail for attendees.** Usually the storage address: see
[Setup troubleshooting](setup.md#troubleshooting).

**The website shows an old schedule.** Responses may be cached for up to 60
seconds. Check that you **published** after your last change.
