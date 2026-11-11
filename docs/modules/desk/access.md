# Access: who may do what in Desk

Desk decides access from the **Keycloak groups** in your sign-in token, like
every Con Services module. There is one module-wide role, **Desk admin**,
and **three roles per mailbox**. HR shows all of them in its access picker,
so you normally grant them there; adding someone to the Keycloak group by
hand works the same.

Terms used on this page:

- **Mailbox slug**: the short name of a mailbox that its roles and groups
  are named after, for example `support` for `support@example.org` or
  `lost-found` for `lost.found@example.org`. It is set when the mailbox is
  created and never changes.
- **Role catalog**: the list of roles Desk publishes at
  [`GET /api/role-catalog`](api.md#get-apirole-catalog); HR reads it live.

## The roles

| Role | Keycloak group | May |
| --- | --- | --- |
| **Desk admin** (`organization_admin`) | `desk-admin` | Everything, in every mailbox of the organization: create, configure, delete and purge mailboxes, read and answer every conversation, delete and restore, start conversations, retention settings, the audit log, the Den connection. |
| Mailbox **viewer** (`desk_<slug>_viewer`) | `desk-<slug>-viewer` | See the mailbox and read its conversations, customers and attachments. Star conversations. |
| Mailbox **manager** (`desk_<slug>_manager`) | `desk-<slug>-manager` | Also reply, note, forward, assign, change status, tag, merge and move, start conversations with any address, use and edit the mailbox's saved replies, and change its signature and auto-reply. Edit customers who wrote to the mailbox. |
| Mailbox **delete** (`desk_<slug>_delete`) | `desk-<slug>-delete` | Delete emails and conversations (to Desk's trash and the provider's trash), see the mailbox's **Trash** folder and restore from it. |

The three mailbox roles are **independent**: `delete` does not include
`manager`. Someone who answers and cleans up needs both groups.

Example for the mailbox `registration@example.org` (slug `registration`):

| Person | Groups | Result |
| --- | --- | --- |
| Head of registration | `desk-registration-manager`, `desk-registration-delete` | Answers and deletes registration mail. |
| Registration volunteer | `desk-registration-manager` | Answers registration mail, cannot delete. |
| Board member | `desk-registration-viewer` | Reads along. |
| IT lead | `desk-admin` | Sets up mailboxes; sees every mailbox. |

## How access is checked

- On **every request**, from the groups in the token. Removing someone from
  a group takes effect on their next request (their next token refresh, at
  most a few minutes).
- Group names are compared without a leading `/` and without regard to
  case, so Keycloak's full group paths (`/desk-support-manager`) work.
- A mailbox, conversation, customer or attachment you have no role for
  answers **404**, as if it did not exist. One you can see but not change
  answers **403** with the role you are missing, for example
  `you need the manager role of this mailbox`.
- Desk admin is checked per organization: an admin of one organization
  does not see another organization's mailboxes.
- Assignees must be able to work the mailbox: you can only assign a
  conversation to someone with its `manager` role (or a Desk admin), and
  only people who have signed in to Desk at least once appear in the
  assignee picker.

## Grant access

### With HR (recommended)

1. Create the mailbox in Desk (as `desk-admin`). Its three roles appear in
   HR's access picker right away, labelled with the mailbox name, for
   example "Registration manager".
2. In HR, open the person and add the role. HR adds them to the Keycloak
   group, creating the group the first time.
3. The person signs out and in again (or waits for their token to refresh)
   and sees the mailbox in Desk's sidebar.

### With Keycloak directly

1. In the Keycloak admin console, realm `conservices`: **Groups → Create
   group**, name `desk-registration-manager`.
2. **Users →** the person **→ Groups → Join group**, pick the group.
3. The person signs in again.

Check what Desk sees with [`GET /api/v1/me`](api.md#get-apiv1me): it lists
every mailbox you can see with your rights in it.

```sh
curl -s -H "Authorization: Bearer $TOKEN" $DESK/api/v1/me
```

```json
{
  "display_name": "Alice Example",
  "is_admin": false,
  "mailboxes": [
    {"id": "c7e2a1d0-…", "slug": "registration", "name": "Registration",
     "email": "registration@example.org",
     "access": {"view": true, "work": true, "delete": false, "admin": false}}
  ]
}
```

## The access config file

Only the module-wide roles are in the access config file
(`infra/access-config.toml` in the Desk repository, mounted as the
ConfigMap `desk-access-config` on Kubernetes). Mailbox roles are not: they
come from the mailboxes themselves.

```toml
organization = "demo-org"

[roles.organization_admin]
description = "Desk admin: creates, configures and deletes mailboxes; full access to every mailbox."
permissions = ["mailbox.manage", "settings.manage"]

[[bindings]]
group = "desk-admin"
role = "organization_admin"
```

| Permission | Allows |
| --- | --- |
| `mailbox.manage` | Desk admin: everything in every mailbox of the organization, mailbox setup, trash and purge, retention, audit log. |
| `settings.manage` | The Den connection (pairing). |

Change `organization` to your organization's slug in Den. The backend reads
the file once at start; restart it after a change.

## Troubleshooting

**Someone was added to `desk-<slug>-manager` but does not see the
mailbox.** Their token is older than the change: sign out and in again.
Then check the slug: it is the mailbox's slug, not its address (see the
mailbox card under **Mailboxes**, or `roles` in
[`GET /api/v1/mailboxes`](api.md#get-apiv1mailboxes) as Desk admin). Also
check that the realm's `groups` mapper puts groups into the token: decode
the token at a JWT viewer and look for `groups`.

**"you need the manager role of this mailbox".** The person has only
`viewer` (or only `delete`). Add `desk-<slug>-manager`.

**The Trash folder is missing.** It is only shown to people with the
mailbox's `delete` role and Desk admins.

**An old `desk-agent` group does nothing.** That role was removed before
1.0.0; grant the per-mailbox groups instead and delete `desk-agent`.

**"only Desk admins may do this".** Creating, configuring, deleting and
purging mailboxes, retention and the audit log are for `desk-admin` only.
