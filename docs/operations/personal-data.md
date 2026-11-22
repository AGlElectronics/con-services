# Personal data

This page lists the personal data each part of Con Services stores, who it
is about, and why that part keeps it. It describes the software. It is not
legal advice: check the periods and the purposes with whoever is responsible
for data protection in your organisation (in the EU, under the GDPR).

**Crew** means the staff and volunteers who run the convention. **Attendees**
sign in on Rally's submission site. **Guests** are everyone else who never
gets an account (a lost-item report, a support email).

Every part below runs on your own servers. Each module has its own database.
A free-text field (a note, a comment, a form answer, a page) holds whatever
someone types into it, including a name or a phone number the form did not
ask for.

Passwords stay in the identity provider
([Keycloak](../deploy/identity.md)). A module copies the name and email from
the sign-in token the first time that person opens it.

## Sign-in (Keycloak)

| Part | What it is for | What is stored | Who | Why it is kept |
| --- | --- | --- | --- | --- |
| Staff account | Sign-in for the crew, realm `conservices` | Username, name, email, groups, password | Crew | So they can sign in, and so modules can tell who they are |
| Attendee account | Sign-in for Rally's submission site, realm `attendees` | Username, name, email, password | Attendees | A public account. Email verification and password reset use that email. The account cannot act as staff |

HR writes the login name, names and email into the staff realm when it
creates an account, plus any attributes named in `KEYCLOAK_USER_ATTRIBUTES`.
See [Personal data in HR](../modules/hr/personal-data.md#where-it-goes-outside-hr).

## Den

Den keeps a row for each person who has signed in, and its backups are a
copy of every module database. The business records stay in the modules.

| Part | What it is for | What is stored | Who | Why it is kept |
| --- | --- | --- | --- | --- |
| Local user | The portal after sign-in | Display name, email, identity-provider issuer and subject, last sign-in, light or dark theme | Crew | Created on the first visit and updated on later ones, so the portal and the audit log can name them |
| Audit log | Changes in the admin console | Who did it, and when | Crew | Accountability. Credentials and tokens are left out of the log |
| Backups | Nightly encrypted copy of the suite | Whatever each module stores | Everyone those databases hold | Recovery. Treat the backup store the way you treat the databases. See [Databases, backups and restore](databases-and-backups.md) |

## HR

HR is the register of the crew. The full account, with who can see it and
when it is deleted, is on [Personal data in HR](../modules/hr/personal-data.md).

| Part | What it is for | What is stored | Who | Why it is kept |
| --- | --- | --- | --- | --- |
| Person record | The register | Names, email, phone, postal address, social handles, date of birth, emergency contact, status (including a ban), notes, departments and roles, identity-provider account id | Crew | Reaching them, telling people with the same name apart, and granting access |
| Review queue | Applications waiting for a decision | The same fields, from self-registration, an import or a scan | Crew | Until someone accepts, merges or rejects the application |
| Onboarding forms | NDA, GDPR consent and similar PDFs | The signed form and the answers in it, in HR's bucket | Crew | The signed agreement |
| Audit log | Changes to a profile | Who changed what, and when | Crew | Accountability. After offboarding, access history stays for the retention period |
| Address search | Suggestions while an address is typed | The address text, sent to the Photon server in **Settings → Address search** | Crew | Optional. Empty the setting to turn suggestions off |
| Google Workspace | An account in the organisation's domain, when the connector is on | Login name, names, email | Crew | The workspace account. It has its own deletion period |

## Rally

Rally is the programme: calls for papers, review and the published schedule.
Rooms, tags and event types are left out of this list. An API key is stored
as a hash.

| Part | What it is for | What is stored | Who | Why it is kept |
| --- | --- | --- | --- | --- |
| Staff sign-in | The programme team | Display name, email, identity-provider subject | Crew | So Rally can name who reviewed, decided or published |
| Submission-site account | A speaker signs in to propose a session | Display name, email, whether the email is verified, an 8-character presenter code | Attendees | So they can submit, and so someone else can add them with that code |
| Proposal | The call for papers | Speaker name, email and bio (up to 20 speakers), the form answers, uploaded files such as slides | Attendees | So staff can read and decide. A form field can ask for more than this |
| Co-presenter invite | The owner adds someone who is not linked yet | Invite email, invite code | Attendees | So that person can be attached to the proposal. Rally does not send the email; the owner shares the code |
| Review | Staff comment, score, accept or reject | Reviewer name, private notes, scores, the decision note | Crew, about attendees | Notes and scores stay with staff. The decision note is shown to the submitter |
| Published programme | Website, info screens, calendar | Speaker names, session title, description | Attendees, shown to whoever holds an API key | So visitors can see who is on, and where. Email and bio stay on the proposal |

Each published version, and each edit of a schedule item, keeps a copy of
the speaker names that were on the grid at that time. Withdrawing a proposal
leaves its contents in place. The docs describe no automatic deletion of
these records.

## Stash

Stash is inventory, sign-outs and Lost & Found. Items, locations and
departments are not personal data.

| Part | What it is for | What is stored | Who | Why it is kept |
| --- | --- | --- | --- | --- |
| Sign-in | Crew using inventory | Display name, email, identity-provider subject, last sign-in | Crew | So history can say who did what |
| Sign-out | Who took the gear | A typed name, and the Stash user when one was picked. Notes | Crew | So overdue gear can be chased. The reminder email goes to that user's email when overdue mail is on |
| Request | Asking logistics for gear | Who asked, and their name | Crew | So the request has an owner |
| Lost & Found report | A guest's lost or found item | Guest name, contact (whatever the desk typed), who it was handed back to, description, notes, a photo of the item | Guests | So the desk can match the item and hand it back. A photo can show a person |
| Telegram link | Tell the guest the item turned up | The Telegram chat id, on the server only. The API shows that a guest is linked | Guests | Optional. The chat id and the message text are left out of the audit log |
| Audit log and item history | Every change | The actor's name and identity-provider subject. Lost & Found entries can also hold the guest fields | Crew, and guests inside Lost & Found entries | Accountability. People without Lost & Found access see `[redacted]` for the guest fields |

Lost & Found reports, their photos and their Telegram link are deleted on a
schedule (by default 30 days after the report is closed). Guest fields in
earlier audit entries are replaced with `[redacted]`. Crew can be anonymised
by hand, or after a number of days without a sign-in (the default is never):
the name becomes *Former user*, and the email and identity-provider subject
are removed from the user row, the audit log and item history. What they did
stays. See [Lost & Found retention](../modules/stash/admin-guide.md#lost-found-retention)
and [People who left](../modules/stash/admin-guide.md#people-who-left).

## Finance

| Part | What it is for | What is stored | Who | Why it is kept |
| --- | --- | --- | --- | --- |
| Customer | Who is invoiced | Name, email, billing address, tax id, notes | A customer, which may be a company or a person | The invoice. A customer who has invoices is archived rather than deleted |
| Issued invoice | A bill that has been sent | A frozen copy of the customer's name, email, address and tax id, the organisation's seller details, and the PDF | That customer | Later edits of the customer do not change an invoice already issued |
| Expense | Money spent | Vendor, description, reference, amount | A supplier, or a crew member when the vendor is a person | The books |
| Audit log | Who booked or approved | Name, identity-provider issuer and subject, and the values before and after | Crew | Accountability |

Seller details (the organisation's own name, address and VAT number) are
the organisation, not a customer.

## Learn

| Part | What it is for | What is stored | Who | Why it is kept |
| --- | --- | --- | --- | --- |
| Account | A learner or trainer signs in | Name, email, identity-provider subject, language, cached groups, notification settings (email on or off, Telegram chat id) | Crew | So Learn can enrol them and send reminders |
| Training record | Courses, quizzes, sessions | Enrolment, progress, quiz attempts and scores, attendance | Crew | Proof they were trained for the job |
| Certificate | A qualification | Name, qualification, dates. The public verify page shows those three | Crew, and anyone with the verify code | The certificate keeps verifying after erasure, under the name *Former learner* |
| Course feedback | A rating after a course or session | A rating and a comment. With anonymous feedback on, the comment is stored without a display name. A hash stops the same person submitting twice, without storing who they are | Crew | Improving the course |
| Reminders | A nudge to finish | Sent by email, and by Telegram when a chat id is saved | Crew | So people finish the training |

Someone who has neither signed in nor been in a synced group for 1,095 days
is anonymised (the default; `0` means never). An admin can erase someone
sooner: the name becomes *Former learner*, and the email, sign-in link,
groups and notification settings are removed. Progress, results, attendance
and certificates stay. These defaults are pending legal review. See
[Erase a person](../modules/learn/guides/admin.md#erase-a-person-gdpr).

## Wiki

| Part | What it is for | What is stored | Who | Why it is kept |
| --- | --- | --- | --- | --- |
| Account | Sign-in | Display name, email, identity-provider issuer and subject | Crew | Who wrote a page, and who may see it. Admins see email addresses in the people picker |
| Pages, comments and databases | The handbook | Whatever people write, including names in the text and in `@` mentions, plus files attached to pages | Crew, and anyone named on a page | The organisation's know-how. A public share link shows that page to whoever has the link |
| Private space | A person's own notes | The pages in that space | Crew | When HR offboards them, the space is handed to the Wiki admins and deleted after the grace period (30 days). Pages they wrote in team spaces stay |

## Desk

Desk is the shared inbox. Customers write by email.

| Part | What it is for | What is stored | Who | Why it is kept |
| --- | --- | --- | --- | --- |
| Customer | The person who wrote in | Name, one or more email addresses, notes | Guests, partners, crew | So threads from the same person stay together |
| Conversation | The support thread | Subject, message text, CC addresses, internal notes, attachments, the original email file | Whoever wrote or was copied | So staff can answer. Internal notes stay in Desk |
| Staff | Who is handling it | Display name and email of people who have signed in, used as the assignee | Crew | One assignee per conversation. Optional notification email to that person |

Closed conversations, attachments and original emails are kept until you set
a period (the defaults are pending legal review). Trash is purged after 30
days. Deleting a message in Desk does not delete the copy at the mail
provider. See [Retention](../modules/desk/operations.md#retention).

## Tasks

| Part | What it is for | What is stored | Who | Why it is kept |
| --- | --- | --- | --- | --- |
| Account | Sign-in | Display name, email, identity-provider issuer and subject | Crew | Assignees, mentions and notification email |
| Task | The job | Title, description, comments (with `@` names), assignees, watchers, custom fields, time recorded on the task, attachments | Crew | The work. A comment or description can name anyone |
| Inbox | What needs attention | The notification (an assignment, a mention, a comment) | Crew | Read notifications are deleted after 90 days. Unread ones stay |

The docs describe no erasure of a person. A grant whose user was deleted
shows *Former user*. Trash, the audit log and automation history have their
own periods ([Settings from Den](../modules/tasks/configuration.md#settings-from-den)); those
defaults are placeholders, not a legal period.

## Feedback

Feedback is a development scaffold. Crew send a note in a private Telegram
chat.

| Part | What it is for | What is stored | Who | Why it is kept |
| --- | --- | --- | --- | --- |
| Note in progress | The chat before the person sends | Chat id, Telegram user id and name, and the answers so far | Crew | Cleared when the note is saved or cancelled |
| Saved note | The inbox | Positive or negative, the department, the text, and whether the board was notified. A named note also keeps the Telegram user id and name | Crew | The note. An anonymous note is stored without the Telegram user id and name. When board notify is on, the text is also posted to the board chat, with the person's Telegram name or the word *anonymous* |

## Intercom

Intercom is a development scaffold for the staff Telegram bot.

| Part | What it is for | What is stored | Who | Why it is kept |
| --- | --- | --- | --- | --- |
| Board question | `/board` in a crew chat | Source chat id and title, the sender's Telegram name (including their `@` username), the question | Crew | So the board can answer back in that chat |
| Idea | `/idea` | The same, plus the idea text. A task is also created in Tasks | Crew | The idea is kept in Intercom and on that task |

## Stats

Stats stores aggregate counts (how many of something), in memory on the
current scaffold. The snapshot has no names or emails.

## Copies outside the module

The same data is also held in:

- That module's PostgreSQL database, and the nightly [backup](databases-and-backups.md) Den's operator takes of it.
- The module's bucket, where it has one: Lost & Found and item photos (`stash-data`), proposal files (`events-data`), support mail (`desk-data`), onboarding PDFs (HR), course media (Learn), page files (Wiki), task attachments (Tasks), invoice PDFs (Finance).
- Your mail server, when a module sends mail (HR notices, Stash overdue reminders, Learn reminders, Desk replies and notifications, Tasks notifications).
- Telegram, when that module's bot is on (Stash Lost & Found, Rally announcements, Learn reminders, Feedback, Intercom).
- Google, when HR's Workspace connector or Desk's Google mailboxes are on.
- Whoever holds a Rally public API key: speaker names and session titles on the website, screens and calendars.
- Logs. A request path can contain an id or a name. See [Logs](observability.md#logs).
