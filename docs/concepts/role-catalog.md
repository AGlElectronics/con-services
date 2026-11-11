# Role catalog

The **role catalog** is the list of roles a module understands, and for
each role the Keycloak group that grants it. Every backend publishes its
catalog at `GET /api/role-catalog`. HR collects all catalogs to build its
access picker: giving someone a role in HR adds them to that role's group
(see [Authentication → From groups to roles](authentication.md#from-groups-to-roles)).

This page is the **contract for 1.0**: what every catalog must contain, who
may read it and how HR finds the modules. Each module implements it in its
own release, which says so in its changelog. Until a module does, its
catalog stays public and has no `privileged` field, and HR finds it only
through `ROLE_CATALOG_SOURCES`.

## What changes

| Today | 1.0 contract |
| --- | --- |
| Roles are a fixed list in each module. | Roles may be **dynamic**: a module publishes roles for things admins create at run time, for example Desk one role per mailbox. |
| Nothing marks admin-type roles. | Every role has `privileged: true` or `false`. |
| `GET /api/role-catalog` is public. | It needs **HR's service token** or a **staff sign-in**. |
| HR reads the modules listed in `ROLE_CATALOG_SOURCES`. | HR asks Den for the paired modules and reads each one's catalog. `ROLE_CATALOG_SOURCES` becomes an optional override. |

## `GET /api/role-catalog`

**Who may call it:**

- HR's backend, with `Authorization: Bearer <HR_SERVICE_TOKEN>`. The module
  checks the token in constant time against its own `HR_SERVICE_TOKEN`; the
  token allows nothing but reading the catalog.
- A person signed in to the staff realm, with the module's usual token
  (any role, or none: the catalog lists role names, not who holds them).

The path stays open while a module waits for Den
(`DEN_MODE=required`), as today.

**Request body:** none.

**Response:** `200` with:

| Field | Type | Meaning |
| --- | --- | --- |
| `module` | string | The module's slug. |
| `display_name`, `description` | string | Shown in HR's access picker. |
| `revision` | string | Changes whenever the list changes; HR may cache the catalog until it does. Also sent as the `ETag` header. |
| `roles[].key` | string | Stable id of the role inside the module. Dynamic roles use `<kind>:<id>`, for example `mailbox:fundraising`. |
| `roles[].label`, `roles[].description` | string | Human-readable. |
| `roles[].group` | string | The Keycloak group that grants it, as stored (normalised; see [How groups are matched](authentication.md#how-groups-are-matched)). Empty when the role cannot be assigned through a group. |
| `roles[].group_display` | string | The group as the admin typed it. |
| `roles[].assignable` | bool | Whether HR may offer it. |
| `roles[].default` | bool | HR gives it to new people by default. |
| `roles[].scope` | string | `organization`, or the kind of thing it applies to (`mailbox`, `department`, …). |
| `roles[].privileged` | bool | **New.** An admin-type role: it can change settings, see other people's data or grant access. HR asks for confirmation before assigning it, shows it in a separate *Privileged access* list on the person, and lists it in the offboarding warning. |
| `roles[].dynamic` | bool | **New.** The role exists because of something created at run time and disappears with it. |
| `roles[].permissions` | string[] | What the role allows inside the module. |

**Errors:**

| Status | Code | When |
| --- | --- | --- |
| `401` | `unauthorized` | No token, an unknown service token, or an invalid sign-in token. |
| `404` | `not_found` | The module has no catalog. |

Example: HR reading Desk's catalog.

```sh
curl -s https://desk-backend.conservices-desk.svc.cluster.local:8080/api/role-catalog \
  -H "Authorization: Bearer $HR_SERVICE_TOKEN"
```

```json
{
  "module": "desk",
  "display_name": "Desk",
  "description": "Shared mailboxes and tickets.",
  "revision": "2026-11-11T16:02:11Z-14",
  "roles": [
    {
      "key": "admin",
      "label": "Desk admin",
      "description": "Manage mailboxes, rules and who may use them.",
      "group": "desk-admin",
      "group_display": "desk-admin",
      "assignable": true,
      "scope": "organization",
      "privileged": true,
      "dynamic": false,
      "permissions": ["settings.manage", "mailbox.manage"]
    },
    {
      "key": "mailbox:fundraising",
      "label": "Mailbox: Fundraising",
      "description": "Read and answer fundraising@con.example.org.",
      "group": "desk/mailboxes/fundraising",
      "group_display": "/desk/mailboxes/Fundraising",
      "assignable": true,
      "scope": "mailbox",
      "privileged": false,
      "dynamic": true,
      "permissions": ["ticket.read", "ticket.reply"]
    }
  ]
}
```

Without a token:

```json
{"error":{"code":"unauthorized","message":"authentication required"}}
```

### Dynamic roles

- The module creates the role (and asks the admin for its group) when the
  thing is created, and removes it from the catalog when the thing is
  deleted.
- HR never deletes a Keycloak group by itself. People who still hold a
  group whose role disappeared are shown in HR as *role no longer offered
  by Desk*, so an admin can remove them.
- `key` never changes for the life of the thing, even when it is renamed;
  only `label` does.

## How HR finds the catalogs

1. HR asks Den which modules are paired, with its own module credential:
   `GET /api/v1/integrations/modules` (below).
2. For each module with a `role_catalog_url`, HR reads the catalog with
   `HR_SERVICE_TOKEN`, five seconds timeout each, and caches it by
   `revision`.
3. `ROLE_CATALOG_SOURCES` (`slug=url,…`), when set, **replaces** the URL Den
   reported for that slug and adds modules Den does not know. A standalone
   HR (not paired) uses only `ROLE_CATALOG_SOURCES`.

Every call is also a NetworkPolicy rule, as today
([Network policies](../operations/network-policies.md#calls-between-modules)).

### `GET /api/v1/integrations/modules` (Den)

**Who may call it:** a paired module, with
`Authorization: Bearer <module credential>`.

**Request body:** none.

**Response:** `200` with the enabled, paired modules of the organisation:

| Field | Meaning |
| --- | --- |
| `modules[].slug`, `modules[].display_name` | As registered in Den. |
| `modules[].base_url` | Public address (for links). |
| `modules[].internal_url` | The address a backend inside the cluster uses, from the module's registration; empty when not set. |
| `modules[].role_catalog_url` | `internal_url` (else `base_url`) plus `/api/role-catalog`; empty when the module publishes none. |

**Errors:** `401` `unauthorized` (missing or revoked credential).

```sh
curl -s https://den-backend.conservices-den.svc.cluster.local:8080/api/v1/integrations/modules \
  -H "Authorization: Bearer $MODULE_CREDENTIAL"
```

```json
{
  "modules": [
    {
      "slug": "desk",
      "display_name": "Desk",
      "base_url": "https://desk.con.example.org",
      "internal_url": "https://desk-backend.conservices-desk.svc.cluster.local:8080",
      "role_catalog_url": "https://desk-backend.conservices-desk.svc.cluster.local:8080/api/role-catalog"
    }
  ]
}
```

## Settings

| Setting | Where | Default | What it does |
| --- | --- | --- | --- |
| `HR_SERVICE_TOKEN` | HR and every module with a catalog | none | **Secret.** The token HR sends; one value per installation, at least 32 characters, allowed only to read catalogs. Without it a module accepts only staff sign-ins on its catalog. See [Secrets](../operations/secrets.md#inventory). |
| `ROLE_CATALOG_SOURCES` | HR | none | Optional override, see above. |

## Troubleshooting

**HR's access picker misses a module**
: The module is not paired with Den, is disabled in Den, or HR cannot reach
  it (NetworkPolicy, `HR_SERVICE_TOKEN` differs). HR's log names the module
  and the status it got.

**HR shows *role no longer offered* for many people after a module upgrade**
: A role's `key` changed. Keys must stay stable; fix the module and
  re-release rather than editing assignments.
