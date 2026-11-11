# Learn for admins and managers

This guide is for the people who run Learn for the organisation:

| Keycloak group | Role | Does |
| --- | --- | --- |
| `learn-admin` | organisation admin | Everything: every course, settings, the audit log, erasure. |
| `learn-manager` | training manager | Decides who teaches: adds and removes trainers on **Course roles**. |
| `learn-coordinator` | training office | Reports, **Qualifications**, revoking certificates. |

People get these groups in Keycloak directly or through HR's access
picker. Changes apply on their next request. Installation and environment
variables are on [Setup](../setup.md) and
[Configuration](../configuration.md).

## Decide who teaches (training managers)

1. Open **Course roles**. Every course is listed with its trainers; filter
   by title.
2. To add a trainer, search for the person under **Add a trainer** and
   choose **Trainer**. People marked *not signed in yet* come from the
   directory.
3. To remove a trainer, use the cross next to their name. The last trainer
   of a course can't be removed: add the new trainer first.

You see: the person appears in the course's trainer list, and the course
appears on their **Teach** page. Every change is in the audit log.

Training managers don't edit course content. Trainers can't add or remove
trainers themselves.

## Qualifications and certificates (training office)

1. Open **Qualifications** and create one: a key (for example `first-aid`),
   a name and how many months a certificate stays valid (empty: never
   expires).
2. A trainer links it to their course (course settings). Learners who
   finish the course get a certificate; learners who already finished get
   one when it is linked.
3. **Holders** lists every certificate. To **Revoke** one, give a reason; the
   public verify page then says *revoked*. Revoking is recorded in the
   audit log.

HR can require a qualification before it grants a role; see
[HR role gating](../index.md#hr-role-gating).

## Group links

Courses and learning paths can be linked to Keycloak groups by full path
(`/learn/cohort-a`). Admins may link any group; trainers only those under
`LEARN_LINKABLE_GROUPS` (default `/learn/*`).

1. Create the groups trainers should use below a parent group, for example
   `/learn/cohort-2026`.
2. Make sure Keycloak sends full paths in tokens: in the groups mapper of
   the `learn-spa` client, **Full group path** must be on.
3. Check **Settings → Group directory**: *Mode: keycloak* and the linkable
   patterns. When the directory is off, links only match groups people sign
   in with, and the panels warn about it.

Links made before Learn used full paths were looked up once at start-up. A
link that says *its path was not found* matched no group, or several:
unlink it and link the right group again.

## Settings (admins)

**Settings** holds:

- **Den connection**: pair Learn with Den (see
  [Pairing](../../../concepts/pairing.md)).
- **Telegram notifications**: switch Telegram reminders on or off. It needs
  `TELEGRAM_BOT_TOKEN`; while it is off, reminders go by email only and
  Telegram doesn't count them as sent.
- **Data retention**: anonymise people inactive for N months and delete
  audit entries after M months (`0` = never). The defaults (36 and 24) are
  **pending legal review**: set your own after checking your duties. While
  Learn is paired with Den, Den's module settings for Learn decide these and
  the fields are read-only.
- **Group directory**: the mode and the groups trainers may link.
- **Erase a person**: see below.
- **Audit log** (button at the top).

## Erase a person (GDPR)

1. **Settings → Erase a person**, search for the person, choose **Erase…**.
2. Type `ERASE` and confirm.

You see: *… was erased.* Their name becomes *Former learner*; email,
sign-in link, groups and notification settings are gone. Progress, results,
attendance and certificates stay, and certificates keep verifying with the
new name. In the audit log their actions stay, shown as *Erased user*. If
the person signs in again, Learn creates a new, empty account. This can't
be undone.

## Audit log

**Settings → Audit log** lists who did what, newest first: enrolments and
course roles, publishing and archiving, quiz grading and resets, revoked
certificates, qualification changes, group links, attendance changes, Den
pairing, settings and erasure. Filter by action; **Load older entries**
pages back. Entries older than the audit retention are deleted
automatically.

## Reset a quiz

Only admins (`course.manage`) can reset a quiz, for example after a broken
question:

1. In the course editor, open the quiz and choose **Reset this cycle…**.
2. Type the quiz title exactly and choose **Reset quiz**.

Every learner's attempts and completion of that quiz in their current cycle
are deleted; earlier cycles and issued certificates stay. The reset is in
the audit log.

## Troubleshooting

- **A trainer can't add a co-trainer.** That is by design: add them on
  **Course roles** (training manager or admin).
- **"This is the course's last trainer".** Add another trainer before
  removing this one.
- **Retention fields are greyed out.** Learn is paired with Den and Den
  decides retention; change it in Den.
- **Telegram switch is greyed out.** `TELEGRAM_BOT_TOKEN` is not set.
- **"The group directory is off"** on the group panels. `GROUP_DIRECTORY` is
  `off`, or `KEYCLOAK_*` is not set. Members are then enrolled as they sign
  in.
- **The coordinator can't open Settings.** Settings needs `learn-admin`;
  coordinators use **Qualifications** and **Reports**.
- **Someone erased by mistake.** Erasure can't be undone; restore the
  database from a backup only if your policy allows it.
