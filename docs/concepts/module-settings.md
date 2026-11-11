# Module settings

**Module settings** are the settings an organisation decides once and every
module must follow: how long personal data is kept, which mail server sends
mail, the seller details on Finance's receipts, how long Stash keeps lost
and found items. With Den, an admin sets them on Den's **Module settings**
page and Den hands each module its part in the
[integration bundle](pairing.md#what-a-paired-module-receives). A
standalone module offers the same settings on its own settings page.

This page is the **contract for 1.0**. Den and each module implement it in
their own release (their changelogs say when); until then each module
keeps its current settings and environment variables.

!!! warning "Retention defaults are pending legal review"
    Every retention default below is a placeholder marked *pending legal
    review*. They have not been checked against the GDPR or any other law.
    Set values your organisation has approved before you hold real data.

## How a module uses them

1. Den adds `module_settings` to `GET /api/v1/integrations/bundle`. It
   contains only the settings of the module that asks (Den knows it from
   the module credential).
2. For every key Den sets, the module uses Den's value and shows it as
   *Managed in Den*, read-only, as it already does for organisation
   settings.
3. A key Den leaves out falls back to the module's own setting.
4. A standalone module (or one Den sets nothing for) shows the same keys,
   with the same names, limits and defaults, on its own settings page.
5. Secrets never travel in the bundle (the module caches the bundle in its
   database). The bundle says `password_set: true`; the module fetches the
   value when it needs it from `GET /api/v1/integrations/module-settings/secrets`
   and keeps it in memory only.

## The settings

### Retention

| Key | Applies to | Default | Meaning |
| --- | --- | --- | --- |
| `retention.offboarded_volunteers_days` | HR, and every module holding volunteer data | `365` *(pending legal review)* | Days after offboarding before a volunteer's personal data is deleted or anonymised. |
| `retention.inactive_users_days` | every module | `730` *(pending legal review)* | Days without a sign-in before a local user record is deleted or anonymised. |
| `retention.module_data_days` | every module | `1095` *(pending legal review)* | Days after the convention's end date before the module's own records (tickets, submissions, items, …) are deleted. `0` keeps them. |

**Backups.** Deleting data in a module does not remove it from backups made
earlier. It is gone from them only when those backups expire (Den's backup
retention; see
[Databases, backups and restore](../operations/databases-and-backups.md)).
Say so in your privacy notice: the real retention is the setting **plus**
the backup retention. A restore brings deleted data back, and the next
retention run deletes it again.

### Mail (SMTP)

| Key | Meaning |
| --- | --- |
| `smtp.host`, `smtp.port` | Mail server; port default `587`. |
| `smtp.security` | `starttls` (default), `tls` or `none` (development only). |
| `smtp.username` | Login; empty for none. |
| `smtp.password_set` | `true` when Den holds a password; the value comes from the secrets endpoint. |
| `smtp.from`, `smtp.from_name` | Sender address and name. |

These replace a module's `SMTP_*` variables when Den sets `smtp.host`.

### Finance: seller details

`finance.seller`: `legal_name`, `address` (multi-line), `country` (ISO 3166
code such as `AT`), `vat_id`, `tax_number`, `registration` (court and
number), `email`, `website`. Printed on receipts and invoices.

### Stash: Lost & Found retention

`stash.lost_found` is one of:

| Mode | Fields | Meaning |
| --- | --- | --- |
| `kept_after_con` | `days` (default `30` *(pending legal review)*) | Unclaimed items and their finder details are kept until `days` after the convention's end date. |
| `deleted_after_closing` | `hours` (default `48` *(pending legal review)*) | A record is deleted `hours` after it is closed (claimed, handed over or discarded). |

## In the bundle

```json
{
  "brand": { "revision": 10, "organization_name": "Con Services Demo" },
  "settings": { "data": { "organization_name": "Con Services Demo" }, "updated_at": "2026-11-05T13:58:34Z" },
  "module_settings": {
    "updated_at": "2026-11-11T09:30:00Z",
    "data": {
      "retention": { "inactive_users_days": 730, "module_data_days": 1095 },
      "smtp": {
        "host": "smtp.example.org", "port": 587, "security": "starttls",
        "username": "conservices", "password_set": true,
        "from": "stash@con.example.org", "from_name": "Stash"
      },
      "stash": { "lost_found": { "mode": "kept_after_con", "days": 30 } }
    }
  }
}
```

## Den API

### `GET /api/v1/modules/{id}/settings` and `PUT /api/v1/modules/{id}/settings`

The settings Den sends to one module. **Who may call it:** a Den admin
(`modules.manage`).

**Request body (`PUT`):** the whole `data` object. Keys left out are not
sent to the module (it uses its own value). `smtp.password` may be given to
set or replace the password; it is never returned.

**Response:** `200` with `{"data": {…}, "updated_at": "…"}`;
`smtp.password` appears only as `smtp.password_set`.

**Errors:**

| Status | Code | When |
| --- | --- | --- |
| `401` / `403` | `unauthorized` / `forbidden` | Not signed in, or not an admin. |
| `404` | `not_found` | No such module. |
| `422` | `validation_failed` | A value is out of range; `details` names the key, for example `{"stash.lost_found.mode": "must be kept_after_con or deleted_after_closing"}`. |

```sh
curl -s -X PUT https://den.con.example.org/api/v1/modules/$STASH_ID/settings \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"data":{"stash":{"lost_found":{"mode":"deleted_after_closing","hours":48}}}}'
```

```json
{"data":{"stash":{"lost_found":{"mode":"deleted_after_closing","hours":48}}},"updated_at":"2026-11-11T09:30:00Z"}
```

### `GET /api/v1/integrations/module-settings/secrets`

The secret values of the calling module's settings. **Who may call it:** a
paired module, with its module credential. **Response:** `200`
`{"smtp": {"password": "…"}}`; keys without a value are left out.
**Errors:** `401` (missing or revoked credential).

```sh
curl -s https://den-backend.conservices-den.svc.cluster.local:8080/api/v1/integrations/module-settings/secrets \
  -H "Authorization: Bearer $MODULE_CREDENTIAL"
```

```json
{"smtp":{"password":"change-me"}}
```

Den stores these values encrypted. They are secrets in the sense of
[Secrets](../operations/secrets.md): rotate the SMTP password at the mail
provider, then save the new one on Den's Module settings page; modules pick
it up on their next fetch.

## Troubleshooting

**A setting shows *Managed in Den* but the admin wants to change it in the module**
: Change it in Den (Module settings), or remove the key there so the
  module's own value applies.

**Mail stopped after setting SMTP in Den**
: The module could not fetch the password (Den unreachable or the
  credential was revoked). The module's Den connection page shows the
  error; pair again if it says the credential was rejected.
