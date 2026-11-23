# Onboarding forms (NDA, GDPR, and the rest)

This page is the operator path for **versioned onboarding forms**: HR picks
what a joining volunteer must sign, emails them a link, they sign on the
**sign-hr** host, HR is notified to review, and only then does **Approve**
create the IdP account.

Addresses (local Compose defaults; use your own domain in production):

- HR staff UI: `https://hr.conservices.test`
- Volunteer signing: `https://sign-hr.conservices.test` (must match
  `SIGNING_PUBLIC_URL`)
- Outbound mail in development: [Mailpit](https://mail.conservices.test)

Set `SIGNING_PUBLIC_URL` to the public HTTPS origin volunteers open (no
trailing slash), for example `https://sign-hr.example.org`.

## Workflow

1. **Forms library (sidebar → Forms)**  
   Open **Forms** (also linked from Settings). Create named forms such as
   **NDA** or **GDPR consent**. Drop an AcroForm PDF: HR reads the field
   names, you map each to an onboarding/person attribute, then
   **Publish version**. That creates immutable **version 1**. Later PDF or
   mapping edits publish **version 2**, **version 3**, and so on.
   In-flight and already-signed onboardings keep the version they were
   given.

2. **Start onboarding**  
   Use the usual wizard (details → access → documents → review). Drafts
   stay in state `draft`. **No forms are attached automatically.**

3. **Attach forms for this volunteer**  
   On **Documents**, attach only the forms this person needs. Attach pins
   the library’s **current published version**. Detach is allowed while
   the row is still `pending`. Attached forms always block Approve until
   signed or waived.

4. **Review → Send for signing**  
   On **Review**, check the packet, then **Send for signing**. That
   emails a link to the volunteer’s **private email** for each attached
   form (`{SIGNING_PUBLIC_URL}/s/{token}`), and moves the draft to
   `pending_approval`. **No IdP account is created.** Links expire after
   **7 days**. The raw URL is emailed only (staff APIs do not return it).
   In local Compose the message appears in Mailpit. Staff can also
   Send/Resend from Documents. Cancelling the onboarding invalidates open
   links.

5. **Volunteer opens sign-hr**  
   No staff login. The page follows Den branding (`GET /api/brand`) and
   shows the form name and version. **Continue to sign** opens that
   submission’s page on DocuSeal. DocuSeal tells HR, by webhook, when the
   person has signed. HR does not mark the document signed from the button.

6. **HR notification**  
   When every attached form is `signed` or `waived`, HR admins receive an
   email (Settings → admin notification emails, or HR admin groups) with a
   link to `{APP_BASE_URL}/onboarding/{draft_id}/review`. The draft also
   appears under **Onboarding → Ready to approve**. That is not the sidebar
   **Review queue** (IdP accounts without an HR person). The account is
   **still not** created.

7. **Human Approve**  
   On the onboarding **Review** step, after you have checked the signatures
   yourself, tick the confirmation and **Approve & create account**. That
   runs provisioning.
   It fails while any attached form is still `pending` or `sent`, or if
   you never used **Send for signing** (`pending_approval`).

8. **Stale drafts**  
   Drafts that stay in state `draft` longer than
   **onboarding auto-delete days** are removed by maintenance. When Den is
   paired and sets `hr.onboarding_auto_delete_days`, that value wins and
   is read-only in HR; otherwise set it under HR Settings. `0` turns the
   purge off. (`pending_approval` is not auto-deleted.)

## Document statuses

| Status | Meaning |
| --- | --- |
| `pending` | Attached; not sent |
| `sent` | Link emailed; waiting on the volunteer |
| `signed` | Stub Sign (or future provider) completed |
| `waived` | HR skipped under “allow waiving” (testing) |
| `stub_blocked` | Legacy/error only; not the happy path |

Required forms clear Approve only when status is **`signed`** or **`waived`**.

## Form versions

| Piece | Role |
| --- | --- |
| Library form (`document_templates`) | Stable name (NDA, GDPR, …) and default required flag |
| Version (`document_template_versions`) | Immutable PDF + field mappings + version number |
| Onboarding document | Pins one `template_version_id` at attach time |

**Publishing a new version** happens when you upload a replacement PDF or
change mappings (Publish version). Open `sent` links keep the old version.
To have someone sign the new text: detach if still pending, or send a new
attach of the updated current version after handling the old row.

The Documents UI and the sign-hr page show names like `NDA · v3`.

## Configuration

| Name | Default | Notes |
| --- | --- | --- |
| `SIGNING_PUBLIC_URL` | `https://sign-hr.conservices.test` | Public volunteer origin (HTTPS in production); no trailing slash; used in emails. Live example: `https://sign-hr.taire.gay` |
| `DOCUSEAL_API_URL` | empty | DocuSeal HR calls. Compose: `http://docuseal:3000`. Cloud Pro: `https://api.docuseal.com` or `https://api.docuseal.eu` |
| `DOCUSEAL_PUBLIC_URL` | empty | Origin the browser opens for the framed builder and the signing page. Compose: `https://docuseal.conservices.test`. Self-hosted Pro also uses this host for the embedded builder |
| `DOCUSEAL_API_TOKEN` | empty | **Secret.** API token from DocuSeal → Settings → API. Created after the first login |
| `DOCUSEAL_ADMIN_EMAIL` | empty | Email of the DocuSeal user who owns the API token. Required for the embedded builder outside development |
| `DOCUSEAL_EMBED` | empty | `true` for self-hosted Pro. `false` to keep the framed page. Empty embeds only when the API URL is Cloud Pro |
| `DOCUSEAL_WEBHOOK_SECRET` | empty | **Secret.** Checked on the completion webhook |
| `DOCUSEAL_BACKUP_KEY` | empty | **Secret.** Base64 of 32 bytes. Encrypts the backup copy of the signed PDF and audit log |
| `SMTP_*` / Den `smtp.*` | — | Required to send sign links |
| `S3_*` | — | Required to store form PDFs |
| `onboarding_auto_delete_days` | `30` | HR setting; overridden by Den when set |
| `hr.onboarding_auto_delete_days` | — | Den module settings key |
| Signing → allow waiving | off | Local testing only |

Full tables: [Configuration](configuration.md). Den keys:
[Module settings](../../concepts/module-settings.md).

## Security notes (operators)

- Session tokens in the email link are **unguessable** (32 random bytes).
  HR stores only a **SHA-256 hash** of the token.
- Open links expire after **7 days**. Cancelling the onboarding (or
  resending) marks open sessions cancelled; those links stop working.
- The volunteer host (sign-hr) must expose only public signing and brand
  APIs; staff and `/api/internal/*` stay on the HR staff origin.
- Public signing routes are **rate-limited** per client IP. Access logs
  redact the token path segment.
- Stub **Sign** is workflow state only — not a qualified electronic
  signature or non-repudiation.

## API

Use your HR base URL (`$HR`) and a staff bearer token as in
[API conventions](../../concepts/api-conventions.md). Public signing uses
`$SIGNING` = `SIGNING_PUBLIC_URL` (or the staff origin if you call the
backend directly in development).

### Staff — Forms library {#staff-forms-library}

Staff need `settings.manage` to write forms and `people.read` to read them.

| Method | Path | Who | Notes |
| --- | --- | --- | --- |
| `POST` | `/api/document-templates/inspect` | `settings.manage` (global) | Multipart `file`; returns AcroForm fields; does not store the PDF |
| `GET` | `/api/document-templates` | `people.read` | Library list |
| `POST` | `/api/document-templates` | `settings.manage` (global) | Create named form |
| `GET` | `/api/document-templates/{id}` | `people.read` | One form + current version |
| `PUT` | `/api/document-templates/{id}` | `settings.manage` (global) | Rename / metadata |
| `DELETE` | `/api/document-templates/{id}` | `settings.manage` (global) | Delete if unused |
| `GET` | `/api/document-templates/{id}/versions` | `people.read` | Version history |
| `GET` | `/api/document-templates/{id}/docuseal` | `people.read` | Builder status. `embed` is present on Pro |
| `POST` | `/api/document-templates/{id}/versions` | `settings.manage` (global) | Multipart: `file`, optional `fields` JSON, `change_note` |

```bash
curl -sS -X POST "$HR/api/document-templates/inspect" \
  -H "Authorization: Bearer $TOKEN" \
  -F "file=@./nda.pdf"
```

```json
{
  "fields": [
    { "name": "LegalName", "type": "text" },
    { "name": "DateOfBirth", "type": "text" },
    { "name": "Agree", "type": "checkbox" }
  ]
}
```

```bash
curl -sS "$HR/api/document-templates/$TEMPLATE_ID/docuseal" \
  -H "Authorization: Bearer $TOKEN"
```

On the local open-source DocuSeal, `embed` is absent and `public_url` is the framed site. On Cloud Pro in Virginia, `host` is omitted (the builder's default). On `docuseal.eu`, `host` is `docuseal.eu`. The token is a short-lived JWT signed with the API token. It is not the API token.

```json
{
  "configured": true,
  "public_url": "https://docuseal.eu",
  "builder_url": "https://docuseal.eu/templates/12/edit",
  "eidas": false,
  "embed": {
    "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.example.signature",
    "host": "docuseal.eu"
  }
}
```

### Staff — Onboarding documents {#staff-onboarding-documents}

| Method | Path | Who | Notes |
| --- | --- | --- | --- |
| `GET` | `/api/onboardings/{id}/documents` | `people.read` | Attached forms |
| `POST` | `/api/onboardings/{id}/documents` | `onboarding.manage` | Body `{ "template_id": "…" }` |
| `DELETE` | `/api/onboardings/{id}/documents/{docID}` | `onboarding.manage` | Only while `pending` |
| `GET` | `/api/onboardings/{id}/documents/{docID}/pdf` | `people.read` | Filled PDF; `?download=1` for attachment |
| `POST` | `/api/onboardings/{id}/documents/{docID}/send` | `onboarding.manage` | Emails link; response is `{ "document": {…} }` (no raw URL) |
| `POST` | `/api/onboardings/{id}/documents/{docID}/waive` | `onboarding.manage` | Only when waiving is enabled |
| `POST` | `/api/onboardings/{id}/documents/{docID}/unwaive` | `onboarding.manage` | |
| `POST` | `/api/onboardings/{id}/submit-for-signing` | `onboarding.manage` | Lock packet, email pending forms → `pending_approval` |
| `POST` | `/api/onboardings/{id}/complete` | `access.manage` | Approve after signatures; queues IdP provisioning |
| `POST` | `/api/onboardings/{id}/cancel` | `onboarding.manage` | Rejects draft/`pending_approval` and cancels open sign links |

```bash
curl -sS -X POST "$HR/api/onboardings/$DRAFT_ID/documents/$DOC_ID/send" \
  -H "Authorization: Bearer $TOKEN"
```

```json
{
  "document": {
    "id": "…",
    "status": "sent",
    "status_note": "Sign link emailed to volunteer@example.org"
  }
}
```

```bash
curl -sS -o filled.pdf -D - \
  "$HR/api/onboardings/$DRAFT_ID/documents/$DOC_ID/pdf" \
  -H "Authorization: Bearer $TOKEN"
```

```http
HTTP/1.1 200 OK
Content-Type: application/pdf
Content-Disposition: inline; filename="nda.pdf"
```

```bash
curl -sS -X POST "$HR/api/onboardings/$DRAFT_ID/submit-for-signing" \
  -H "Authorization: Bearer $TOKEN"
```

```json
{
  "draft": { "id": "…", "state": "pending_approval" },
  "sent": 2,
  "message": "Sign links sent by email. The account is not created yet — wait for signatures, check them, then Approve."
}
```

### Public — volunteer sign-hr {#public-volunteer-sign-hr}

Token in the path; no staff OIDC.

| Method | Path | Who | Notes |
| --- | --- | --- | --- |
| `GET` | `/api/public/signing/{token}/` | public | Session metadata |
| `GET` | `/api/public/signing/{token}/pdf` | public | Filled PDF |
| `POST` | `/api/public/signing/{token}/sign` | public | Stub Sign; requires open `sent` session and a waiting draft |

```bash
curl -sS -X POST "$SIGNING/api/public/signing/$TOKEN/sign"
```

Errors: **404** unknown/cancelled token; **409** expired or no longer
open; **429** rate limited.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Cannot attach a form | Publish a version with a PDF first |
| Upload finds no fields / inspect error | PDF must have AcroForm fillable fields (not a flat scan). LibreOffice samples are fine; flat “print to PDF” files are not |
| PDF preview blank or blocked | Forms iframe needs `EXTRA_FRAME_SRC=blob:` on the HR frontend (Compose and chart default). Use **Open in new tab** if the browser still blocks the viewer |
| Send fails: email | Person needs private `email`; SMTP or Den SMTP must be configured |
| Send fails: storage | `S3_*` must be set for PDF upload/fill |
| Sign link 404 or “no longer open” | `SIGNING_PUBLIC_URL` matches the volunteer host; link not expired (7 days); onboarding not cancelled; sign-hr / ingress up |
| Sign link works on staff URL but not sign-hr | Volunteer host must proxy `/api/public/signing/` and `/api/brand` only |
| Cannot Approve | Attached forms still not `signed` or `waived`, or draft never reached `pending_approval` |
| Draft vanished | Auto-delete days elapsed while still `draft` |

## DocuSeal

A form is a DocuSeal template. **Forms** is a full-height workspace: the
library stays on the left, and the builder fills the rest of the page.

The local Compose DocuSeal is a **development** copy. It is the open-source
image, so it has no embedded-builder license and it can only produce **SES**.
HR frames that site edge to edge. Its own pages stay DocuSeal's, including
the logo and the purple buttons. Set `DOCUSEAL_ADMIN_EMAIL` only when you
move to Pro.

The standard deployment is **DocuSeal Pro**. HR then mounts DocuSeal's
embedded form builder in that same workspace and themes it to HR (light and
dark, indigo actions, Inter). Send and Sign yourself are hidden, because HR
sends the form. Saving in the builder stores the template id, so staff do
not copy it by hand. Staff still sign in to HR with the same SSO as the
other modules. The builder JWT is minted by HR. It names
`DOCUSEAL_ADMIN_EMAIL` (the DocuSeal user who owns the API token) and the
staff member's email, and it expires after 12 hours.

Cloud Pro turns the embed on by itself. A DocuSeal you run needs
`DOCUSEAL_EMBED=true` and a Pro license, plus that origin on the HR
frontend's `EXTRA_CONNECT_SRC` and `EXTRA_FRAME_SRC`. Virginia loads
`https://cdn.docuseal.com/js/builder.js`. Ireland loads
`https://cdn.docuseal.eu/js/builder.js`, and that file then loads the rest
from `https://docuseal.eu`. Both origins belong in `script-src`
(`EXTRA_SCRIPT_SRC`). The page preview is an image. Ireland serves it from
`https://docuseal-eu.s3.eu-west-1.amazonaws.com`, so `img-src` allows that
host too (`EXTRA_IMG_SRC`). AES and QES exist only on the Pro service at `docuseal.eu`.

**Publish** stores the DocuSeal template id and the signature level.
The PDF itself stays in DocuSeal.

HR calls one API. `DOCUSEAL_API_URL` is the DocuSeal we run (`http://docuseal:3000`
in Compose), `https://api.docuseal.com` (Cloud Pro, Virginia), or
`https://api.docuseal.eu` (Cloud Pro, Ireland). Cloud Basic cannot be used:
it has no production API and no webhooks, and it sends only 10 signature
emails a month.

| Level | What it is | When Send works |
| --- | --- | --- |
| SES | The volunteer signs and DocuSeal seals the PDF with its server certificate. On the free image that certificate is created at first start (self-signed) unless you upload your own. This is the signature US law (ESIGN and, in most states, UETA) treats as an electronic signature. | Local DocuSeal, or Cloud Pro on `docuseal.com` or `docuseal.eu` |
| AES | The signer is identified by a provider, and the signing key is under the signer’s control. DocuSeal sells this only on `docuseal.eu`, at **$2** per signature. The PDF and the signer’s identity leave the cluster. The form builder does not create an AES. | Only when `DOCUSEAL_API_URL` is on `docuseal.eu` |
| QES | A qualified signature. In the EU it has the same effect as a handwritten signature. Unsupported on a DocuSeal you run. Prices on `docuseal.eu`: **$0.20** with the signer’s own certificate or ID card, **$2** via a provider, **$4** one-shot. | Only when `DOCUSEAL_API_URL` is on `docuseal.eu` |

Cloud Pro is **$20** per dashboard user per month (**$200** per year) plus
**$0.20** per document completed through the API. A volunteer is not a user.
One submission with several files and signers counts as one completion.

The webhook is `POST /api/public/docuseal/webhook?secret=<DOCUSEAL_WEBHOOK_SECRET>`
on the HR backend. In Compose, set that URL in DocuSeal to
`http://hr-backend:8080/api/public/docuseal/webhook?secret=dev-only-docuseal-webhook-secret`.
On completion HR marks the document signed and writes an encrypted backup of
the signed PDF and the audit log into HR’s bucket. Staff still open
DocuSeal’s copy. The backup is not shown in the app.

The live volunteer host for this installation is `https://sign-hr.taire.gay`.
Local Compose stays on `https://sign-hr.conservices.test`. The Google
Workspace key for `taire.gay` belongs in OpenBao at
`modules/hr/google-workspace` (`credentials.json`). It is not part of the
DocuSeal sandbox and it is not stored in git.

## Older PDF versions

Versions published before DocuSeal still have an AcroForm PDF in HR’s bucket.
Those keep the local **Sign** button. New versions do not.
