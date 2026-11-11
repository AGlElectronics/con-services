# Den admin guide

This guide walks through Den from an administrator's point of view: what
each page is for and how to use it. It assumes Den is running and you can
sign in as an administrator (see
[Run Den on Kubernetes](../../getting-started/den-quickstart.md)).

## Who sees what

Den has two areas:

- the **portal** at `/dashboard`, for everyone with the `member` or `admin`
  role;
- the **admin console** under `/admin`, for `admin` and `owner` only. The
  API enforces this too, so hiding a button is never the only protection.

Roles come from Keycloak groups: `den-admin` makes you an admin,
`den-member` a member, and `den-ops` gives the **ops** role (all three group
names are configurable). The ops role is separate from admin: only people
with it can run, schedule and download backups and delete a module's
database. Admins without it see the Backups page read-only. A Den serves one
organisation; another convention runs its own Den. See
[Authentication](../../concepts/authentication.md#from-groups-to-roles).

Members see only the services they can use: a module whose role catalog
names one of their groups, or a module set to *Every member* (see
[Editing a module](#editing-a-module)). Only admins see the counts on the
Overview page.

## The portal

The portal home is the first page people see after signing in. From top to
bottom it shows:

- the **welcome** line, the **convention name** and the **tagline**, all
  taken from the branding [copy](#copy-wording);
- an **Admin console** button, for admins only;
- **To-dos** collected from the services (see below);
- **Your services**: a card for each module that is *enabled*, *paired* and
  has an *address*. Unpaired modules, or modules without an address, are not
  shown to members;
- **Quick links** to the same services, and the legal footer if you set one.

The theme switch (system, light or dark) in the top bar is saved in Den and
shared with every paired module.

### Portal to-dos

The portal shows things the signed-in person should do in the services they
can use, in one list, sorted by due date and then severity. Den's backend
asks each module itself (the browser only talks to Den, and the person's
token never leaves Den): it calls `GET <module address>/api/portal/todos`
with the module's pairing credential and the person's issuer and subject
(the exact request is in the
[API reference](api.md#get-apiv1portaltodos)), and expects:

```json
{
  "items": [
    {
      "id": "shift-42",
      "title": "Confirm your Saturday shift",
      "detail": "Info desk, 10:00–14:00",
      "due_at": "2026-11-14T10:00:00Z",
      "url": "https://hr.conservices.test/shifts/42",
      "severity": "warning"
    }
  ]
}
```

`severity` is `info`, `warning` or `danger` (anything else counts as `info`),
`url` must be an `http` or `https` link, and `due_at` may be `null`. Modules
that do not answer within 5 seconds, answer with an error, or do not support
the request are skipped. The list refreshes every 5 minutes. To-dos need
`DEN_CREDENTIAL_KEY` on Den's backend
([Configuration](configuration.md#calling-modules-portal-to-dos)); a module
paired before that key was set must be paired again.

## The admin console

The admin console has its own menu on the left:

| Page | What it is for |
| --- | --- |
| **Overview** | Counts of paired modules, modules waiting to pair, services live on the portal and people with a role, with shortcuts. |
| **Modules** | Add, edit, pair and remove modules; see and revoke their credentials. |
| **Branding** | Colours, fonts, wording, logo, favicon, sign-in background, Keycloak name sync. |
| **Organisation** | The organisation settings document. |
| **Module settings** | Settings Den hands to modules: retention, e-mail, Finance, Stash, Wiki, Tasks, Rally, and Den's own identity links. |
| **Backups** | Backup status, schedule and downloads (ops role); the database list. |
| **Audit log** | Every change made in Den, who made it and when. |
| **Settings** | The sign-in mode, the dev user name (dev mode only) and version information. |

When **Module settings → Identity links** has an identity provider admin
console address, the menu links to it (for example the Keycloak admin
console, where you manage accounts and groups). A warning sign next to
**Backups**, and a banner, appear whenever backups need attention.

## Modules

The **Modules** page lists every module registered in Den, with its
environment, its status (`unpaired` or `paired`) and, when Den manages
databases, its database and size.

### Adding a module

1. Click **New module**.
2. Fill in the form:

    | Field | Meaning | Example |
    | --- | --- | --- |
    | **Short name** | The module's *slug*: lowercase letters, digits and single hyphens, unique. | `hr` |
    | **Display name** | The name people see on the portal. | `HR` |
    | **Address** | The module's public web address, `https://`. The portal links here. Leave it empty and the module will not appear on the portal. | `https://hr.example.org` |
    | **Environment** | A free label, `production` by default. The same slug can be registered once per environment. | `production` |
    | **Server address** | Optional. Where Den's backend itself reaches the module (its role catalog and to-dos), usually its in-cluster address. Empty: the address above. | `https://hr-backend.conservices-hr.svc.cluster.local:8080` |
    | **Shown on the portal to** | *People with a role in the module* (default) or *Every member*. | People with a role |
    | **Create a database for it** | Only shown when Den manages databases. Den creates a database and login for the module. | ticked |

    Addresses must start with `https://`; `http://` is only accepted when Den
    runs with `APP_ENV=development`.

3. Click **Create module**.

If you ticked **Create a database for it**, Den shows a yellow box with the
new database's connection URL, **once**:

```text
postgres://hr:3f9c…e1@postgres.conservices-data.svc.cluster.local:5432/hr?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt
```

The host in it is the operator's `MODULE_DB_HOST` (on Kubernetes, the
in-cluster name of PostgreSQL). Copy it into the module's `DATABASE_URL`
secret before you start the module; the full walkthrough with Stash is in
[How the platform starts](../../getting-started/how-the-platform-starts.md#step-4-deploy-a-module-stash). The database is named after the slug, with hyphens turned into
underscores; it must start with a letter and use only lowercase letters,
digits and `_` (2 to 41 characters). Den refuses names of protected
databases such as `den` or `keycloak`.

### Pairing a module

Pairing makes a module follow Den's brand and settings. How it works is
explained in [Pairing](../../concepts/pairing.md). Step by step:

1. Make sure the module is running and you can sign in to it as its
   administrator.
2. In Den → **Modules**, click **Pair** on the module's row.
3. Den shows a yellow box: **One-time pairing URL**. Click **Copy**.

    !!! warning "Shown once, valid for 15 minutes"
        The URL works exactly once and expires after 15 minutes. If you
        lose it or it expires, click **Pair** again for a new one.

4. In the module, open its Den connection settings and paste the URL:

    | Module | Where |
    | --- | --- |
    | HR | Settings → Den connection |
    | Stash | Settings → Den connection |
    | Rally (Events) | Organizations → Den connection |
    | Learn | Settings → Den connection |

5. Save. The module contacts Den, receives its credential and syncs right
   away. Within a few seconds it shows Den's name, logo and colours, and its
   organisation settings show as *Managed in Den*.
6. Back in Den, reload **Modules**: the module's status is now **paired**,
   and if it has an address it appears on the portal.

If the module reports that Den refused the URL, the message says why:
the token was already used, it expired, it was not copied completely, or it
was made for another module (Den checks the module's id and short name when
the module sends them). Make a new one, or paste it into the right module.

Pairing a module again replaces its credential: the new one works and every
older one stops working at once. Den never pairs a module by itself; if a
module reports that Den refused its credential, pair it again by hand.

### Credentials

Click **Credentials** on a module's row to see the credentials it was given
when it was paired: when each was made, when it was last used, and whether
it is still active. Normally only the newest is active.

- **Revoke** one credential, or **Revoke all credentials**, when one may
  have leaked (for example a copied configuration or a lost backup of the
  module). The module is disconnected from Den straight away: it stops
  receiving the brand and settings, and its calls to Den are refused.
- A module left without an active credential shows as **unpaired**. To
  connect it again, click **Pair** and paste the new URL into the module.

The full procedure for a leaked pairing URL or credential is in
[Disaster recovery](../../operations/disaster-recovery.md#a-pairing-url-or-module-credential-leaked).

### Editing a module

Click **Edit** to change a module's display name, addresses, environment, the
**Enabled** switch (off hides it from the portal) and who sees it on the
portal:

- **People with a role in the module**: Den reads the module's role catalog
  (`/api/role-catalog`) and shows the module to members who have one of its
  groups. If Den cannot read the catalog at the module's server address,
  members do not see it.
- **Every member**: for modules everyone may use without a role, such as
  Learn (anyone can take a course).

The same setting decides which people's theme preference the module may
read from Den.

### Removing a module

Click **Remove** on the module's row. Den asks twice before deleting
anything:

1. **What happens to the data.**
    - **Remove and delete its data**: the operator backs the database up
      first, then deletes it and its login. If the backup fails, nothing is
      deleted. This is only offered when **Den created** the module's
      database (with *Create a database for it*), the database is not
      protected, and you have the **ops** role; otherwise the dialog says
      why it is not offered.
    - **Remove only, keep its data**: the module is unregistered and its
      database stays where it is, so you can add and pair it again later.
2. **Type the module's short name** to confirm deleting the data.

Either way the module is disconnected from Den straight away: its pairing
credentials are removed, so it stops receiving the brand and settings. Files
in the module's bucket are never touched. Removals are written to Den's
audit log, including the name of the backup made before deletion. More
detail in
[Databases, backups and restore](../../operations/databases-and-backups.md#adding-and-removing-modules).

## Branding

The **Branding** page decides how Den, every paired module and the Keycloak
sign-in page look. It has a JSON editor with three tabs, a live preview, the
assets, the sign-in background and the Keycloak name sync status.

Each tab edits one JSON document. Next to the editor, a table lists every
key Den understands, what it changes, and its current value; click **add**
to insert a key with its default, or use the colour pickers. **Save new
revision** saves all three documents as a new revision; the revision number
and date are shown at the top. **Reset** throws away unsaved edits.

Keys Den does not know are kept and passed on to paired modules, but Den's
own pages ignore them.

### Theme (colours)

| Key | Changes | Default |
| --- | --- | --- |
| `primary` | Buttons, links, the active menu item, icons on service cards. | `#5048e5` |
| `primary_hover` | Hover state of buttons and links. | `#4338ca` |
| `accent` | Start of the hero gradient, icon tiles, active menu background. | `#e0e7ff` |
| `background` | Cards, the top bar and panels (the "surface"). | `#ffffff` |
| `muted` | Page background behind the cards, end of the hero gradient. | `#f5f5f7` |
| `foreground` | Body text and headings. | `#1c1b22` |
| `border` | Card outlines and dividers. | `#e4e4e7` |

Colours may be written as hex (`#e44763`) or with `rgb(...)`, `hsl(...)`,
`oklch(...)` or `color(...)`.

**Dark mode.** Den derives dark-mode colours from the ones above, so dark
mode always matches your brand. To override a colour in dark mode, set it
under `theme.dark`; the keys are the same, plus `page` (the page background
behind the cards):

```json
{
  "primary": "#e44763",
  "background": "#ffffff",
  "dark": {
    "background": "#16151a",
    "page": "#0f0e12"
  }
}
```

### Typography (fonts)

| Key | Changes | Default |
| --- | --- | --- |
| `heading_font` | The convention name, section titles and card titles. | `Montserrat` |
| `body_font` | All other text. | `Inter` |

Den bundles **Inter** and **Montserrat**. Any other font name only works if
the font is installed on the viewer's device.

### Copy (wording)

| Key | Changes | Default |
| --- | --- | --- |
| `convention_name` | The big title on the portal home. Without it, the organisation's name is used. | the organisation name |
| `welcome` | The small line above the title. | `Welcome` |
| `tagline` | The line under the title, after "Hi *name* —". | `Your home for inventory, events, and crew tools.` |
| `legal_footer` | Small print at the bottom of the portal. Hidden when empty. | empty |
| `login_layout` | How sign-in screens with a background picture look: `panel` docks the form on the right, `centered` keeps it in a card in the middle. Phones always get the card. | `panel` |
| `login_caption` | Words shown over the sign-in background picture. Hidden when empty. | empty |

Example:

```json
{
  "convention_name": "Example Con 2027",
  "welcome": "Welcome back",
  "tagline": "Everything the crew needs, in one place.",
  "legal_footer": "Example Con e.V. · Imprint · Privacy",
  "login_layout": "panel",
  "login_caption": "See you at the con!"
}
```

### Assets

| Role | Used for | Tips |
| --- | --- | --- |
| `logo` | Module headers and the sign-in page. | SVG or PNG with a transparent background. |
| `favicon` | The browser tab icon. | Square PNG or SVG. |
| `login-background` | The picture behind every sign-in screen. | Landscape JPG or WebP, about 1920 × 1080, ideally under 2 MB. |

Upload with **Upload** (or **Replace**). Files may be up to 10 MB and must be
PNG, JPEG, WebP, ICO or SVG; Den checks the file itself, not its name. SVG
files are only ever shown as images, never opened as pages. The newest
upload of each role is the one in use, and it is live as soon as it is
uploaded; **Remove** deletes it. Paired modules and the sign-in page fetch
the files through Den, so no module ever needs access to Den's storage.

The **Sign-in background** section previews the picture with the chosen
layout and caption. The layout and caption are part of the copy JSON, so
click **Save new revision** to publish them.

### Keycloak sync

The Keycloak sign-in page follows the brand by itself: the `conservices`
login theme fetches Den's public brand (organisation name, tagline, colours,
logo, favicon, background picture, layout and caption) each time the page
opens, and draws the page in light and dark mode. Changes show up on the
next page load. For that, Keycloak needs:

- the `conservices` theme files (the Kubernetes manifests mount them from
  the `keycloak-theme` ConfigMap, built from
  `infra/keycloak/themes/conservices`), selected as the realm's login theme
  (the realm import does this);
- the environment variable `DEN_PUBLIC_URL` with Den's public address.

Den itself needs no access to the realm for this. The card **Sign-in page
(Keycloak)** at the bottom of the Branding page is about one optional extra:
the realm's **display name**, which Keycloak uses in its own e-mails (for
example the password-reset mail). When a Keycloak admin client is set up,
Den sets it to the organisation name when it starts, right after every
branding or organisation settings change, and every 5 minutes (which also
undoes manual edits in the Keycloak console). After a failure it retries
after 15 seconds. **Sync name now** syncs immediately and shows the result.

The card shows one of:

- *Realm conservices is named Example Con …, synced …*: all good;
- *Last realm name sync failed: …*: the error from Keycloak; see
  [the runbook](../../operations/disaster-recovery.md#the-keycloak-name-sync-fails);
- *Realm name sync is off*, with the reason: either no Keycloak admin client
  is configured (fine: the sign-in page is branded anyway), or Den runs with
  `IDENTITY_STAFF_MODE=existing`, where the realm belongs to your convention
  and Den never changes it.

The name sync needs a confidential Keycloak client whose service account has
the `realm-management` role `manage-realm` (Keycloak has no smaller role that
can rename a realm). The local realm ships one, `den-keycloak`. Leave it out
if you do not want Den to have that access.
See [Configuration](configuration.md#keycloak-login-branding).

The organisation name is chosen in this order: `organization_name` from the
organisation settings, then `convention_name` from the copy, then the
organisation's name in Den's database.

## Organisation settings

The **Organisation** page holds one JSON document of settings that apply to
the whole organisation. Paired modules read it (within a minute of a change)
and show the keys they use as *Managed in Den*. Standalone modules keep
their own settings pages.

Edit the JSON on the left; the table on the right lists the keys Den knows,
with **add** buttons. **Save** stores it; if a value is invalid, Den rejects
the whole document and lists the problems under the editor.

### Known keys

`organization_name` (text)
:   The organisation's name, shown in emails (for example HR's
    account-deleted notice) and on the sign-in page. With the
    [Keycloak name sync](#keycloak-sync) on, it is also the realm's display
    name.

`org_email_domain` (text)
:   The organisation's email domain, for example `example.org`. HR builds
    organisation email addresses as *name*`@`*this domain*. Den lowercases
    it and removes a leading `@`; it must look like a domain name.

`org_email_template` (text)
:   HR's suggestion for the part of an organisation email address before
    the `@`, for example `{first}.{last}`.

`username_template` (text)
:   The login name HR gives new Keycloak accounts, for example
    `{nickname}`. Existing accounts keep their login name.

`events_public_schedule` (`true` or `false`)
:   Whether Rally (Events) serves the published schedule publicly, as JSON
    and iCal, for the convention's website. `false` hides it.

`wiki_public_links` (`true` or `false`)
:   Whether people with full access in the Wiki may share pages through
    public links. `false` turns every public link off.

**Templates** may contain letters, digits, `.`, `-`, `_` and the
placeholders `{first}`, `{last}` and `{nickname}`, and must use at least one
placeholder.

Rules for every key:

- A key that is missing means "use each module's own default".
- Setting a key to `null` removes it.
- Keys Den does not know are kept and passed on to modules, so a module can
  introduce its own setting without a Den release.

Example:

```json
{
  "organization_name": "Example Con e.V.",
  "org_email_domain": "example.org",
  "org_email_template": "{first}.{last}",
  "username_template": "{nickname}",
  "events_public_schedule": true,
  "wiki_public_links": false
}
```

If something is wrong, Den answers with the problems per key, for example:

```text
org_email_domain: must be a domain like example.org
username_template: unknown placeholder {surname} (use {first} {last} {nickname})
```

Saving also triggers a [Keycloak name sync](#keycloak-sync).

## Module settings

The **Module settings** page holds settings Den hands to paired modules, in
the same bundle they already fetch every minute. Each module gets the
shared parts and only its own part, and shows those values as *Managed in
Den*. A field you leave empty means "the module decides". Click **Save**;
if a value is not valid, the message appears under the field.

| Section | What it is | Who gets it |
| --- | --- | --- |
| **Retention** | How long HR keeps offboarded volunteers, how long unused accounts stay, and how long old module data is kept (days). The suggested numbers are **pending legal review**: they have not been checked against data-protection law yet. | every module |
| **E-mail (SMTP)** | Server, port, security, sender and user name for the e-mails modules send. The password is not typed here. The page says *Password: configured in Den's secret (DEN_SMTP_PASSWORD)* or *Password: not set*, and links to the configuration page. Modules fetch the password separately when they send mail; it is not in the bundle. | every module |
| **Finance: seller details** | Legal name, address, country, VAT ID and the other details printed on invoices and receipts. | Finance |
| **Stash: Lost & Found** | Either *kept for N days after the con* or *deleted N hours after closing*. | Stash |
| **Wiki** | How many days old page revisions are kept. `0` keeps every revision. | Wiki |
| **Tasks** | How long trash, read notifications, the audit log and automation history are kept, and how many days before a due date a reminder is sent. | Tasks |
| **Rally: submission site** | The host name attendees submit events on, for example `submit.example.org`. Rally's address in Den may be the slug `events`; it still receives this section. | Rally |
| **Identity links** | The name of your sign-in (SSO), the "manage my account" address (password, two-factor) and the identity provider's admin console. | Den only: the menu and the portal. No module receives this. |

The SMTP password is Den's secret `DEN_SMTP_PASSWORD` (a key of
`den-secrets`) or the file `DEN_SMTP_PASSWORD_FILE`. It is not stored in
Den's database. A module fetches it, when it sends mail, from Den with its
pairing credential. It is not in the bundle. See
[Secrets](../../operations/secrets.md) and the
[module settings contract](../../concepts/module-settings.md). Changes to
the other fields are written to the [audit log](#audit-log). The password
is not, because this page cannot change it.

## Audit log

The **Audit log** page lists every change made in Den, newest first: who did
it, what (for example `module.update`), on which item, and a note. Click the
arrow on a row to see the values before and after. Filter by kind of change
(modules, pairing, branding, settings, backups, Keycloak), by an item's id or
by date; **Show older events** loads the next page.

*System* in the *Who* column means Den did it by itself, for example
registering a module from `DEN_PREREGISTER_MODULES`. For a pairing redeem the
person shown is the admin who created the pairing URL. Credentials, tokens and
passwords are never in the log. The same data is available from
[`GET /api/v1/audit-events`](api.md#get-apiv1audit-events).

## Backups

The **Backups** page is the front end of Den's operator. Running, scheduling
and downloading backups needs the **ops** role (group `den-ops`); admins
without it see the status and the database list only, with a note saying
so. It shows:

- **Last backup**: whether it succeeded, when, how big, and how many
  databases and file stores it contained;
- **Next backup**: when the next scheduled backup runs;
- **Stored in**: where backups go, and for how many keys they are encrypted;
- **Schedule and how long backups are kept**: the hour of the daily backup
  (in the operator's time zone) and how many daily, weekly and monthly
  backups to keep;
- **Databases**: every database on the server with its size, and which are
  never deleted by Den;
- **Stored backups**: every backup, with a **Download** button. Downloads are
  encrypted and can only be opened with the secret backup key. Each click
  makes a one-time link that works for 5 minutes; backups, schedule changes
  and downloads are written to the [audit log](#audit-log).

**Back up now** starts a full backup immediately. If the page says **Not set
up**, Den runs without an operator; if it says **Operator unreachable**,
check the operator with `kubectl logs -n conservices-den deploy/den-operator`
and see [Troubleshooting](../../getting-started/troubleshooting.md#den-shows-cant-reach-the-operator).

A red banner appears (here and on every admin page) when the last backup
failed, when there has never been a backup, or when the last good backup is
more than 26 hours old.

There is deliberately no restore button. Restoring is a command-line job,
described with everything else about backups in
[Databases, backups and restore](../../operations/databases-and-backups.md).

## Settings

The **Settings** page shows how this Den was built: the sign-in mode (`oidc`
or `dev`), the version and the API address. In dev mode it also lets you
change the dev user name the browser sends (stored only in this browser).
