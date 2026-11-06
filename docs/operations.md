# Operations: databases, backups and restore

This is the guide for whoever runs a Con Services deployment. It covers how
the modules share a PostgreSQL server, how Den creates and removes module
databases, what the automatic backups contain (and what they don't), and how
to restore.

**Read [What is not backed up](#what-is-not-backed-up) and
[The encryption key](#the-encryption-key) before you rely on any of this.**

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

## The pieces

| Component | Role |
| --- | --- |
| PostgreSQL | One server holding a separate database per module, plus Den's and Keycloak's. |
| Den backend | The portal and admin console. It never holds the PostgreSQL admin login. |
| Den operator (`den-operator`) | An internal service, built from `den/backend/cmd/operator`. It is the **only** component with the PostgreSQL admin (superuser) login. It creates and drops module databases when Den asks, and takes the backups. |
| Backup storage | An S3-compatible bucket the operator writes encrypted backups to (dev: MinIO bucket `conservices-backups`). |

The operator has no published port and no user interface. Only the Den
backend calls it, over the internal network, with a shared token
(`OPERATOR_TOKEN`, set on both). Admins use it through Den admin →
**Modules** and **Backups**.

Because the operator holds the superuser login, treat it like the database
itself:

- Never publish its port.
- Use a long random `OPERATOR_TOKEN`.
- On Kubernetes, add a network policy so only the Den backend can reach it.

## One server, separate databases

ADR [0005](../den/docs/adr/0005-no-shared-postgres.md) says modules must not
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
per module (ADR [0004](../den/docs/adr/0004-one-bucket-per-module.md)).

## Managed databases

With `MANAGED_DATABASES=true` (the default), Den can create a database for a
new module and drop it when the module is removed.

Set `MANAGED_DATABASES=false` when the databases are not on the operator's
server, for example when each module has its own managed database at a cloud
provider. Den admin → Backups then says Den-managed databases are turned off,
the module dialogs no longer offer to create or drop anything, and creating and removing
module databases is up to you. Backups keep working for whatever is on the
operator's server.

**Protected databases** are never dropped, whatever anyone clicks:

- `postgres`, `template0` and `template1`;
- everything in `PROTECTED_DATABASES` (default `keycloak,den`).

## Adding and removing modules

**Adding.** In Den admin → Modules → New module, tick **Create a database for
it**. The operator creates the database and its login. Den shows the
connection URL (with the password) **once**: copy it into the module's
`DATABASE_URL`. Den remembers which database belongs to the module.

**Removing.** Remove asks twice:

1. **Choose what happens to the data.**
   - **Delete its database too** (the default when Den manages a database for
     the module):
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

**Where to keep them.** In production, point `BACKUP_S3_*` at a **different
provider or account** from the one holding the live data. A backup that
disappears together with the server it protects is not a backup.

## What is not backed up

The operator backs up exactly one PostgreSQL server and the buckets you list.
It does **not** back up:

- **Modules running standalone or on another database server.** See
  [Standalone modules](#standalone-modules).
- Buckets not listed in `FILES_S3_BUCKETS`. Add new modules' buckets there.
- Configuration and secrets: compose files, `.env` files, Kubernetes secrets,
  `OPERATOR_TOKEN`, the age secret key, Keycloak client secrets kept outside
  the database. Keep those in your secrets manager.
- Keycloak themes and other files mounted into containers (they live in this
  repository).
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
`pg_restore`) and the [MinIO client](https://min.io/docs/minio/linux/reference/minio-mc.html)
`mc` (or any S3 tool) for files. The `den-operator` image has `age` and the
PostgreSQL tools, so in the compose stack you can do everything except the
file step inside it: `docker compose exec den-operator sh`, working in `/tmp`.
Use `docker cp` to move files in and out.

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

```sh
docker compose stop hr-backend        # compose example
```

### 4. Restore the logins

Needed on a new, empty server; harmless on an existing one.

```sh
psql "postgres://postgres:<password>@<host>:5432/postgres" -f restore/globals.sql
```

On an existing server you get `role "…" already exists` errors. That is
expected: the existing logins are kept.

### 5. Restore databases

One command per database you want back:

```sh
pg_restore -d "postgres://postgres:<password>@<host>:5432/postgres" \
  --clean --if-exists --create restore/databases/hr.dump
```

- `--clean --create` **drops the existing database** and recreates it from the
  backup, with the same owner and permissions.
- To restore just one module, run this for its database only.
- For a full disaster recovery, restore every file in `restore/databases/`,
  including `den` and `keycloak`.
- To look at old data **without** touching the live database, restore into a
  scratch database instead:

  ```sh
  createdb -h <host> -U postgres hr_check
  pg_restore -h <host> -U postgres -d hr_check --no-owner restore/databases/hr.dump
  ```

### 6. Restore files

```sh
mc mirror --overwrite restore/files/hr-data-dev/ live/hr-data-dev
```

Here `live` is an `mc` alias for the live S3 service. Skip buckets you are not
restoring.

### 7. Start everything again

```sh
docker compose start hr-backend
```

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
| `PG_ADMIN_URL` | required | Superuser connection to the shared server, e.g. `postgres://postgres:…@postgres:5432/postgres`. |
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
| `FILES_S3_ENDPOINT`, `FILES_S3_ACCESS_KEY_ID`, `FILES_S3_SECRET_ACCESS_KEY`, `FILES_S3_REGION`, `FILES_S3_USE_PATH_STYLE` | | Live file storage to copy from. |
| `FILES_S3_BUCKETS` | none | Comma-separated buckets to include in every backup. |
| `OPERATOR_ADDR` | `:8080` | Listen address. |

Den backend: `OPERATOR_URL` (e.g. `http://den-operator:8080`) and
`OPERATOR_TOKEN`. Without `OPERATOR_URL`, Den runs without the operator: the
Backups page says "Not set up", and modules are added and removed without
touching databases.

The backup hour and retention are changed in Den admin, not through the
environment. They are stored in the backup bucket under `state/`.

## Production checklist

- [ ] Your own age key pair; secret key stored offline, ideally in two places.
- [ ] Backup bucket at a different provider or account than the live data.
- [ ] Long random `OPERATOR_TOKEN`; operator port not published; network
      policy if on Kubernetes.
- [ ] `FILES_S3_BUCKETS` lists every module bucket.
- [ ] Den admin → Backups shows a successful backup the next morning.
- [ ] A test restore into a scratch database has been done once.
- [ ] Standalone modules or modules on other servers have their own backups.
