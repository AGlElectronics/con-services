# Databases, backups and restore

This is the guide for whoever runs a Con Services deployment. It covers how
the modules share a PostgreSQL server, how Den creates and removes module
databases, what the automatic backups contain (and what they don't), and how
to restore.

**Goal:** connect Den to the database server and backup storage, add and
remove module databases safely, get a successful backup every night, and
restore one.

**Read [What is not backed up](#what-is-not-backed-up) and
[The encryption key](#the-encryption-key) before you rely on any of this.**
Procedures for larger failures (lost server, lost cluster, lost key) are on
[Disaster recovery](disaster-recovery.md).

!!! info "What Den's admin console can do today"
    The database server and the S3 storage are **configured in the
    manifests** (`PG_ADMIN_URL`, `DATABASE_URL`, `S3_*`, `BACKUP_S3_*`,
    `FILES_S3_*`), not in Den. Den's **Backups** page *shows* the server, its
    databases and the backup target, and its **Modules** page creates and
    drops module databases. Entering and testing a database or storage
    connection in Den, and creating per-module buckets and keys, are
    planned but not built. See
    [What works today](../getting-started/how-the-platform-starts.md#what-works-today-and-what-is-still-planned).

## Contents

- [The pieces](#the-pieces)
- [One server, separate databases](#one-server-separate-databases)
- [Managed databases](#managed-databases)
- [Adding and removing modules](#adding-and-removing-modules)
- [Backups](#backups)
- [What is not backed up](#what-is-not-backed-up)
- [The encryption key](#the-encryption-key)
- [Restore](#restore)
- [Standalone modules](#standalone-modules)
- [Configuration reference](#configuration-reference)
- [Production checklist](#production-checklist)
- [Troubleshooting](#troubleshooting)

## The pieces

| Component | Role |
| --- | --- |
| PostgreSQL | One server holding a separate database per module, plus Den's and Keycloak's. |
| Den backend | The portal and admin console. It never holds the PostgreSQL admin login. |
| Den operator (`den-operator`) | An internal service, built from `den/backend/cmd/operator`. It is the **only** component with the PostgreSQL admin (superuser) login. It creates and drops module databases when Den asks, and takes the backups. |
| Backup storage | An S3-compatible bucket the operator writes encrypted backups to (local trial and Docker Compose: bucket `conservices-backups` on the bundled SeaweedFS S3 server). |

!!! info "Kubernetes with CloudNativePG"
    In the [GitOps reference deployment](../deploy/data.md) the server is a
    three-instance CloudNativePG cluster (`conservices-pg`), which takes
    its own continuous backups (WAL archiving, daily base backups,
    point-in-time recovery) next to Den's. Den's operator connects to
    `conservices-pg-rw` as the `postgres` superuser and runs with
    `MANAGED_DATABASES=false`. See [Data: Backups](../deploy/data.md#backups).

The operator has no Ingress and no user interface. Only the Den backend
calls it, inside the namespace `conservices-den`, with a shared token
(`OPERATOR_TOKEN`, set on both). People use it through Den admin →
**Modules** and **Backups**. Running, scheduling and downloading backups and
deleting a module's database need Den's **ops** role (Keycloak group
`den-ops`, set with `DEN_OPS_GROUPS`); admins without it see the backup
status and the database list only. Every backup started by hand, schedule
change and download is written to Den's audit log.

Because the operator holds the superuser login, treat it like the database
itself:

- Never expose it through an Ingress or a `LoadBalancer` Service.
- Use a long random `OPERATOR_TOKEN`, from your [secret manager](secrets.md).
- Keep the `den-operator` network policy, which admits only the Den backend
  (see [Network policies](network-policies.md)).

## One server, separate databases

ADR [0005](https://github.com/AGlElectronics/den/blob/main/docs/adr/0005-no-shared-postgres.md) says modules must not
share a database. That still holds: every module has **its own database and
its own login**, and modules talk to each other only through their APIs, never
through SQL.

For small deployments (a convention, a club) those databases can sit on **one
PostgreSQL server**. That is the default setup here, and the operator assumes
it. The separation then comes from the database permissions:

- Each module database is owned by a login of the same name (`hr` owns `hr`).
- `CONNECT` is revoked from everyone else, so the `hr` login cannot even open
  the `stash` database.
- The shared server is a resource boundary, not a data boundary. One module
  running heavy queries slows the others down. If that becomes a problem, move
  that module to its own server (see [Managed databases](#managed-databases)).

The same idea applies to file storage: one S3-compatible service, one bucket
per module (ADR [0004](https://github.com/AGlElectronics/den/blob/main/docs/adr/0004-one-bucket-per-module.md)).

## Managed databases

With `MANAGED_DATABASES=true` (the default), Den can create a database for a
new module and drop it when the module is removed.

Set `MANAGED_DATABASES=false` when the databases are not on the operator's
server, for example when each module has its own managed database at a cloud
provider, or when they are declared somewhere else. The
[GitOps reference deployment](../deploy/data.md#roles-and-databases) does
this: CloudNativePG creates every role and database from Git, so Den must
not create or drop them. Den admin → Backups then says Den-managed databases are turned off,
the module dialogs no longer offer to create or drop anything, and creating and removing
module databases is up to you. Backups keep working for whatever is on the
operator's server.

!!! info "Kubernetes with CloudNativePG (GitOps reference)"
    The [GitOps reference deployment](../deploy/data.md) declares every
    role and database in Git (CloudNativePG `Database` objects) and runs
    Den's operator with `MANAGED_DATABASES=false`. CloudNativePG also takes
    its own continuous backups (point-in-time recovery, 30 days) next to
    Den's daily encrypted backups; see [Data](../deploy/data.md#backups).

**Protected databases** are never dropped, whatever anyone clicks:

- `postgres`, `template0` and `template1`;
- everything in `PROTECTED_DATABASES` (default `keycloak,den`).

Den also only ever drops a database **it created** itself (with *Create a
database for it*): a module whose database existed before, or was created
by someone else, keeps it on removal, even if the database carries the
module's name.

## Adding and removing modules

**Adding.** In Den admin → Modules → New module, tick **Create a database for
it**. The operator creates the database and its login. Den shows the
connection URL (with the password) **once**: copy it into the module's
`DATABASE_URL` secret (see
[How the platform starts](../getting-started/how-the-platform-starts.md#4b-put-the-connection-into-stashs-overlay)). Den remembers which database belongs to the module.

**Removing.** Remove asks twice:

1. **Choose what happens to the data.**
   - **Delete its database too** (offered, and preselected, only when Den
     created the module's database and you have the ops role):
     1. The operator first takes a backup of that database, stored under
        `pre-drop/<database>/` in the backup bucket.
     2. If that backup fails, nothing is deleted.
     3. Then the database is dropped (open connections are cut, so the module
        stops working immediately) and so is its login.
   - **Remove only, keep its data**: the module is disconnected from Den and
     the database is left as it is.
2. **Type the module's slug to confirm.**

Either way the module is disconnected from Den straight away: its pairing is
revoked, it stops receiving branding and settings, and the removal is written
to Den's audit log (including the pre-drop backup's name). Uploaded files in
the module's bucket are never deleted by Den.

Pre-drop backups are **never pruned automatically**. Delete them from the
bucket yourself once you are sure the data is no longer needed.

## Backups

The operator backs up the whole suite **once a day** (default 03:00 in
`BACKUP_TIMEZONE`). If it was down at that time, it catches up when it
starts. **Back up now** in Den admin → Backups starts one immediately.

Each backup is one encrypted file, `backups/<UTC time>-<scheduled|manual>.tar.age`.
Inside the encrypted file is a tar archive:

| Path | Contents |
| --- | --- |
| `manifest.json` | When and why it was taken; the list of databases (with owners) and buckets. |
| `globals.sql` | All logins/roles **with their passwords**, from `pg_dumpall --globals-only`. |
| `databases/<name>.dump` | Every database on the server except `postgres` and the templates: Den, Keycloak (users, groups, realm settings), HR, Stash, Rally and any module added later. `pg_dump` custom format. |
| `files/<bucket>/...` | Every object in the buckets listed in `FILES_S3_BUCKETS` (module uploads, Den's logos). |

The operator dumps the databases to its temporary folder before uploading.
It needs free disk space roughly the size of the databases.

**Status.** Den admin → Backups shows:

- the last run;
- the next run;
- the size of every database;
- the list of backups, each with a download link.

When something is wrong, Den shows a warning banner on every admin page. That
happens when:

- the last backup failed;
- there has never been a backup;
- the last successful backup is more than 26 hours old.

**Retention**, configurable in Den admin → Backups → Schedule:

| Setting | Default | Meaning |
| --- | --- | --- |
| Daily | 7 | Keep the newest scheduled backup of each of the last 7 days. |
| Weekly | 4 | …and of each of the last 4 weeks. |
| Monthly | 6 | …and of each of the last 6 months. |

- The newest backup is always kept.
- Manual backups are kept for as many days as the daily setting, then deleted.
- Pre-drop backups are never deleted automatically.
- Pruning runs after every successful backup.

### Where backups go

In production, point `BACKUP_S3_*` at a **different provider or account**
from the one holding the live data, for example live files in Hetzner
Object Storage and backups in AWS S3, or the other way round. Both are
S3-compatible and the recommended storage for real installations; the
in-cluster S3 server (SeaweedFS) is for local trials only. A backup that
disappears together with the server it protects is not a backup: one
provider outage, a closed account or a leaked key would take the data and
its backups together.

Using the same S3 service still works, and is fine for a trial. It is
flagged so nobody relies on it by accident:

- **Argo CD template:** when `s3.backup.endpoint` in `cluster.yaml` is
  empty or equals `s3.endpoint`, the Application `den` shows
  **Warning: backups** on its page in Argo CD, and `install-root` prints a
  warning. Rendering does not fail. Fix it by setting `s3.backup` to the
  other provider:

    ```yaml
    s3:
      backup:
        endpoint: https://s3.eu-central-1.amazonaws.com
        region: eu-central-1
        fqdns: ["s3.eu-central-1.amazonaws.com"]
    ```

- **Den:** Den's operator gets `BACKUP_SAME_STORAGE_AS_DATA` (`"true"` or
  `"false"`), set by the Argo CD template from the comparison above and by
  you elsewhere (the Compose dev stack sets `"true"`). With `"true"` Den
  shows a warning on its Backups page. The flag only drives the warning;
  backups run the same either way.

## What is not backed up

The operator backs up exactly one PostgreSQL server and the buckets you list.
It does **not** back up:

- **Modules running standalone or on another database server.** See
  [Standalone modules](#standalone-modules).
- Buckets not listed in `FILES_S3_BUCKETS`. Add new modules' buckets there.
- Configuration and secrets: your overlays or Helm values, Kubernetes Secrets,
  `OPERATOR_TOKEN`, the age secret key, Keycloak client secrets kept outside
  the database. Keep those in your secrets manager.
- Keycloak themes and the realm file mounted into Keycloak (they live in this
  repository and your overlay or chart values).
- The backup bucket itself, and the S3 service as a whole.
- Mail, DNS, TLS certificates and anything else outside the suite.

## The encryption key

Backups are encrypted with [age](https://age-encryption.org) before they
leave the operator. The operator only has the **public** key
(`BACKUP_AGE_RECIPIENTS`), so it can write backups but cannot read them, and
neither can anyone who steals the bucket.

> **If you lose the secret key, every backup is unreadable. Nobody can
> recover it, including us.**

Set up a key:

```sh
age-keygen -o conservices-backup.key
# prints: Public key: age1...
```

- Put the `age1…` public key into `BACKUP_AGE_RECIPIENTS`.
- Keep `conservices-backup.key` **offline**: a password manager entry, a USB
  stick in a safe, a printed copy. Never store it next to the backups or on
  the server.
- You can list several public keys, comma-separated. Any one of the matching
  secret keys can decrypt, so two people can each hold one.
- Changing keys only affects new backups. Keep old secret keys for as long as
  backups made with them are retained.

**Dev only:** the key pair in `infra/operator/dev-backup-identity.txt` is
committed to the repository on purpose, so the local stack works out of the
box. Everyone can read it. Never use it anywhere else.

## Restore

There is deliberately no restore button. A restore overwrites live data, so it
is a command-line job. You need `age`, PostgreSQL 16 client tools (`psql`,
`pg_restore`) and an S3 tool for files, for example the
[AWS CLI](https://docs.aws.amazon.com/cli/) (`aws s3 cp`) or
[rclone](https://rclone.org/s3/).

The `den-operator` pod already has `age` and the PostgreSQL tools, and the
network policies let it reach PostgreSQL, so the easiest place to work is
inside it, in its temporary folder `/tmp`:

```sh
kubectl cp conservices-backup.key conservices-den/<den-operator-pod>:/tmp/
kubectl cp 20261104T030000Z-scheduled.tar.age conservices-den/<den-operator-pod>:/tmp/
kubectl exec -it -n conservices-den deploy/den-operator -- sh
cd /tmp
```

Find the pod name with `kubectl get pods -n conservices-den -l app.kubernetes.io/component=operator`.
`/tmp` is limited to 5 GiB and is emptied when the pod restarts; **delete
the secret key from it when you are done** (`rm /tmp/conservices-backup.key`).
Run the file step (6) from your own computer.

### 1. Get the backup file

- Den admin → Backups → **Download**, or
- directly from the bucket:
  `mc cp backups/backups/20261104T030000Z-scheduled.tar.age .`
  (first `mc alias set backups <endpoint> <key> <secret>`).

### 2. Decrypt and unpack

```sh
age -d -i conservices-backup.key -o backup.tar 20261104T030000Z-scheduled.tar.age
mkdir restore && tar -xf backup.tar -C restore
cat restore/manifest.json
```

Check in `manifest.json` that the backup has what you need.

### 3. Stop whatever uses the data

Stop the backends of the modules you are restoring, and Keycloak if you
restore `keycloak`. A database cannot be replaced while something is connected
to it.

Scale them to zero replicas (run this from your computer, not inside the
operator pod):

```sh
kubectl scale -n conservices-stash deploy/stash-backend --replicas=0
kubectl scale -n conservices-identity deploy/keycloak --replicas=0   # only when restoring keycloak
```

To restore `den` itself, scale `den-backend` to zero the same way.

### 4. Restore the logins

Needed on a new, empty server; harmless on an existing one.

Inside the operator pod, the superuser connection is already in the
environment as `PG_ADMIN_URL`:

```sh
psql "$PG_ADMIN_URL" -f restore/globals.sql
```

On an existing server you get `role "…" already exists` errors. That is
expected: the existing logins are kept.

### 5. Restore databases

One command per database you want back:

```sh
pg_restore -d "$PG_ADMIN_URL" --clean --if-exists --create restore/databases/stash.dump
```

- `--clean --create` **drops the existing database** and recreates it from the
  backup, with the same owner and permissions.
- To restore just one module, run this for its database only.
- For a full disaster recovery, restore every file in `restore/databases/`,
  including `den` and `keycloak`.
- To look at old data **without** touching the live database, restore into a
  scratch database instead:

  ```sh
  psql "$PG_ADMIN_URL" -c 'CREATE DATABASE stash_check'
  pg_restore -d "${PG_ADMIN_URL%/postgres*}/stash_check?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt" --no-owner restore/databases/stash.dump
  ```

  The `${PG_ADMIN_URL%/postgres*}` part is the server address without the
  database name. Drop `stash_check` when you are done.

### 6. Restore files

Copy the files out of the operator pod to your computer, then upload them:

```sh
kubectl cp conservices-den/<den-operator-pod>:/tmp/restore/files/stash-data ./stash-data
mc mirror --overwrite ./stash-data/ live/stash-data
```

Here `live` is an `mc` alias for the live S3 service. Skip buckets you are not
restoring.

### 7. Start everything again

```sh
kubectl scale -n conservices-stash deploy/stash-backend --replicas=1
```

Use the replica count from [Running on Kubernetes](running.md#what-runs-where)
(one for every backend).

Check the module works, and log in once through Keycloak if you restored it.

**Pre-drop backups** (from removing a module) are restored the same way. They
contain `globals.sql` and the one database; there are no files.

**Practise this.** A backup you have never restored is a hope, not a backup.
Restoring into a scratch database every few months is enough.

## Standalone modules

HR, Stash and Rally can run without Den, each with its own database. **Then
Den's operator does not back them up. Backing them up is the administrator's
job.** For example:

- run `pg_dump --format=custom` on a schedule;
- copy the module's bucket;
- encrypt both and store them somewhere else.

The same applies to a module that is paired with Den but uses a database
outside the operator's server. Each module's README repeats this.

## Configuration reference

Operator (`den-operator`):

| Variable | Default | Purpose |
| --- | --- | --- |
| `OPERATOR_TOKEN` | required | Shared secret with the Den backend. |
| `PG_ADMIN_URL` | required | Superuser connection to the shared server, e.g. `postgres://postgres:…@postgres.conservices-data.svc.cluster.local:5432/postgres`. |
| `MODULE_DB_HOST` | host of `PG_ADMIN_URL` | `host:port` written into connection URLs handed out for new databases. |
| `MANAGED_DATABASES` | `true` | Let Den create and drop module databases. |
| `PROTECTED_DATABASES` | `keycloak,den` | Databases that can never be dropped (in addition to `postgres` and the templates). |
| `BACKUP_ENABLED` | `true` | Turn backups off entirely. |
| `BACKUP_S3_ENDPOINT` | required for backups | Backup storage, `host:port` or URL. |
| `BACKUP_S3_BUCKET` | required for backups | Created if missing. |
| `BACKUP_S3_ACCESS_KEY_ID`, `BACKUP_S3_SECRET_ACCESS_KEY` | required for backups | Credentials for the backup bucket. |
| `BACKUP_S3_REGION` | `us-east-1` | |
| `BACKUP_S3_USE_PATH_STYLE` | `true` | `false` for providers that need virtual-host style. |
| `BACKUP_AGE_RECIPIENTS` | required for backups | Comma-separated age public keys. |
| `BACKUP_TIMEZONE` | `UTC` | Time zone of the daily backup hour. |
| `BACKUP_SAME_STORAGE_AS_DATA` | `false` | `true` when the backup bucket lives on the same S3 service as the live data; Den then warns on its Backups page ([Where backups go](#where-backups-go)). Set by the Argo CD template. |
| `FILES_S3_ENDPOINT`, `FILES_S3_ACCESS_KEY_ID`, `FILES_S3_SECRET_ACCESS_KEY`, `FILES_S3_REGION`, `FILES_S3_USE_PATH_STYLE` | | Live file storage to copy from. |
| `FILES_S3_BUCKETS` | none | Comma-separated buckets to include in every backup. |
| `OPERATOR_ADDR` | `:8080` | Listen address. |

Den backend: `OPERATOR_URL` (e.g. `https://den-operator.conservices-den.svc.cluster.local:8080`) and
`OPERATOR_TOKEN`. Without `OPERATOR_URL`, Den runs without the operator: the
Backups page says "Not set up", and modules are added and removed without
touching databases.

The backup hour and retention are changed in Den admin, not through the
environment. They are stored in the backup bucket under `state/`.

## Production checklist

- [ ] Your own age key pair; secret key stored offline, ideally in two places.
- [ ] Backup bucket at a different provider or account than the live data.
- [ ] Long random `OPERATOR_TOKEN` from the secret manager; the `den-operator`
      network policy is in place and enforced by your CNI.
- [ ] `FILES_S3_BUCKETS` lists every module bucket.
- [ ] Den admin → Backups shows a successful backup the next morning.
- [ ] A test restore into a scratch database has been done once.
- [ ] Standalone modules or modules on other servers have their own backups.

## Troubleshooting

The operator logs every backup and database change as JSON lines with
`"service":"den-operator"`. Start there:

```sh
kubectl logs -n conservices-den deploy/den-operator --since=24h | grep -i -E 'error|fail'
```

**Backups page: *Not set up***
: Den's backend has no `OPERATOR_URL`. Set it in `den-config` and restart
  `den-backend`.

**Backups page: *Can't reach the operator* or `unauthorized`**
: The operator is down, a NetworkPolicy blocks it, or `OPERATOR_TOKEN`
  differs between `den-secrets` and `den-operator-secrets`. See
  [Troubleshooting](../getting-started/troubleshooting.md#den-shows-cant-reach-the-operator).

**A backup fails with `pg_dump: error: aborting because of server version mismatch`**
: The operator image ships the PostgreSQL 16 client tools (Alpine's
  `postgresql16-client`), so its `pg_dump` cannot dump a newer server. Keep
  the server on PostgreSQL 16 until the operator image supports newer
  versions. Check the version inside the pod:

    ```sh
    kubectl exec -n conservices-den deploy/den-operator -- pg_dump --version
    ```

    It prints `pg_dump (PostgreSQL) 16.x`.

**A backup fails with `AccessDenied` or `SignatureDoesNotMatch`**
: The `BACKUP_S3_*` or `FILES_S3_*` keys are wrong or lack permissions
  (write on the backup bucket, read on every bucket in
  `FILES_S3_BUCKETS`), or the region is wrong. With AWS S3 try
  `BACKUP_S3_USE_PATH_STYLE=false`.

**A backup fails with `dial tcp …:443: i/o timeout`**
: No egress rule to the S3 provider. Add one; see
  [External services](network-policies.md#external-services).

**A backup fails with `no space left on device`**
: The dumps do not fit into the operator's `/tmp` (5 GiB). Raise its
  `sizeLimit` with a patch in your overlay.

**The warning banner stays after a successful backup**
: Reload the page. The banner shows when the newest *successful* backup is
  older than 26 hours; a manual backup counts.

**New module: *Create a database for it* is missing**
: `MANAGED_DATABASES=false` on the operator, or Den has no `OPERATOR_URL`.

**Creating a module database fails with `permission denied to create role`**
: The login in `PG_ADMIN_URL` is not a superuser and lacks `CREATEROLE`
  and `CREATEDB`. Managed providers often need you to grant these
  explicitly.

**Removing a module fails with *backup before removal failed, nothing was deleted***
: This is the safety catch working. Fix the backup problem (above), then
  remove the module again.

**`a backup or database removal is already running`**
: The operator does one backup or removal at a time. Wait for the running
  one to finish (the operator log shows it), then try again.

## Related pages

- [Disaster recovery](disaster-recovery.md): full rebuilds, lost keys, leaked secrets.
- [Secrets](secrets.md): `PG_ADMIN_URL`, `OPERATOR_TOKEN` and S3 keys.
- [Logs, health and monitoring](observability.md#backup-freshness): noticing a missing backup.
- [Den admin guide: Backups](../modules/den/admin-guide.md#backups): the screens.
