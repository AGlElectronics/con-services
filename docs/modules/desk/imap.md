# IMAP and SMTP mailboxes

Use this connector for a support address that is **not** in Google
Workspace: your own mail server, a hosting provider's mailbox, or the test
servers in development. Desk logs in with a username and password, reads
new mail over **IMAP** (the protocol mail programs use to read a mailbox)
and sends replies over **SMTP** (the protocol for sending). For mailboxes in
Google Workspace use [the Google connectors](google-workspace.md) instead.

## How it works

- Every `FETCH_INTERVAL` (60 seconds by default) Desk logs in, opens
  `INBOX` and imports every message it has not seen yet (it remembers the
  last message number, the IMAP `UID`).
- Each imported message is marked **read** (`\Seen`) on the server. If the
  mailbox has a folder to move mail to (`imap_move_to`, for example
  `Desk`), it is then moved to that folder, which must exist. Desk never
  deletes mail on the server.
- Replies go out through the mailbox's own SMTP server, or, if it has
  none, through the module-wide server set with `SMTP_*`
  ([Configuration](configuration.md#backend)).
- A mailbox that keeps failing is polled less often: the wait doubles after
  every failure in a row, up to one hour, so a wrong password does not
  lock the account. A successful fetch resets it.

Passwords are encrypted in the database with `DESK_SECRET_KEY` and never
shown again; see [Operations](operations.md#rotate-desk_secret_key).

## Safety rules

| Rule | Why |
| --- | --- |
| Security must be `tls` (port 993 for IMAP, 465 for SMTP) or `starttls` (143, 587). `none` (plaintext) is only accepted with `APP_ENV=development`. | Passwords and mail never cross the network unencrypted. |
| Hosts that resolve to private, loopback or link-local addresses (`10.x`, `192.168.x`, `127.0.0.1`, `169.254.x`, `fd00::/8` and similar) are refused, unless listed in `DESK_ALLOWED_MAIL_HOSTS`. The check runs when Desk connects, on every resolved address. | A mailbox form must not become a way to probe the cluster's internal services. |
| Changing the IMAP (or SMTP) host or username needs the password again in the same change. | A stored password is never sent to a server it was not typed in for. |
| Errors in the web app are short ("could not connect", "login failed"); details are only in the backend log. | Error messages do not leak internal network details. |

For an on-site mail server on a private address, add it:

```yaml
config:
  DESK_ALLOWED_MAIL_HOSTS: "mail.internal.example.org,10.20.30.0/24"
```

## Add an IMAP mailbox

1. As `desk-admin`: **Mailboxes → New mailbox**, connector **IMAP / SMTP
   server**.
2. Fill in:

    | Field | Example | Notes |
    | --- | --- | --- |
    | Name | `Support` | Shown in the sidebar and as the sender name. |
    | Address | `support@example.org` | A plain address. Also sets the slug (`support`) that names the [roles](access.md). |
    | Incoming mail (IMAP) | `imap.example.org`, port `993`, security `tls`, login and password | |
    | After fetching, move mail to folder | `Desk` (optional) | An existing IMAP folder. Empty: mail stays in `INBOX`, marked read. |
    | Outgoing mail (SMTP) | `smtp.example.org`, port `587`, `starttls`, login and password (optional) | Empty: the module-wide `SMTP_*` server is used. |
    | Signature | `-- {agent.name}, Support team` | `{agent.name}` becomes the name of the person replying. |

3. **Create mailbox**, then **Test connection** on the mailbox card. It
   logs in to IMAP (and opens `INBOX`) and SMTP without changing anything
   and shows which SMTP server was used.
4. Send a test mail to the address. It appears under **Unassigned** within
   `FETCH_INTERVAL`, or right away with **Fetch now**.
5. Grant people the mailbox's roles ([Access](access.md)).

The same with the API ([reference](api.md#post-apiv1mailboxes)):

```sh
curl -s -X POST $DESK/api/v1/mailboxes \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"Support","email":"support@example.org","connector":"imap",
       "imap_host":"imap.example.org","imap_port":993,"imap_security":"tls",
       "imap_username":"support@example.org","imap_password":"change-me",
       "imap_move_to":"Desk"}'
curl -s -X POST -H "Authorization: Bearer $TOKEN" $DESK/api/v1/mailboxes/<id>/test
```

```json
{"imap_ok":true,"smtp_ok":true,"smtp_via":"smtp.example.org:587"}
```

## Network

On Kubernetes the chart's `networkPolicy.extraEgress` allows IMAP and SMTP
(993, 143, 465, 587) to any address by default. Narrow it to your mail
provider where you can:

```yaml
networkPolicy:
  extraEgress:
    - to: [{ ipBlock: { cidr: 203.0.113.0/24 } }]   # your mail provider
      ports:
        - { protocol: TCP, port: 993 }
        - { protocol: TCP, port: 587 }
```

## Providers that refuse passwords

Microsoft 365 and Gmail mostly refuse IMAP and SMTP password logins
(they want OAuth2). For Gmail, use the [Google connectors](google-workspace.md).
For Microsoft 365, use an app password where your tenant allows it; OAuth2
for Microsoft 365 is not supported yet.

## Troubleshooting

**"plaintext (none) is only allowed in development; use tls or
starttls".** Change the security to `tls` or `starttls`. Only the
development test servers (GreenMail, Mailpit) use `none`.

**"this server is on a private or internal network address; an
administrator can allow it with DESK_ALLOWED_MAIL_HOSTS".** Add the host
name or its network to `DESK_ALLOWED_MAIL_HOSTS` and restart the backend.

**"enter the password again when the IMAP server or username changes".**
Type the password into the form again together with the new host.

**"could not connect: the server did not answer in time".** The network
policy blocks it (check the ports in `networkPolicy.extraEgress`), or a
firewall in front of the mail server does.

**"secure connection failed: the server does not speak TLS on this
port".** Port and security do not match: 993 is `tls`, 143 is `starttls`
(likewise 465 and 587 for SMTP).

**"secure connection failed: the server's certificate is not valid for this
name".** Use the host name the certificate was issued for, usually the
provider's documented server name rather than your own domain.

**"login failed: check the username and password".** Wrong username or
password, or the provider needs an app password (see above).

**Mail shows up only after an hour.** The mailbox had failed several times
in a row and is backing off. **Fetch now** tries immediately; the card
shows the next try.

**A message never shows up, other mail does.** Desk could not read or
store it (for example a broken message, or S3 was unreachable), recorded it
as an import failure and skipped it so the mailbox keeps working. List
them with sender, subject and reason:
`GET /api/v1/mailboxes/{id}/import-failures`
([reference](api.md#get-apiv1mailboxesmailboximport-failures)).

**Replies stay "Not sent".** The mailbox has no SMTP server and
`SMTP_HOST` is empty, or the server refused. The reply shows the reason;
Desk retries after 1, 5, 15 and 60 minutes, then offers **Retry**.
