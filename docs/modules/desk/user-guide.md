# Using Desk

This page is for the people who answer support mail. Desk shows every email
thread to a support address as a **conversation**; you assign it, answer
it, add internal notes and close it. Customers just get email from the
support address.

What you can do depends on your roles per mailbox ([Access](access.md)):
**viewers** read, **managers** answer and organise, **delete** may delete
and restore.

## The inbox

The sidebar lists the mailboxes you can see. Each has folders with counts:

| Folder | Shows |
| --- | --- |
| **Unassigned** | Open conversations nobody has taken yet. Start here. |
| **Mine** | Open or pending conversations assigned to you. |
| **Assigned** | Open or pending conversations assigned to anyone. |
| **Pending** | Answered, waiting for the customer. A customer reply moves it back to open. |
| **Closed** | Done. A customer reply reopens it. |
| **Spam** | Marked as spam; hidden everywhere else. |
| **All** | Everything except spam. |
| **Starred** | Conversations you starred (stars are personal). |
| **Trash** | Deleted emails and conversations, for 30 days. Only with the `delete` role. |

Search (`/`) finds subjects, message text, customer names and addresses,
and `#17` finds conversation number 17. **Filter by tag** shows every
conversation with one tag.

## Answering

1. Open a conversation. If someone else has it open, a banner shows who is
   viewing or replying, so you do not answer twice.
2. **Reply** (`r`) writes to the customer; **Note** (`n`) writes an internal
   note that is never emailed.
3. The editor supports bold, lists and links. **Insert saved reply…** adds
   a prepared answer; the mailbox's signature is added when sent.
4. A reply keeps the people who were in copy of the last message (not the
   mailbox itself or the customer); edit the **Cc** line as needed (at most
   20 addresses).
5. Pick the status after sending (default **Pending**) and send.
6. For **10 seconds** the reply can be undone. After that it is sent; if
   sending fails, Desk retries for an hour and then shows **Not sent** with
   a **Retry** button and the reason.

Answering an unassigned conversation assigns it to you.

Other actions on a conversation: **assign** (`a` assigns to you), **close**
(`x`), **tags**, **star** (`s`), **forward** a message to someone outside,
**merge** into another conversation, **move** to another mailbox, and with
the `delete` role **delete** a single email or the whole conversation.

**New conversation** (`c`) writes to a customer first, from a mailbox you
manage.

## Customers

The customer card next to a conversation shows the customer's name, notes,
addresses and other conversations. Managers can edit the name and notes,
add another address the customer writes from, and merge two customers who
turned out to be the same person.

## Email bodies and attachments

Emails are shown in a protected frame: scripts never run, and images from
the internet are only loaded when you click **Show images** (they can tell
the sender you opened the mail). Images, PDFs and plain-text attachments
can be shown in the browser; every other type is only downloaded, so a
hostile file cannot run inside Desk.

## Notifications

**Settings → Email notifications**: get an email for every new conversation
in your mailboxes, and when a conversation is assigned to you. Both are off
until you turn them on, and only work when your installation has set up
Desk's own email (`NOTIFY_FROM`).

## Keyboard shortcuts

Press `?` anywhere to see them. They do nothing while you type in a field
or the editor (except `Escape`).

| Keys | Does |
| --- | --- |
| `j` / `k` | Next / previous conversation in the list |
| `Enter` | Open the selected conversation |
| `/` | Search |
| `c` | New conversation |
| `r` | Reply (in a conversation) |
| `n` | Internal note (in a conversation) |
| `a` | Assign to me |
| `x` | Close the conversation |
| `s` | Star or unstar |
| `u` | Back to the inbox |
| `?` | Show the shortcuts |
| `Escape` | Close a dialog or leave the editor |

## Troubleshooting

**I do not see a mailbox.** You have no role for it, or your sign-in is
older than the change. Sign out and in again; otherwise ask a Desk admin
for the mailbox's `viewer` or `manager` role.

**The Reply button is missing.** You only have the `viewer` role.

**"you need the manager role of this mailbox".** Same: ask for `manager`.

**I cannot assign to a colleague.** They need the `manager` role of this
mailbox and must have signed in to Desk once.

**A reply shows "Not sent".** The reason is shown under it. Retry once the
problem is fixed, or tell a Desk admin (the mailbox's mail server may be
down).
