# Bookkeeping with Finance

This page is for the people who keep the books: **bookkeepers**, who
record invoices and money, **approvers**, who check and approve what
bookkeepers record, and **admins**. It explains each task in the web app
and names the API call behind it ([API reference](api.md)).

Terms used here:

- **Issue**: turn a draft into a numbered invoice. After that it cannot be
  edited or deleted.
- **Credit note**: a numbered document that corrects an issued invoice, in
  full or in part. It has its own series (`FIN-CN-0001`).
- **Refund**: money paid back to a customer against a credit note.
- **Four-eyes approval**: a request by one person that only takes effect
  once a different person approves it.
- **Closed month**: a month nothing can be added to or changed in.

!!! note "Pending accountant review"
    Finance keeps money simple: one currency, a default VAT rate, number
    prefixes. Have your accountant confirm the VAT rates, the invoice
    contents your country requires and how credit notes are used before you
    rely on Finance for your books.

## Before the first invoice

1. **An admin checks Settings.** Open **Settings**. Under *Seller on new
   invoices* the name and address must be filled in (from Den → Module
   settings → Finance, or set on this page). *This installation* shows the
   currency, the default VAT rate, the number prefixes and above which
   amount approval is needed.
2. **People have their roles.** At least one bookkeeper and one approver
   who are different people. With the default threshold of 0, every
   payment, void, expense, credit note and refund needs the approver.
3. **The first draft.** A bookkeeper opens **Customers**, adds the
   customer, then **Invoices → New invoice**.

You should see the draft with **Edit**, **Issue** and **Delete** buttons.

## Issue an invoice

1. Open the draft and check the lines, the customer and the *From* and
   *Bill to* blocks.
2. Click **Issue** and confirm.
3. The invoice gets the next number (`FIN-0001`), today's date and a due
   date (the draft's, else 30 days later). The customer and seller details
   are frozen: editing the customer later does not change this invoice.
4. Click **PDF** to download the stored PDF and send it to the customer.

API: `POST /api/invoices/{id}/issue`, then `GET /api/invoices/{id}/pdf`.

If issuing fails nothing changes and no number is used; the message says
why (missing seller details, closed month, PDF storage unavailable).

## Record a payment

1. Open the invoice, click **Record payment**.
2. Enter the amount (at most what is still owed), the date it arrived, the
   method and the bank reference.
3. Click **Record payment**. If the amount needs approval, Finance says
   *Sent for approval*; the payment is listed under *Waiting for approval*
   on the invoice and does not count yet.

API: `POST /api/invoices/{id}/payments` with an `Idempotency-Key`. If the
page hangs and you are unsure whether it worked, reload the invoice before
trying again: the web app sends the same key on a retry, so nothing is
recorded twice.

## Four-eyes approval

Voids, payments, expenses, credit notes and refunds above
`FINANCE_APPROVAL_THRESHOLD_CENTS` (default 0) wait for a second person.

**As an approver:**

1. Open **Approvals**. Each request shows what will happen, the amount and
   who asked.
2. Check it against the evidence (bank statement, receipt). **Open the
   invoice** shows the invoice.
3. Click **Approve** (an optional note goes into the audit log) or
   **Reject** (a reason is required).

Approving carries the request out at that moment, checking everything
again. If the invoice was paid or the month closed in the meantime,
approving fails with the reason; reject the request then.

**As the person who asked:** the same page shows **Withdraw** on your own
requests. You can never approve your own request, not even as an admin.

API: `GET /api/approvals?status=pending`,
`POST /api/approvals/{id}/approve`, `POST /api/approvals/{id}/reject`.

## Correct a mistake

Which tool fits:

| Situation | Do this |
| --- | --- |
| A draft is wrong | **Edit** it, or **Delete** it. |
| An issued invoice was sent by mistake and **nothing was paid** | **Void** it with a reason. The number stays taken. |
| An issued invoice is wrong and money was paid, or part of it is wrong | Issue a **credit note** for the wrong part. If the customer paid more than the corrected total, record a **refund**. |
| A payment was recorded on the wrong invoice | Issue a credit note on that invoice for the amount, record a refund of the payment there, then record the payment on the right invoice. |
| An expense is wrong | **Delete** it with a reason and record it again. The amount and date of an expense cannot be edited. |

### Issue a credit note

1. Open the issued invoice, click **Credit note**.
2. Choose **The whole invoice** (only while it has no credit notes) or
   **Part of it** and enter what is credited, net, with its tax rate.
3. Enter the reason; it is printed on the credit note.
4. Click **Issue credit note**. After approval (if needed) it gets the next
   `FIN-CN-` number and its own PDF, listed under *Credit notes* on the
   invoice. The invoice shows *Credited* and the new *Still owed*.

API: `POST /api/invoices/{id}/credit-notes`.

### Pay a refund

1. On the invoice, *To refund* shows what the customer paid too much.
2. Next to the credit note click **Refund**, enter the amount (at most *To
   refund*), the date and the bank reference.
3. After approval (if needed) the refund is listed under *Refunds* and in
   the ledger as money out.

API: `POST /api/credit-notes/{id}/refunds`.

### Void an invoice

1. Open the invoice (issued, no payments, no credit notes), click **Void**.
2. Enter the reason and click **Void**. After approval (if needed) the
   invoice shows *Void*; it stops counting as owed.

API: `POST /api/invoices/{id}/void`.

## Close a month

Once the bank statement for a month is reconciled:

1. An approver opens **Settings → Closed months**, picks the month and
   clicks **Close month**.
2. From then on nothing dated in that month can be issued, paid, refunded,
   credited, voided, recorded, changed or deleted; Finance answers
   `period_closed`.
3. If something must still change, an **admin** clicks **Reopen** next to
   the month and gives the reason. The reopening and the reason are in the
   audit log. Close the month again afterwards.

API: `POST /api/periods/{month}/close`, `POST /api/periods/{month}/reopen`.

## Check the audit log

Admins, approvers and read-only users open **Audit log**. Filter by kind of
record, action (`invoice`, `payment.recorded`, …) or person. Click a row to
see who it was (name, issuer, subject) and the values before and after.

API: `GET /api/audit`.

## Backups and retention

Invoices, credit notes and their PDFs are legal records with retention
periods (often 6 to 10 years). Finance never deletes them. Make sure:

- the `finance` database is in Den's nightly backups (or your own
  `pg_dump`), and
- the PDF bucket is in Den's `FILES_S3_BUCKETS` (or has versioning and a
  copy elsewhere).

To restore one PDF, put the object back under the same key
(`invoices/<invoice id>/<number>.pdf`); Finance checks it against the
SHA-256 it stored at issue.

## Troubleshooting

| What you see | Why, and what to do |
| --- | --- |
| *Sent for approval* after every payment | The threshold is 0. Ask an approver to approve, or the operator to raise `FINANCE_APPROVAL_THRESHOLD_CENTS`. |
| No **Approve** button on a request | It is your own request, or you do not have the approver role. |
| Approving fails with "can never be voided" or "exceeds what is still owed" | The invoice changed since the request. Reject the request and make a new one. |
| "2026-10 is closed" | The date is in a closed month. Use today's date, or ask an admin to reopen the month. |
| No **Void** button on an issued invoice | It has payments or credit notes. Issue a credit note instead. |
| **Issue** fails: seller name and address needed | An admin sets them on **Settings** (or in Den → Module settings → Finance). |
| **Issue** fails: PDF storage not configured | The operator must set the `S3_*` settings ([Configuration](configuration.md)). |
| The amount field of an expense is greyed out | Amount and date are fixed once recorded. Delete the expense with a reason and record it again. |
