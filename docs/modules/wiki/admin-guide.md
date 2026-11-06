# Wiki admin guide

This page is for the people who look after Wiki: who can do what, how
sharing works, and the few admin screens. Installing Wiki is on
[Setup](setup.md).

## Roles

Wiki has only two roles. They come from Keycloak groups, through the
[access config file](configuration.md#access-config-file), and are checked
on every request: removing someone from a group takes effect on their next
click.

| Keycloak group | Role | May do |
| --- | --- | --- |
| `wiki-admin` | `organization_admin` | Full access to every **team** space and page; the Den connection. |
| `wiki-editor` | `space_creator` | Create team spaces (and gets full access to the ones they create). |

There is deliberately no "reader" group. **Reading and editing pages is not
a role**: it comes from sharing inside Wiki. In HR's access picker, these
two roles appear because Wiki publishes them at `/api/role-catalog`.

!!! note "Private spaces stay private, even from admins"
    `wiki-admin` does not see anyone's private space. The only exception is
    [offboarding](#offboarding).

## Access levels

Everything in Wiki is shared at one of four levels:

| Level | Can |
| --- | --- |
| **View** | Read the page and its files, see comments. |
| **Comment** | View, plus write comments, resolve threads and react. |
| **Edit** | Comment, plus change the page, upload files, create sub-pages, restore revisions. |
| **Full** | Edit, plus share, restrict, rename, trash and delete forever. |

## Spaces

- **Private space:** everyone gets one on first sign-in. Only its owner sees
  it. Single pages from it can still be shared.
- **Team spaces:** created by `wiki-editor` or `wiki-admin` with the **+**
  next to **Team spaces** in the sidebar. They start **closed**: only the creator (with full
  access) and Wiki admins see them until they are shared.

## Sharing

Open a space or page and click **Share**. You can give a level to:

- **a person** (search by name);
- **a Keycloak group**, for example a department group such as
  `dept-front-of-house` that HR maintains;
- **everyone signed in** (a space's or page's "everyone" level).

Pages **inherit** the access of their parent page or space and can add
grants of their own. Someone with a grant on one page in a space they
otherwise cannot see finds it under **Shared with you**.

Pages and spaces you cannot see answer "not found", not "forbidden", so
their titles never leak.

### Restricted pages

Tick the restrict option in a page's share dialog to stop it inheriting
access (restricted pages show a lock icon).
Then only the page's own grants apply, to it and everything under it.
`wiki-admin` keeps access. If restricting would lock you out, Wiki gives you
a full grant on the page first.

## Trash

Each space has a trash page listing its trashed pages. Trashing needs
full access, or edit access on a page you created; the same goes for
restoring. **Delete forever** needs full access and removes the page's
content from storage.

## History

Every page keeps automatic revisions, at most one per 10 minutes of
editing. Open a page's history panel to preview a revision and restore it
(needs edit access). People who have the page open are reloaded onto the
restored version; the replaced state is kept as a revision too.

## Public share links

A public share link shows a page read-only, optionally with its sub-pages,
to anyone with the URL, without an account. Use them for things like a
public FAQ.

1. **Allow them for the organisation.** They are off by default. With Den,
   set the organisation setting `wiki_public_links` to `true` in Den's
   organisation settings. Without Den, set `PUBLIC_LINKS_ENABLED=true` on
   the backend.
2. **Create a link:** open the page's **Share** dialog. In the public links
   part, tick **Include sub-pages** if wanted, pick an expiry (never, 7, 30
   or 90 days) and click **Create link**. Needs full access on the page.
3. **Copy the URL now.** It is shown once; Wiki stores only a hash of the
   token.
4. **Revoke** a link from the same dialog at any time.

Public links are rate limited per visitor and marked so search engines do
not index them. When the feature is switched off again, every link stops
working (and answers "not found") until it is switched back on.

## Offboarding

When HR deletes someone's account, it calls Wiki's offboarding hook (set up
in [Setup, step 8](setup.md#option-1-kubernetes-platform-recommended)).
Then:

1. The person's **private space is handed to the Wiki admins**: it appears
   in their sidebar under **Offboarded**.
2. Admins can move or share anything worth keeping during the grace
   period (`WIKI_OFFBOARD_GRACE_DAYS`, 30 days by default).
3. An hourly sweep then deletes the space and everything in it.

Pages the person created in team spaces are not affected.

## Settings → Den connection

Only Wiki admins see **Settings**. Its one card, **Den connection**, pairs
Wiki with Den so it uses the organisation's brand, theme and settings (such
as `wiki_public_links`):

1. In Den: **Admin console → Modules → Pair** on the Wiki row. Copy the URL.
2. In Wiki: **Settings → Den connection**, paste it and click **Connect**.
3. The card shows the pairing and the last sync time. **Sync now** fetches
   Den's brand and settings immediately (otherwise every minute).
   **Disconnect** returns Wiki to its own settings and default look.

See [Pairing](../../concepts/pairing.md).

## Backups

Page content is stored **only in the bucket**; the database holds the
structure, grants, comments and search text. With Den's operator, make
sure the Wiki bucket is in `FILES_S3_BUCKETS`. Standalone, back up both
yourself. See [Databases, backups and restore](../../operations/databases-and-backups.md).

## Troubleshooting

**Someone cannot see a space they should.** Check the space's share dialog:
is the person, one of their Keycloak groups, or "everyone signed in"
listed? Group names must match the `groups` claim exactly. Then check for a
restricted page above the one they want.

**An admin cannot see someone's private space.** By design; only
offboarding hands it over.

**"Shared with you" shows a page but not its space.** Also by design: the
grant is on that page only.

**Public link says "not found".** Links are switched off for the
organisation, the link was revoked or has expired, or the page is in the
trash.
