# HR admin guide

This page is for the people who use HR day to day: onboarding volunteers,
changing their access and offboarding them. For installing HR see
[Setup](setup.md).

## Who can use HR

Only members of an HR access group (`HR_ACCESS_GROUPS`, default
`hr-admin`) can open HR. Everyone else sees "you don't have access to HR".
To let someone in, add them to `hr-admin` in Keycloak, or give them the
**HR admin** role through HR itself (it is in HR's own role catalog). They
sign out and in again for it to apply.

HR has full power over accounts: whoever can use HR can create, change and
delete everyone's account in the realm. Keep the group small.

## The pages

| Page | What you do there |
| --- | --- |
| **Dashboard** | Counts, onboardings in progress, records with missing or invalid fields. |
| **Onboarding** | Give an approved volunteer their account in three steps: details, access, review. |
| **People** | Search everyone by name or status; open a person to edit their profile, change access, pause or offboard them. |
| **Departments** | Create and rename departments. Each one has a Keycloak group and default roles that every new member gets. |
| **Keycloak groups** | A live, read-only view of the realm's groups, with a link to the Keycloak console. Shows a notice when HR runs with the fake identity provider. |
| **Settings** | Organisation and form settings (below). |

## Onboarding someone

1. Open **Onboarding** and start a new one. Choose the **department** and
   enter the person's details. You can save with fields missing; the
   Dashboard lists what is still needed. Everything is required except the
   organisation email, social handles, and the emergency contact's email
   and comments.
2. **Access**: the roles of every module are listed (from each module's
   role catalog). The suite defaults and the department's defaults are
   already ticked. Add or remove roles.
3. **Review & complete**: check everything and complete. HR then:
    - creates the Keycloak account with the login name from the **Login
      name** setting (by default the nickname),
    - adds the department group and one group per role,
    - asks Keycloak to email a link for setting a password.

    If Keycloak cannot send that email, the completed page shows a
    **temporary password once**. Write it down and hand it over in person;
    the person must change it at first sign-in.

Roles that require training (set under role requirements) are held back
as **pending grants** until Learn reports the training as done, or until
you override them.

If completing fails, nothing is half-done on HR's side: the draft returns
to editable and the error says what to check (usually Keycloak access).
Fix it and complete again.

## Changing access

Open the person under **People** and change their access. HR updates
their Keycloak groups straight away; modules see the change the next time
the person signs in.

## Pausing and offboarding

- **Pause** marks an active person as paused (for example a break between
  events). It does **not** remove their account or access.
- **Offboard** removes the person: their Keycloak account is deleted,
  other modules are told (for example the Wiki), they get an email if
  email is set up (with your reason only if you choose to share it), and
  HR deletes their record. Only one audit line remains (login name, who
  and when). This cannot be undone.

If Keycloak is down, offboarding stops with an error and deletes nothing.
Choose **HR only** to delete the record anyway, then delete the account in
Keycloak yourself.

## Settings

| Setting | What it does |
| --- | --- |
| **Organization name** | Used in emails. |
| **Organization email domain** | Domain of organisation addresses, for example `example.org`. |
| **Organization email name** | Template for the part before `@`; default `{first}.{last}`. |
| **Login name** | Template for new login names; default `{nickname}`. |
| **Default country** | Two-letter code (for example `AT`) for phone numbers without a country code and for addresses. |
| **Address search** | Photon server used for address suggestions; default `https://photon.komoot.io`. |

Templates may use `{first}`, `{last}` and `{nickname}`, plus letters,
digits, `.`, `-` and `_`.

When HR is paired with Den, the four organisation fields come from Den
(**Den → Settings**) and are read-only here. Default country and address
search always stay in HR.

## Troubleshooting

**"HR is running with the fake identity provider."** No real accounts are
created. Ask the operator to set the Keycloak settings
([Configuration](configuration.md#account-provisioning-keycloak)).

**"This nickname is already taken."** The login name it would produce
exists, in HR or in Keycloak. Choose another nickname.

**"HR's Keycloak service account is not allowed to …"** The `hr-provisioner`
client lacks the `manage-users` role. See [Setup](setup.md#troubleshooting).

**A module's roles are missing on the Access step.** That module's catalog
could not be fetched; the step shows the error. Check
`ROLE_CATALOG_SOURCES` and that HR may reach the module.
