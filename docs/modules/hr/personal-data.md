# Personal data in HR

HR is the suite's register of volunteers and staff, so it holds more
personal data than any other module. This page says what it stores, who
can see it, where it goes and when HR deletes it. It is a description of
the software, not legal advice: check the retention periods with whoever
is responsible for data protection in your organisation (in the EU, under
the GDPR).

## What HR stores

| Data | Example | Why |
| --- | --- | --- |
| Names | first, last and legal name, nickname, login name | Account creation, emails, finding people. |
| Contact | email, organisation email, phone, postal address, social handles | Reaching the person; the account's email. |
| Date of birth | `1990-05-17` | Telling people with the same name apart; age where your organisation needs it. |
| Emergency contact | name, phone, optional email and comments | Safety during the event. |
| Status | applicant, active or paused, and whether the person is banned | Who may sign in. |
| Notes | free text by HR | Internal remarks. Write only what you would show the person. |
| Memberships and access | departments, access groups, roles, pending grants | What the person may do in the other modules. |
| Account link | the identity provider's account id and subject | Changing and deleting the account. |
| Audit log | who changed what and when | Accountability; also kept after the person is gone (below). |

Self-registrations, imported rows and accounts found by the review scan
wait in the **review queue** until someone accepts, merges or rejects
them.

## Who can see it

| Who | What |
| --- | --- |
| HR admins | Everything. |
| HR viewers | Everything, read-only. |
| Department leads | People, onboardings and review entries of the departments they lead. |
| The person | Their own registration while it waits in the review queue. |
| Other modules | Only what they need: the account and its groups through the identity provider; the Wiki the names of departments and access groups (no people); modules named in `OFFBOARD_HOOKS` the identity of someone offboarded (`issuer`, `subject`, `external_id`, `username`). |

## Where it goes outside HR

- **The identity provider** (Keycloak) gets the login name, names, email
  and the attributes in `KEYCLOAK_USER_ATTRIBUTES`.
- **Address search**: addresses typed into HR are sent to the Photon server
  in **Settings → Address search** (default the public
  `https://photon.komoot.io`, run by komoot). Run your own Photon, or empty
  the setting to turn suggestions off.
- **Email**: HR's own notices go through your SMTP server.
- **Google Workspace**, when that connector is on
  ([Google Workspace](google-workspace.md)).

## When HR deletes it

Under **Settings → Retention** (defaults below, in days). While HR is paired
with Den, `retention.inactive_users_days` overrides the applicant and paused
periods and `retention.offboarded_volunteers_days` overrides the access
history, when Den sends a number greater than 0:

| Rule | Default | What happens |
| --- | --- | --- |
| Applicants untouched for | 180 days | The applicant and their onboardings are deleted. |
| People paused for | 730 days | They are offboarded (account deleted, record deleted). |
| Access history kept after an offboarding | 365 days | Then the remaining audit lines about the person are deleted too. |
| Warning before a deletion | 14 days | HR admins are emailed the list first. |

The housekeeping task (`MAINTENANCE_INTERVAL`, every hour) applies the
rules. **Nothing is deleted without a warning that was actually sent**: if
the email cannot be delivered, HR deletes nothing and tries again later.
To keep someone, update or reactivate them before the date in the email.
`GET /api/retention/candidates` (admins) lists who is due.

**Offboarding** deletes the person straight away: profile, onboardings and
the audit entries about their profile. Only their access history and one
offboarding line (login name, who, when, reason) stay, for the period
above.

## Requests from a person

- **"What do you have about me?"** Open the person in HR: the profile and
  **Access** show everything HR holds; the **Audit log** shows the changes.
- **"Please correct it."** Edit the profile; the change goes to the
  identity provider too.
- **"Please delete me."** Offboard them with that reason. Remember the
  Google Workspace account (deleted after its own period) and, with a
  convention SSO, the account there.

## Troubleshooting

**Retention deletes nothing.** Retention is off, nobody is due yet, or the
warning email could not be sent: check `SMTP_HOST` and **Settings → Admin
notification emails**, and the backend log for
`retention: could not warn HR admins, nothing purged`.
