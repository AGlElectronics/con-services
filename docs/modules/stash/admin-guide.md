# Stash admin guide

This page is for the people who look after Stash: who may do what, the
settings, privacy, notifications, the Den connection, and the tasks that
come up before, during and after an event. Installing Stash is on
[Setup](setup.md); the people at the desk and in the warehouse use the
[Volunteer and front-desk guide](volunteer-guide.md).

## Who can do what

Access in Stash is decided by **roles**. A role is a named set of
**permissions** (such as `item.create` or `lostfound.resolve`). People get
roles through **groups** in the identity provider (Keycloak).

**Roles are global.** A role applies to every department: a department lead
handles every department's gear, and nobody's access is limited to one
department.

Every role appears in HR's access picker as `stash_<role>` (HR reads
`GET /api/role-catalog`). A person gets a role in two ways:

1. They are in a group that `access-config.toml` binds to the role (the
   shipped file binds `stash-admin`, `stash-logistics-lead` and so on), or
2. they are in a group named exactly like the role's key, for example
   `stash_volunteer`. No binding is needed for that.

| Role (catalog key) | Bound group in the shipped file | Can |
| --- | --- | --- |
| `stash_admin` | `stash-admin` | Everything: settings, the Den connection, people, exports, the audit log. |
| `stash_inventory_manager` | `stash-logistics-lead` | Items, sign-outs, locations, categories, departments, purchases, requests (decide), exports. No Lost & Found. |
| `stash_dept_lead` | `stash-dept-lead` | Sign-outs and returns, report damage and loss, exports, ask for gear. |
| `stash_volunteer` | `stash-volunteer` | Look up items, create and return sign-outs, ask for gear. |
| `stash_readonly` | `stash-readonly` | View inventory, sign-outs and the audit log (without guest data). |
| `stash_frontdesk` | `stash-conops` | Log and resolve Lost & Found reports, notify guests on Telegram. |
| `stash_conops_lead` | `stash-conops-lead` | All of Lost & Found, plus reopen, delete, audit and exports. |
| `stash_conops_readonly` | `stash-conops-readonly` | View Lost & Found only. |

Every permission is listed on [Configuration](configuration.md#the-access-config-file).

### Give someone access

1. In HR, give the person the Stash role (for example `stash_volunteer`), or
   add them to the group in Keycloak yourself.
2. They sign in again (or wait for their token to renew, five minutes in the
   local realm): permissions are recalculated on every request from their
   token, so nothing needs restarting.
3. Check: as that person, open Stash; or call `GET /api/me` with their
   token. It returns `"roles": ["stash_volunteer"]` and the permissions.

### Change what a role may do, or add a binding

1. Edit `access-config.toml`. A role listed in the file **replaces** its
   built-in permission set:

    ```toml
    [roles.volunteer]
    description = "Look up items, run sign-outs and ask for gear."
    permissions = ["item.view", "signout.view", "signout.create", "signout.return", "request.create"]

    [[bindings]]
    group = "logistics-crew"
    role = "volunteer"
    ```

2. Update the ConfigMap and restart the backend:

    ```sh
    kubectl create configmap stash-access-config -n conservices-stash \
      --from-file=access-config.toml=access-config.toml --dry-run=client -o yaml | kubectl apply -f -
    kubectl rollout restart -n conservices-stash deploy/stash-backend
    ```

3. Check: `GET /api/role-catalog` lists the role with its permissions and
   group.

The backend refuses to start when the file names an unknown permission or
role, or has a `department_id` on a binding; the log says which line.

### Trying roles in development

With `AUTH_MODE=dev` there is no sign-in. In the browser's developer tools,
set `localStorage["stash.devUser"]` to `bob:volunteer` (or
`carol:frontdesk,readonly`) and reload; a plain name such as `alice` is an
admin. Never run dev mode where anyone else can reach it.

## Settings

**Settings** (admins, `access.manage`) holds Stash-wide choices, stored in
Stash's database. Every change is in the audit log (`settings.update`, with
before and after). While Stash is paired with Den, the settings Den manages
are read-only here and show *Managed in Den*
([which ones](configuration.md#settings-that-den-can-manage)).

**System defaults:**

| Setting | What it does |
| --- | --- |
| Require barcode scan to sign out | Every sign-out line must be scanned. |
| Default item owner | Filled in when an item is created without an owner. |
| Default currency | ISO 4217 code for purchase prices (EUR when empty). |
| Barcode prefix and width | Format of generated asset tags (default `ST` + 6 digits, `ST000042`). |
| Protect Lost & Found report LF-0001 | An easter egg, off by default: the very first report can no longer be edited or removed, and retention skips it. |

**Privacy and notifications:**

| Setting | Default | What it does |
| --- | --- | --- |
| Delete reports | *a number of hours after closing* | [Lost & Found retention](#lost-found-retention). |
| Hours after closing | 720 (30 days) | Used with *after closing*. |
| Last day of the convention, days after | not set, 30 | Used with *after the convention*. |
| Anonymise staff who have not signed in for | 0 (never) | See [People who left](#people-who-left). |
| Telegram bot for Lost & Found | off | See [Telegram](#telegram-notifications-for-guests). |
| Email overdue-return reminders, digest list | off, empty | See [Overdue returns](#overdue-returns). |
| Email server (SMTP) | port 587, STARTTLS | Host, port, user, sender (`Stash <stash@example.org>`) and security. The password is the `SMTP_PASSWORD` secret. |

A value Stash does not accept is refused with a message per field, for
example *default_currency: must be a three-letter ISO 4217 code such as EUR*.

The **Den connection** box on the same page shows whether Stash is paired,
when it last synced and the last error. Pairing steps: [Setup, step 9](setup.md#9-pair-stash-with-den).
Pair, sync and disconnect are in the audit log (`den.pair`, `den.sync`,
`den.unpair`). **Disconnect** returns Stash to standalone: its own settings
and default look.

## Lost & Found retention

Lost & Found reports hold guests' names and contact details, so Stash
deletes them when they are no longer needed. Pick one rule:

- **A number of hours after closing** (default, 720 hours = 30 days): a
  report is deleted that long after it was returned to its owner, closed or
  removed.
- **A number of days after the convention:** every report is deleted that
  many days after the end of *Last day of the convention*. Nothing is
  deleted while that date is not set.
- **Never:** only for testing.

Once an hour the job deletes the report, its photos and its Telegram link,
and replaces the guest's data (name, contact, notes, photo filenames) in
the report's earlier audit entries with `[redacted]`. The deletion itself is
in the audit log as `lostfound.purge`, without guest data.

Separately, the audit log never shows guest data from Lost & Found to people
without `lostfound.view` (for example `stash_readonly`).

## People who left

Stash keeps a row for everyone who signed in, so history can say who did
what. For someone who left:

1. Open **Settings → People** (`user.manage`).
2. Click **Anonymise** next to them and confirm.

Their name, email and identity-provider subject disappear from Stash,
including the audit log and item history, which then say *Former user*.
What they did stays. If they sign in again, they start as a new person.

To do this automatically, set *Anonymise staff who have not signed in for*
(days). Pick a value longer than the gap between two events, for example
400, so returning staff are not anonymised between conventions.

## Telegram notifications for guests

Stash has **its own** Telegram bot, so the desk can tell a guest their item
was found without phoning them.

1. In Telegram, talk to [@BotFather](https://t.me/BotFather), send
   `/newbot`, and pick a name and a username (for example
   `examplecon_lostfound_bot`). BotFather replies with a token such as
   `123456789:AA…`.
2. Store the token as `TELEGRAM_BOT_TOKEN` in `stash-secrets` (your secret
   manager; see [Secrets](../../operations/secrets.md)) and restart
   `stash-backend`.
3. Check the NetworkPolicy lets the backend reach `api.telegram.org` (the
   Kustomize manifests and the Helm chart do by default;
   [network policies](../../operations/network-policies.md)).
4. In **Settings → Privacy and notifications**, tick **Telegram bot for Lost
   & Found** and save.
5. Open a report: it now shows *Telegram: Not linked* and the line the
   guest sends, `/start LF0042`, with a link to the bot.

The guest sends `/start LF0042` (the number from their receipt) to the bot
and gets *Linked to Lost & Found report LF-0042*. The report then shows
*Guest linked*, and people with `lostfound.notify` see **Notify guest**,
which sends the standard message or your own text (up to 1,000 characters).
`/stop` unlinks the guest from every report. Linking, unlinking and every
message are in the audit log (`lostfound.telegram_link`,
`lostfound.telegram_unlink`, `lostfound.notify`); the chat id and the
message text are not. Only one replica polls Telegram (the job leader).

## Overdue returns

Sign-outs with an expected return in the past show in the sidebar for
everyone with `signout.view` (*SO-2026-00012 is overdue*, or *3 sign-outs
overdue*).

To email reminders:

1. Fill in the **Email server** in Settings (or in Den). With the dev stack:
   host `mailpit`, port `1025`, security *None*; the mails appear at
   <http://localhost:8025>.
2. Set `SMTP_PASSWORD` if the server needs a login, and allow egress to it
   (Helm: `networkPolicy.smtp`).
3. Tick **Email overdue-return reminders** and, optionally, add addresses
   for the daily digest (for example `logistics@example.org`).

Once a day per overdue sign-out, Stash emails the person who received the
gear (when Stash knows their email, that is, they were picked as a Stash
user) and sends the digest list one email listing all overdue sign-outs.
Each reminder is audited as `signout.overdue_reminder`.

## Before the event

1. Create the **departments** (who borrows things), **locations**
   (buildings, rooms, shelves; locations can be nested) and **categories**.
   Only people with the matching manage permission can create them, also
   from the item form.
2. Add items one by one, or many at once on **Import & export**: download
   the items export, fill in rows (no `id` for new items), **Check file**,
   then **Import**. Nothing is saved unless every row is fine. Record what
   you bought on each item's **Purchases**, and attach receipts, manuals and
   warranties under **Documents**.
3. Print labels from the item page: a barcode for USB scanners or a QR code
   that any phone camera opens.
4. Make **packing lists** for events or departments.
5. Check that each team lead has the right role (sign in as a test user, or
   call `GET /api/me`).

## During the event

- **Sign-outs and returns:** see the
  [Volunteer and front-desk guide](volunteer-guide.md).
- **Requests:** people ask for gear on **Requests**; approve, mark ordered,
  fulfil or reject them there (`request.manage`).
- **Lost & Found:** the front desk logs items with a photo; each gets a
  report number and a label. Turn on the guest lookup page only when kiosks
  are ready (`PUBLIC_LOSTFOUND_CLAIM_ENABLED` on the backend and
  `publicClaimEnabled` in the web app's `/config.json`; the Helm chart sets
  the second from the first). Guests see only the report number, the item
  name and the day it came in.

## After the event

- **Exports** (`export.create`) on **Import & export**: all items, all
  sign-outs, and the reports *Low stock*, *Damaged*, *Lost*, *Expiring*,
  *Retired* and *Overdue sign-outs*. The Lost & Found datasheet is on the
  Lost & Found page (`export.create` and `lostfound.view`). Every export is
  in the audit log. Spreadsheet formulas in cells are neutralised with a
  leading `'`.
- **Audit log** (`audit.view`): every change with who, when, before and
  after, filterable by action and type (`item`, `signout`, `lostfound`,
  `file`, `settings`, `den`, `export`, `user`, …).
- **Retention** runs by itself; check that *Last day of the convention* is
  set if you use *after the convention*.
- **Backups:** on the platform Den's operator backs up the `stash` database
  and, if listed in `FILES_S3_BUCKETS`, the bucket every night. Standalone,
  backups are your job ([Setup](setup.md#standalone-on-kubernetes)).

## After installing: checklist

1. Sign in through Keycloak; you appear on **Settings → People**.
2. `GET /api/role-catalog` lists the `stash_*` roles with the groups you
   expect.
3. A test user with only `stash_readonly` cannot open Settings and sees no
   guest names in the audit log.
4. Upload a photo and a PDF to an item: the photo shows on the page, the PDF
   downloads instead of opening.
5. The bucket is private: the object URL without a signature answers 403.
6. The backend log shows `jobs: this replica is the leader` on exactly one
   replica.

## Troubleshooting

**Someone has the wrong permissions.** Call `GET /api/me` with their token:
`roles` and `permissions` show what Stash computed. Compare their token's
`groups` claim (not `roles`) with the `[[bindings]]` and the `stash_<role>`
names. Matching ignores case and one leading `/`, so `/Stash-Admin` is
`stash-admin`. With `OIDC_GROUP_MATCH=last`, only the last path segment
counts. A parent in `OIDC_GROUP_PREFIX` is removed first.

**The backend does not start: "department_id is not supported; roles are
global".** Remove the `department_id` line from that binding in
`access-config.toml`.

**"is managed in Den (Admin → Module settings)" when saving settings.** Stash
is paired and Den sets that key; change it in Den → Admin → Module settings,
or remove the key there. The last day of the convention stays in Stash.

**Den connection shows "Den rejected this module's credential".** The module
was removed or its credential revoked in Den. Create a new pairing URL in
Den and pair again.

**No "Telegram" box on reports.** The bot is off in Settings, or
`TELEGRAM_BOT_TOKEN` is empty: `GET /api/lostfound/telegram` answers
`"configured": false`.

**"Telegram did not accept the message".** The guest blocked the bot or
deleted the chat. Ask them to send `/start` with the report number again.

**The guest gets no answer to `/start`.** Check that one backend logs
`jobs: this replica is the leader`, that the log has no `telegram: poll
failed`, and that egress to `api.telegram.org:443` is allowed. With Rally
or Learn: each module needs its own bot; two programs reading one bot's
messages steal them from each other.

**No overdue emails.** Overdue emails are on, *Email server* has a host and
a sender, and the receiver was picked as a Stash user (a typed name has no
email). The log shows `overdue: email to receiver failed` with the SMTP
error. Each sign-out is reminded at most once a day.

**A deleted Lost & Found report was still needed.** Retention cannot be
undone; restore the database backup into a separate database if it matters.
Lengthen the retention for the next event.
