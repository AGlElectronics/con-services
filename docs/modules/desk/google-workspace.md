# Mailboxes in Google Workspace

This page connects Desk to **Google Workspace** (Google's paid Gmail for
organisations), so that Desk can create support mailboxes in Google, read
their mail and send replies from them. Do it once per installation; after
that a Desk admin creates mailboxes in Desk and never has to open Google's
admin console for them.

Terms used on this page:

- **Service account**: a Google account for a program, not a person. Desk
  signs in to Google with its **key** (a JSON file).
- **Domain-wide delegation**: a Workspace setting that lets a service
  account act as any user of your domain, limited to the **scopes**
  (permissions) you list. Desk uses it to read and send as each mailbox and
  to create users and groups as an admin.
- **Connector**: how one Desk mailbox exists in Google. There are two.

## The two Google connectors

| | `google_user` | `google_group` |
| --- | --- | --- |
| In Google | Its own **licensed user** (`info@example.org`). | A free **group** whose only member is one shared licensed account (`desk@example.org`). |
| Cost | One Workspace licence per mailbox. | Free; one licence for the shared account in total. |
| Storage and limits | Its own. | Shared by every group mailbox (the shared account's storage and Gmail sending limits). |
| How Desk reads | As that user. | Reads the shared account once for all group mailboxes and sorts each message by its recipient (`Delivered-To`, `X-Original-To`, `To`, `Cc`). |
| How Desk sends | As that user. | As the shared account, "send as" the group address, so the customer sees `registration@example.org`. |
| Good for | Busy addresses, addresses someone else also uses in Gmail. | Many quiet addresses (`lost-found@`, `press@`). |

Choose per mailbox when you create it; it cannot be changed later (create a
new mailbox instead). Mailboxes on any other mail server use the third
connector, [IMAP and SMTP](imap.md).

!!! warning "Needs a Desk build with the Google client"
    Desk talks to Google through the shared Google Workspace client of
    Con Services (`shared/go/gworkspace`). A Desk image built without it
    refuses to start when `GOOGLE_WORKSPACE_DOMAIN` is set, with
    `this build of Desk has no Google Workspace client yet`. Check the
    release notes of your Desk version. In development you can try the
    whole flow without Google with `GOOGLE_FAKE=true`
    ([Option 4](setup.md#option-4-development-on-docker)).

## What Desk does in Google

| When | `google_user` | `google_group` |
| --- | --- | --- |
| A Desk admin creates the mailbox | Creates the user (name and address from Desk). | Creates the group with the shared account as its only member, lets anyone (also outside the domain) write to it, and adds a send-as address for it to the shared account. |
| Every `FETCH_INTERVAL` | Reads inbox mail **without** the label `Desk`, imports it, adds the label. | Same, on the shared account; mail for no known mailbox gets `Desk/Unrouted`. |
| A reply is sent | Sends as the user. | Sends from the shared account with the group address as sender. |
| An email or conversation is deleted in Desk | Moves the message to Gmail's trash (restoring in Desk takes it out again). | Same. |
| The mailbox is deleted in Desk (to Desk's trash) | **Suspends** the user. | Stops delivery to the group and removes the send-as address. |
| The mailbox is restored | Unsuspends the user. | Turns delivery and send-as back on. |
| The mailbox is purged (after 30 days, or by an admin) | **Deletes** the user. | **Deletes** the group and the send-as address. |

Desk never deletes mail in Gmail by itself, except by moving a message to
Gmail's trash when someone deletes it in Desk. The label `Desk` is what
tells Desk a message was handled: removing it in Gmail makes Desk import
the message again (duplicates are skipped by `Message-ID`).

## Before you start

- A Google Workspace subscription and a **super admin** account for the
  setup steps.
- The Google Cloud console (<https://console.cloud.google.com>), signed in
  with an account of your Workspace domain.
- For group mailboxes: one licensed user as the **shared account**, for
  example `desk@example.org`. Nobody needs to sign in to it.
- Desk installed ([Setup](setup.md)) or about to be, with access to your
  secret manager.

## Set it up

1. **Create a Google Cloud project.** In the Cloud console: project picker
   → **New project**, name `conservices-desk`, organisation = your
   Workspace domain → **Create**.

2. **Turn on the APIs.** In the project: **APIs & Services → Library**,
   search for and **Enable** each of:

    - Gmail API
    - Admin SDK API

    Or with the `gcloud` command line:

    ```sh
    gcloud services enable gmail.googleapis.com admin.googleapis.com \
      --project conservices-desk
    ```

3. **Create the service account and its key.** **IAM & Admin → Service
   accounts → Create service account**, name `desk`, no project roles →
   **Done**. Open it → **Keys → Add key → Create new key → JSON**. The
   browser downloads a file like `conservices-desk-1a2b3c4d5e6f.json`. Note
   the service account's **Unique ID** (a long number, the "client ID") on
   its **Details** tab.

    !!! danger "The key is a password for your whole domain"
        With domain-wide delegation it can read every mailbox Desk may
        read and create users. Put it straight into your secret manager
        (step 6) and delete the downloaded file. Never commit it.

    If your organisation blocks key creation (the policy
    `iam.disableServiceAccountKeyCreation`), ask your Google Cloud admin
    for an exception for this project.

4. **Allow domain-wide delegation.** In the Workspace Admin console
   (<https://admin.google.com>) as super admin: **Security → Access and data
   control → API controls → Manage domain wide delegation → Add new**.
   Client ID: the Unique ID from step 3. OAuth scopes (one line,
   comma-separated):

    ```text
    https://www.googleapis.com/auth/gmail.modify,https://www.googleapis.com/auth/gmail.settings.sharing,https://www.googleapis.com/auth/admin.directory.user,https://www.googleapis.com/auth/admin.directory.group
    ```

    | Scope | Used for |
    | --- | --- |
    | `gmail.modify` | Read mail, add the `Desk` label, send replies, move to and from Gmail's trash. Not permanent deletion. |
    | `gmail.settings.sharing` | Add and remove the send-as address of group mailboxes on the shared account. |
    | `admin.directory.user` | Create, suspend, unsuspend and delete `google_user` mailboxes. |
    | `admin.directory.group` | Create and delete `google_group` mailboxes and add the shared account to them. |

    Desk does not change a group's posting settings. Allow outside senders
    yourself, see step 9.

    Click **Authorize**. Changes can take a few minutes, rarely up to 24
    hours, to apply.

    If this client ID is already authorised, edit it and add exactly:

    ```text
    https://www.googleapis.com/auth/gmail.settings.sharing
    ```

    Leave every scope that is already there. `gmail.modify` does not include
    this one. Without it Desk cannot add or remove the send-as address, so
    creating or suspending a group mailbox fails.

5. **Pick the admin Desk acts as.** The Admin SDK calls run as a Workspace
   admin (`GOOGLE_WORKSPACE_ADMIN_EMAIL`). Use a dedicated user, for example
   `desk-admin@example.org`, with an admin role that can manage users and
   groups (**Account → Admin roles → Create new role**: Users → Create,
   Update, Suspend, Delete; Groups → all). A super admin works too but
   gives Desk more than it needs. Make sure new users get a licence:
   **Billing → Licence settings → Automatic licensing** on for the
   organisational unit Desk creates users in (the top-level one).

6. **Store the key in your secret manager** and let the External Secrets
   Operator create the Secret `desk-google` (see
   [Secrets](../../operations/secrets.md)). With OpenBao or Vault:

    ```sh
    vault kv put secret/conservices/desk/google \
      service-account.json=@conservices-desk-1a2b3c4d5e6f.json
    rm conservices-desk-1a2b3c4d5e6f.json
    ```

    ```yaml
    apiVersion: external-secrets.io/v1
    kind: ExternalSecret
    metadata:
      name: desk-google
      namespace: conservices-desk
    spec:
      refreshInterval: 1h
      secretStoreRef: { name: vault, kind: SecretStore }
      target: { name: desk-google }
      data:
        - secretKey: service-account.json
          remoteRef: { key: conservices/desk/google, property: service-account.json }
    ```

7. **Configure Desk.** Add to your Helm values (see
   [Setup](setup.md#option-1-kubernetes-platform-recommended)):

    ```yaml
    google:
      enabled: true              # mounts desk-google at /etc/desk-google
      existingSecret: desk-google
    config:
      GOOGLE_WORKSPACE_DOMAIN: example.org
      GOOGLE_WORKSPACE_ADMIN_EMAIL: desk-admin@example.org
      GOOGLE_SHARED_MAILBOX: desk@example.org   # only for group mailboxes
      GOOGLE_LABEL: Desk
      NOTIFY_FROM: "Desk <desk@example.org>"    # reminders and notifications
    networkPolicy:
      google:
        enabled: true            # egress to Google's APIs on 443
    ```

    The chart sets `GOOGLE_WORKSPACE_CREDENTIALS_FILE` to
    `/etc/desk-google/service-account.json`. With Cilium it adds the
    `CiliumNetworkPolicy` `desk-backend-google`, which allows HTTPS to
    `gmail.googleapis.com`, `admin.googleapis.com`,
    `oauth2.googleapis.com` and `www.googleapis.com`.
    On other CNIs set `networkPolicy.google.cidrs` (Google publishes no
    small address range; `0.0.0.0/0` on port 443 is the usual choice). With
    only Google mailboxes and no `SMTP_HOST`, you can set
    `networkPolicy.extraEgress: []`.

    ```sh
    helm upgrade desk deploy/charts/desk -n conservices-desk -f my-desk.yaml
    ```

    With Docker Compose, mount the key read-only and set the same variables
    plus `GOOGLE_WORKSPACE_CREDENTIALS_FILE` ([Configuration](configuration.md#backend)).

8. **Check the connection.** As `desk-admin`: **Settings → Mail
   connectors** shows the domain, the shared account, the label, when the
   shared account was last read and any error. If the backend does not
   start, its log names the problem (see Troubleshooting).

9. **Create the first mailbox.** **Mailboxes → New mailbox**: name
   `Registration`, address `registration@example.org`, connector **Google
   Workspace: group into the shared account** or **Google Workspace: own
   licensed user** → **Create mailbox**. When Google refuses, the card
   shows the error and a **Create in Google again** button.

    The same with the API ([reference](api.md#post-apiv1mailboxes)):

    ```sh
    curl -s -X POST $DESK/api/v1/mailboxes \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      -d '{"name":"Registration","email":"registration@example.org","connector":"google_group"}'
    ```

    ```json
    {"id":"c7e2a1d0-…","slug":"registration","name":"Registration",
     "email":"registration@example.org","connector":"google_group",
     "provider_state":"active","provider_error":"", "...": "..."}
    ```

    For a `google_group` mailbox, let customers write to it: in the Admin
    console open **Directory → Groups**, select the group → **Group
    settings → Who can post** → **Anyone on the web** → **Save**. If the
    option is missing, first allow it for the domain under **Apps → Google
    Workspace → Groups for Business → Sharing settings** ("Group owners can
    allow incoming email from outside the organisation"). Desk does not
    change this setting for you.

10. **Verify.** Send a mail from an outside address to
    `registration@example.org`. Within `FETCH_INTERVAL` it appears in Desk
    under **Unassigned**, and in the shared account's Gmail it carries the
    label `Desk`. Reply from Desk; the outside address receives it from
    `registration@example.org`. Then grant people the mailbox's roles
    ([Access](access.md)).

## Using an address that already exists

If the address already exists in Google (a user or a group), Desk takes it
over as it is and says so on the mailbox card (`the address already existed
in Google Workspace; Desk uses it as it is`). For an existing group, make
sure the shared account is a member and has a send-as address for it, or
create the mailbox as `google_user` if the address is a user.

## Troubleshooting

**The backend does not start: `GOOGLE_WORKSPACE_CREDENTIALS_FILE is required
when GOOGLE_WORKSPACE_DOMAIN is set`** (or `GOOGLE_WORKSPACE_ADMIN_EMAIL`). Set
`google.enabled: true` (it sets the file path) and `GOOGLE_WORKSPACE_ADMIN_EMAIL`.

**The backend does not start: `this build of Desk has no Google Workspace
client yet`.** Your Desk image has no Google client; see the warning at the
top. Unset `GOOGLE_WORKSPACE_DOMAIN` to run with IMAP mailboxes only.

**`GOOGLE_SHARED_MAILBOX must be an address in GOOGLE_WORKSPACE_DOMAIN`.**
The shared account must be in the same domain, for example
`desk@example.org` for `example.org`.

**Creating a mailbox fails with `connector: group mailboxes need
GOOGLE_SHARED_MAILBOX`.** Set it, or create a `google_user` mailbox.

**The mailbox card shows `could not create the mailbox in Google Workspace:
… unauthorized_client`.** Domain-wide delegation is missing or lacks a
scope: check step 4 (client ID and the exact scope list), wait a few
minutes, then **Create in Google again**.

**`… Not Authorized to access this resource/api` when creating.**
`GOOGLE_WORKSPACE_ADMIN_EMAIL` is not an admin, or its admin role cannot create users
or groups (step 5).

**Mail to a group mailbox never arrives in Desk; the shared account's Gmail
shows it with the label `Desk/Unrouted`.** No Desk mailbox has the address
the message was delivered to. Usually the group forwards from an alias:
create the mailbox with the address the customer actually writes to.

**Customers get a bounce "you don't have permission to post to this
group".** The group only accepts members' mail. Desk does not change who can
post. Set **Who can post** to **Anyone on the web** in the Admin console
(step 9).

**Replies from a group mailbox fail with `the shared account may not send
as this address`, or creating a group mailbox fails the same way.** The
send-as address is missing, or domain-wide delegation does not include
`https://www.googleapis.com/auth/gmail.settings.sharing`. Add that scope
on the service account's client ID (step 4), wait a few minutes, then
**Create in Google again** on the mailbox card.

**Timeouts or `dial tcp …:443: i/o timeout` in the log.** The network
policy blocks Google: set `networkPolicy.google.enabled: true` (and
`cidrs` on non-Cilium clusters).

**The licence count went up unexpectedly.** Each `google_user` mailbox is a
licensed user. A suspended user (mailbox in Desk's trash) still holds its
licence until it is purged.
