# Operating Desk

Day-to-day tasks for whoever runs Desk: the trash and automatic purge,
retention, the audit log, rotating `DESK_SECRET_KEY`, backups and the
background jobs. Most of this needs the **Desk admin** role
([Access](access.md)).

## Background jobs

The backend runs these itself, in its single replica:

| Job | When | What |
| --- | --- | --- |
| Mail fetcher | Every `FETCH_INTERVAL` (default 60 s) per mailbox, longer after failures | Imports new mail ([Google](google-workspace.md), [IMAP](imap.md)). |
| Reply sender | Continuously | Sends queued replies 10 seconds after they were written (the undo window); retries after 1, 5, 15 and 60 minutes. |
| Outbox | Continuously | Sends Desk's own emails: notifications and purge reminders. |
| Daily maintenance | Once every 24 hours, remembered across restarts (so right after start if the last run is older) | Purges mailboxes whose time in the trash is up, sends purge reminders, applies retention. |

The chart refuses `backend.replicas` other than 1: two backends would fetch
every mailbox twice. A send that was in progress when the pod stopped is
queued again on start and never sent twice.

## The trash

**Emails and conversations.** Someone with the mailbox's `delete` role (or
a Desk admin) deletes an email or a whole conversation; it moves to the
mailbox's **Trash** folder, and for Google mailboxes the message also
moves to Gmail's trash. **Restore** brings both back. After `trash_days`
(default 30) the daily job deletes it for good, with its attachments.

**Mailboxes.** Only Desk admins delete mailboxes (**Mailboxes →** the
mailbox **→ Delete**). The mailbox moves to the **mailbox trash**:

1. Desk stops fetching and sending for it; queued replies fail with "the
   mailbox was deleted". Its roles disappear from the role catalog.
2. A Google mailbox is **suspended** in Google, not deleted.
3. Desk admins get an email **7 days and 1 day** before the purge (needs
   `NOTIFY_FROM`; only admins who have signed in to Desk at least once are
   known to Desk).
4. After `mailbox_trash_days` (default 30) the daily job **purges** it:
   deleted in Google Workspace, its files deleted from S3, every
   conversation deleted in Desk.

To keep it, restore it before then: **Mailboxes → Trash → Restore**, or

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" $DESK/api/v1/mailboxes/c7e2a1d0-…/restore
```

To purge now (cannot be undone):

```sh
curl -s -X POST -H "Authorization: Bearer $TOKEN" $DESK/api/v1/mailboxes/c7e2a1d0-…/purge
```

The address stays taken (also for new mailboxes) until the purge.

## Retention

Retention says how long Desk keeps what. Five periods, in days; empty
(`null`) means keep forever.

| Setting | Deletes | Default |
| --- | --- | --- |
| Closed conversations (`closed_conversation_days`) | Closed conversations with all their mail and files, counted from when they were closed. | keep, **pending legal review** |
| Attachments (`attachment_days`) | Attachments, counted from arrival. The messages stay. | keep, **pending legal review** |
| Original emails (`raw_mail_days`) | The stored original `.eml` files. The conversation text stays. | keep, **pending legal review** |
| Trash (`trash_days`) | Emails and conversations in Desk's trash. | 30 |
| Mailbox trash (`mailbox_trash_days`) | Mailboxes in the mailbox trash (purge). | 30 |

!!! warning "Decide the periods with whoever is responsible for data protection"
    Support mail contains personal data. How long to keep it is a legal
    decision for your organisation (GDPR: no longer than needed). Desk
    keeps everything until you decide, and the Settings page shows
    "pending legal review" for each period that is not set.

Where the values come from:

1. **Den**, when Desk is paired: Den's module settings for Desk can send
   `retention`. Every period Den sets wins and is read-only in Desk.
2. **Desk's own setting** (**Settings → Retention**, Desk admins) for the
   periods Den does not set. This is the only place in a standalone Desk.
3. The defaults above.

Set Desk's own periods with the API (the request replaces all five; leave
a field `null` to keep):

```sh
curl -s -X PUT $DESK/api/v1/settings/retention \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"closed_conversation_days":730,"attachment_days":365,"raw_mail_days":90,"trash_days":30,"mailbox_trash_days":30}'
```

The daily job applies the periods; each run that deletes something writes
an audit entry `retention.purge` with the counts. Retention never deletes
the copy at the mail provider (Gmail, your IMAP server); that follows the
provider's own rules.

## Audit log

Desk records who did what to mailboxes and mail: mailbox created, changed
(which fields, never values), moved to the trash, restored, provisioned
and purged; purge reminders; emails and conversations deleted and
restored; conversations forwarded, merged and moved; customers changed and
merged; retention changed and applied. Desk admins see it under **Settings →
Audit log**, or:

```sh
curl -s -H "Authorization: Bearer $TOKEN" "$DESK/api/v1/audit?action=mailbox.trash&limit=20"
```

Audit entries are kept as long as the database.

## Rotate DESK_SECRET_KEY

`DESK_SECRET_KEY` encrypts the IMAP and SMTP passwords stored per mailbox.
Every stored value carries the id of the key that sealed it, so you can
change the key without typing the passwords in again. Rotate it when
someone who knew it leaves, when it may have leaked, or on your regular
schedule.

1. **Generate a new key** (at least 32 characters):

    ```sh
    openssl rand -base64 32
    ```

2. **Keep the old key as previous and set the new one** in your secret
   manager (the ExternalSecret copies both into `desk-secrets`):

    ```sh
    vault kv patch secret/conservices/desk/backend \
      DESK_SECRET_KEY_PREVIOUS='<the old key>' \
      DESK_SECRET_KEY='<the new key>'
    ```

3. **Restart the backend** so it reads both keys:

    ```sh
    kubectl rollout restart -n conservices-desk deploy/desk-backend
    kubectl logs -n conservices-desk deploy/desk-backend | grep "secret key loaded"
    ```

    ```json
    {"level":"info","key_id":"9f2c41d0","previous_keys":1,"message":"secret key loaded"}
    ```

    Desk works normally now: old values open with the previous key, new
    ones are sealed with the new key.

4. **Re-encrypt every stored password** with the new key:

    ```sh
    kubectl exec -n conservices-desk deploy/desk-backend -- /server reencrypt
    ```

    ```json
    {"level":"info","key_id":"9f2c41d0","resealed":12,"already_current":0,"failed":[],"message":"reencrypt finished"}
    ```

    `failed` must be empty. If it lists values, they were sealed with a key
    that is neither current nor previous: put that key into
    `DESK_SECRET_KEY_PREVIOUS` as well (comma-separated) and run it again,
    or type those mailbox passwords in again.

5. **Remove the previous key** from the secret manager and restart the
   backend once more.

    ```sh
    vault kv patch secret/conservices/desk/backend DESK_SECRET_KEY_PREVIOUS=''
    kubectl rollout restart -n conservices-desk deploy/desk-backend
    ```

With Docker Compose: change `.env`, `docker compose up -d desk-backend`,
then `docker compose exec desk-backend /server reencrypt`.

The key id is safe to log; the key is not. See
[Secrets](../../operations/secrets.md) for the inventory.

## Backups

| What | Where | Backed up by |
| --- | --- | --- |
| Conversations, customers, settings, audit log, encrypted passwords | PostgreSQL database `desk` | The platform's database backups (CloudNativePG), or yours when standalone. |
| Attachments, inline images, original emails | S3 bucket `desk-data` | Den's operator, once the bucket is in `FILES_S3_BUCKETS`; yours when standalone. |
| `DESK_SECRET_KEY` | Your secret manager | Your secret manager. Without it a restored database cannot open the stored mailbox passwords (they can be typed in again). |
| Mail in Google Workspace | Google | Google; Desk's copy is separate. |

Restore the database and the bucket from the same point in time; a
conversation whose file is missing shows the attachment but cannot download
it.

## Troubleshooting

**Purge reminders never arrive.** `NOTIFY_FROM` is empty, or there is no way
to send (no `SMTP_HOST` and no `GOOGLE_SHARED_MAILBOX`). **Settings → Mail
connectors** says "Desk's own emails: off" in that case. Reminders only go
to Desk admins who have signed in to Desk at least once.

**A mailbox stays in the trash after its purge date.** Google refused to
delete it; the mailbox card shows the reason (for example a missing admin
right) and the log has `automatic purge failed`. Fix it, then purge by hand.

**`reencrypt` fails with `DESK_SECRET_KEY_PREVIOUS must not contain the
current DESK_SECRET_KEY`.** You put the new key in both places. The
previous list holds only old keys.

**After a restore from backup every IMAP mailbox shows "the stored
password cannot be decrypted".** The restored database was sealed with a
key you no longer use. Add that key to `DESK_SECRET_KEY_PREVIOUS`, restart
and run `/server reencrypt`.

**A retention field says "Set in Den." and cannot be changed.** Den's
module settings manage it; change it in Den (**Modules → Desk →
settings**). The API answers `422` with the same reason.
