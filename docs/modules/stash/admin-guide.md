# Stash admin guide

This page is for the people who look after Stash: who may do what, the
settings, the Den connection, and the tasks that come up before and during
an event. Installing Stash is on [Setup](setup.md).

## Who can do what

Access in Stash is decided by **roles**. A role is a named set of
**permissions** (such as `item.create` or `lostfound.resolve`). People get
roles through **groups** in the identity provider (Keycloak): the access
config file binds each group to a role.

There is no screen in Stash for this. Access is managed **only in the
access config file** (`stash/infra/access-config.toml`, mounted at
`ACCESS_CONFIG_PATH`), and it is read once when the backend starts.

The default roles:

| Role | Group (default) | Can |
| --- | --- | --- |
| `admin` | `stash-admin` | Everything, including settings, the Den connection, exports and the audit log. |
| `inventory_manager` | `stash-logistics-lead` | Items, sign-outs, locations, categories, departments, exports. No Lost & Found. |
| `dept_lead` | `stash-dept-lead` | Sign-outs and returns, report damage and loss. |
| `volunteer` | `stash-volunteer` | Look up items, create and return sign-outs. |
| `readonly` | `stash-readonly` | View inventory, sign-outs and the audit log. |
| `frontdesk` | `stash-conops` | Log and resolve Lost & Found reports. |
| `conops_lead` | `stash-conops-lead` | All of Lost & Found, plus reopen, delete, audit and exports. |
| `conops_readonly` | `stash-conops-readonly` | View Lost & Found only. |

### Give someone access

1. Add the person to the group in Keycloak (or let HR do it when onboarding
   them; HR reads Stash's roles from `GET /api/role-catalog`).
2. They sign in again (or refresh): permissions are recalculated on every
   request from their token, so nothing needs restarting.

### Change what a role may do, or add a binding

1. Edit the access config. A role listed in the file **replaces** its
   built-in permission set. To limit a binding to one department, add its
   id:

    ```toml
    [[bindings]]
    group = "stash-dept-tech"
    role = "dept_lead"
    department_id = "0c5e3e57-8f0a-4d0f-9a43-61f2b1d1c0a2"
    ```

2. Update the ConfigMap and restart the backend:

    ```sh
    kubectl create configmap stash-access-config -n conservices-stash \
      --from-file=access-config.toml=access-config.toml --dry-run=client -o yaml | kubectl apply -f -
    kubectl rollout restart -n conservices-stash deploy/stash-backend
    ```

3. Check: `GET /api/role-catalog` lists the role with its group.

A permission name the backend does not know makes it refuse to start; the
log names it.

## Settings

**Settings** (admins only) holds Stash-wide choices, stored in Stash's
database:

| Setting | What it does |
| --- | --- |
| Organisation name | Used in defaults and exports. **Managed by Den** while paired: read-only here, change it in Den. |
| Default item owner | Filled in when an item is created without an owner. |
| Default currency | ISO 4217 code for purchase prices (EUR when empty). |
| Barcode prefix and width | Format of generated asset tags (default `ST` + 6 digits, `ST000042`). |
| Force barcode on sign-out | Every sign-out line must be scanned. |

The **Den connection** box on the same page shows whether Stash is paired,
when it last synced and the last error. Pairing steps: [Setup, step 9](setup.md#9-pair-stash-with-den).
**Disconnect** returns Stash to standalone: its own organisation name and
default look.

## Before the event

1. Create the **departments** (who borrows things), **locations**
   (buildings, rooms, shelves; locations can be nested) and **categories**.
2. Add items, or import them through the API. Print barcode labels from the
   item page; generated codes follow the barcode settings.
3. Check that each team lead is in the right group and can see what they
   need (sign in as a test user, or call `GET /api/me`).

## During the event

- **Fast sign-out:** Items → search → **Sign out**, pick the department and
  the person's name, confirm. It is signed out immediately.
- **Returns:** open the sign-out and enter how many came back, were used
  up, lost or damaged per line. It stays *partially returned* until every
  line is settled, then becomes *returned*; admins can then **close** it.
- **Lost & Found:** the front desk logs found items with a photo; each gets
  a report number and a printable label. Turn on the guest lookup page only
  when kiosks are ready (`PUBLIC_LOSTFOUND_CLAIM_ENABLED` on the backend and
  `publicClaimEnabled` in the web app's `/config.json`; the Helm chart sets
  the second from the first).

## After the event

- **Exports:** Items and sign-outs as CSV (`export.create`):
  `GET /api/export/items.csv`, `GET /api/export/signouts.csv`.
- **Audit log:** every change with who, when, before and after, filterable
  by action and type (`audit.view`).
- **Backups:** on the platform Den's operator backs up the `stash` database
  and, if listed in `FILES_S3_BUCKETS`, the bucket every night. Standalone,
  backups are your job ([Setup](setup.md#standalone-on-kubernetes)).

## Troubleshooting

**Someone has the wrong permissions.** Call `GET /api/me` with their token:
`permissions` and `memberships` show what Stash computed. Compare their
token's `groups` claim with the `[[bindings]]`; group names must match
exactly (a leading `/` from Keycloak groups is not the same name).

**"organization_name is managed in Den".** Stash is paired; change the name
in Den (**Admin console → Organisation**).

**Den connection shows "Den rejected this module's credential".** The module
was removed or its credential revoked in Den. Create a new pairing URL in
Den and pair again.
