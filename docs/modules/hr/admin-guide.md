# HR admin guide

This page is for the people who use HR day to day: onboarding volunteers,
changing their access and offboarding them. For installing HR see
[Setup](setup.md).

## Roles

HR has three roles of its own. Which one you have depends on your groups in
the identity provider (IdP, on the platform: Keycloak):

| Role | Group (default) | What you can do |
| --- | --- | --- |
| **Admin** | `hr-admin` | Everything: people, departments, access groups, settings, the Den connection, imports, the audit log, assigning admin roles of other modules, offboarding and banning. |
| **Viewer** | `hr-viewer` | Read people, departments, onboardings and the audit log. Change nothing. |
| **Lead** | `hr-lead` | Only in the departments an admin made you lead of: read people, edit their profile, onboard, change access (not admin roles), pause and reactivate, work the review queue. |

The group names come from `HR_ADMIN_GROUPS`, `HR_VIEWER_GROUPS` and
`HR_LEAD_GROUPS` ([Configuration](configuration.md#sign-in-to-hr)). After a
group change, sign out and in again. Nobody can change their own access,
status or ban.

Someone signed in without any HR role sees **No access to HR** with a link
to **Register**: there they can send their details to a coordinator, and
their entry appears in the [review queue](#review-queue).

An admin has full power over accounts: they can create, change and delete
everyone's account in the realm. Keep the admin group small.

## The pages

The menu only shows the pages your role may use.

| Page | Who | What you do there |
| --- | --- | --- |
| **Dashboard** | everyone | Counts, onboardings in progress, records with missing or invalid fields. |
| **Onboarding** | admins, leads | Give an approved volunteer their account in three steps: details, access, review. |
| **People** | everyone | Search everyone by name or status; open a person to edit their profile, change access, pause, ban or offboard them. Leads see the people of their departments. |
| **Departments** | everyone (admins edit) | Create, rename and archive departments; choose their leads. Each department has an IdP group, a lead group and default roles. |
| **Access groups** | everyone (admins edit) | Named sets of roles (for example "Standard volunteer") you give in one go. |
| **Review** | admins, leads | People waiting for a decision: self-registrations, imported rows and IdP accounts without an HR record. |
| **Import** | admins | Load a spreadsheet of volunteers into the review queue. |
| **Audit log** | admins, viewers | Who changed what and when. |
| **Keycloak groups** | admins, viewers | A live, read-only view of the realm's groups, with a link to the IdP's admin console. |
| **Settings** | everyone (admins edit) | Organisation, form, identity, retention and Google Workspace settings (below). |

## Onboarding someone

1. Open **Onboarding** and start a new one. Choose the **department** and
   enter the person's details. You can save with fields missing; the
   Dashboard lists what is still needed. Everything is required except the
   organisation email, social handles, and the emergency contact's email
   and comments.
2. **Access**: pick **access groups** and single roles. The roles of every
   module are listed (from each module's role catalog); the suite defaults
   and the department's defaults are already ticked. Leads cannot give
   admin roles of other modules.
3. **Review & complete**: check everything and complete. HR then, in the
   background:
    - creates the account with the login name from the **Login name**
      setting (by default the nickname), or links the existing account when
      HR runs with `IDP_PROVISIONER_MODE=link`,
    - adds the department group and one group per role,
    - asks the IdP to email a link for setting a password (not for accounts
      that sign in through the convention's own SSO).

    If the IdP cannot send that email, the completed page shows a
    **temporary password once**. Write it down and hand it over in person;
    the person must change it at first sign-in. **Resend set-password
    email** on the person's page sends the link again.

An onboarding you no longer need can be **cancelled**; nothing is created.

Roles that require training (set under role requirements) are held back
as **pending grants** until Learn reports the training as done, or until
you override them.

If completing fails, nothing is half-done on HR's side: the onboarding
returns to editable and the error says what to check (usually access to
the IdP). Fix it and complete again.

## Access groups

An access group bundles roles, for example "Standard volunteer" with the
Stash and Wiki roles every volunteer needs. Give it during onboarding or
on a person's page. When an admin changes the roles of an access group,
HR updates everyone holding it in the background. An access group still
held by someone cannot be deleted.

Other modules can list the IdP groups that access groups grant (the Wiki's
share dialog does, when HR has `HR_DIRECTORY_TOKEN`).

## Departments and leads

Each department has an IdP group (for example `dept-security`) and a lead
group (`dept-security-lead`). With **Change leads** on the department an admin
picks the people who lead it; they get the lead group and, if they are in
`hr-lead`, can work on that department in HR.

**Archive** hides a department from new onboardings while keeping its
members; **Restore** brings it back. Other modules are told about new,
renamed and archived departments (the department hooks).

## Changing access

Open the person under **People** and change their access. HR updates
their IdP groups in the background; modules see the change the next time
the person signs in.

## Review queue

The **Review** page lists people waiting for a decision. They come from:

- **Register**: someone signed in without an HR role sent their details.
- **Import**: rows of a spreadsheet you imported.
- **IdP scan**: HR found an enabled account in the IdP without an HR
  record (every `REVIEW_SCAN_INTERVAL`, or **Check accounts now**).

For each entry you can:

- **Accept as new person**: check and complete the details, choose the
  department and access groups; HR creates the person and an
  onboarding in the chosen department, linked to their existing account if
  they have one.
- **Merge**: the entry is someone HR already knows; link it (and its
  account) to that person.
- **Reject**: close the entry with a reason. For an IdP account, HR
  disables it.

Leads see entries for their departments only.

## Importing a spreadsheet

**Import** loads a CSV or Excel file of volunteers into the review queue;
rows never become people without a review.

1. Upload the file. HR shows its sheets and columns and suggests which
   column is which field. Pick the sheet, the header row and, if you like,
   one department for every row.
2. Check the mapping (**Save mapping** keeps it for next time) and click
   **Check (dry run)**: every row shows what would happen and why a row
   would fail. **Download check as spreadsheet** gives the result as an
   Excel file to fix.
3. Click **Import** (or **Import (skip N with errors)**). The valid rows
   appear on the **Review** page.

Under **Earlier imports**, **Undo** removes an import's entries as long as
none was accepted or merged.

## Pausing, banning and offboarding

- **Pause** marks an active person as paused (for example a break between
  events). Their account is disabled, so they cannot sign in, but they keep
  their access for when they come back. **Reactivate** enables the account
  again (unless they are banned).
- **Ban** (admins) disables the person's account and stops them from being
  onboarded again; a reason is required. Lifting the ban enables an active
  person's account again.
- **Offboard** (admins) removes the person: their account is deleted (or,
  with `IDP_PROVISIONER_MODE=link`, HR only removes its groups), other
  modules are told (for example the Wiki), they get an email if email is
  set up (with your reason only if you choose to share it), and HR deletes
  their record. Their access history and the offboarding line stay for the
  retention period, then are deleted too. This cannot be undone.

!!! warning "Convention SSO accounts stay active"
    When staff sign in through the convention's own SSO (**Settings →
    Identity**, mode *brokered* or *existing*), offboarding in HR cannot
    close that account. The offboarding screen says so and links the SSO's
    admin page: close the account there as well.

If the IdP is down, offboarding stops with an error and deletes nothing.
Choose **HR only** to delete the record anyway, then delete the account in
the IdP yourself.

## Settings

| Setting | What it does |
| --- | --- |
| **Organization name** | Used in emails. |
| **Organization email domain** | Domain of organisation addresses, for example `example.org`. |
| **Organization email name** | Template for the part before `@`; default `{first}.{last}`. |
| **Login name** | Template for new login names; default `{nickname}`. |
| **Default country** | Two-letter code (for example `AT`) for phone numbers without a country code and for addresses. |
| **Address search** | Photon server used for address suggestions; default `https://photon.komoot.io`. Addresses you type are sent there. |
| **Admin notification emails** | Who gets HR's notices (retention and Workspace deletion warnings). Empty: the members of the HR admin groups. |
| **Identity** | How staff sign in (*own* accounts, *brokered* from the convention's SSO, or an *existing* IdP), the SSO's name and address for the offboarding warning, and the IdP admin console link. |
| **Retention** | How long HR keeps personal data; see [Personal data](personal-data.md). |
| **Google Workspace** | The Workspace connector; see [Google Workspace](google-workspace.md). |

Templates may use `{first}`, `{last}` and `{nickname}`, plus letters,
digits, `.`, `-` and `_`.

When HR is paired with Den, the four organisation fields (and retention,
if Den's module settings set it) come from Den (**Den → Settings**) and are
read-only here. The other settings always stay in HR.

## Troubleshooting

**"HR is running with the fake identity provider."** No real accounts are
created. Ask the operator to set the Keycloak settings
([Configuration](configuration.md#account-provisioning-keycloak)).

**"This nickname is already taken."** The login name it would produce
exists, in HR or in the IdP. Choose another nickname.

**"HR's Keycloak service account is not allowed to …"** The `hr-provisioner`
client lacks the `manage-users` role. See [Setup](setup.md#troubleshooting).

**A module's roles are missing on the Access step.** That module's catalog
could not be fetched; the step shows the error. Check that the module is
paired with Den (or `ROLE_CATALOG_SOURCES`) and that HR may reach it.

**A lead sees no people.** They lead no department yet, or the department
is archived. An admin adds them with **Departments → Change leads**.

**An onboarding stays "in progress".** The background job could not reach
the IdP and is retrying. The person's page shows the last error; the
housekeeping task reports onboardings stuck for long.
