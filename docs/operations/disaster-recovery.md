# Disaster recovery

**Goal:** know what to do when something is lost — one module's data, the
database server, the whole cluster, the backups, or a secret — and rehearse
it before you need it.

The building blocks (what a backup contains, the encryption key, restoring
one database) are on [Databases, backups and restore](databases-and-backups.md).
This page puts them together into procedures for each kind of disaster.

## What you can expect

| | Value | Why |
| --- | --- | --- |
| **Data you can lose** (recovery point) | Up to 24 hours | One scheduled backup a day. Click **Back up now** before risky changes (upgrades, bulk imports, removing a module). |
| **Time to recover** (recovery time) | One to a few hours for a full rebuild | Mostly downloading the backup, restoring databases and copying files. Practise to know your number. |
| **What a backup can bring back** | Every database on the operator's PostgreSQL server, all logins, and the buckets in `FILES_S3_BUCKETS` | See [What is not backed up](databases-and-backups.md#what-is-not-backed-up). |

What you must have **outside** the cluster for any of this to work:

- [ ] the backup bucket, at a different provider or account from the live
      data;
- [ ] the age **secret** key, offline, ideally in two places;
- [ ] your overlay or Helm values in Git;
- [ ] every secret in your secret manager (see [Secrets](secrets.md)).

## Choose the procedure

| What happened | Procedure |
| --- | --- |
| A module's data is wrong (bad import, mass deletion) | [One module's data](#one-modules-data) |
| A module was removed in Den by mistake | [A module was removed](#a-module-was-removed) |
| The PostgreSQL server is gone or corrupted | [The database server](#the-database-server) |
| The whole cluster is gone | [The whole installation](#the-whole-installation) |
| The backup bucket is gone | [The backups](#the-backups) |
| The age secret key is lost | [The encryption key](#the-encryption-key) |
| A secret leaked | [A leaked secret](#a-leaked-secret) |

## One module's data

1. **Stop the damage:** scale the module's backend to zero so nobody makes
   more changes:

    ```sh
    kubectl scale -n conservices-stash deploy/stash-backend --replicas=0
    ```

2. **Pick the backup** from before the problem in Den → **Backups**.
3. **Decide:** replace the whole database, or copy back only what was lost.
    - Whole database: follow [Restore](databases-and-backups.md#restore)
      steps 1 to 7 for that one database.
    - Only some rows: restore into a scratch database (step 5 of the
      restore, *without touching the live database*), compare, and copy
      the rows back with SQL. The rest of the data stays current.
4. Scale the backend back to one replica and check the module.

## A module was removed

If the admin chose **Delete its database too**, the operator took a
**pre-drop backup** first, stored as `pre-drop/<database>/…` in the backup
bucket. Den's audit log names the file.

1. In Den, add the module again (**Modules → New module**) **without**
   *Create a database for it*.
2. Download the pre-drop backup from the bucket and restore it like any
   backup ([Restore](databases-and-backups.md#restore)): `globals.sql` brings
   back the module's login with its old password, then restore the one
   database.
3. The module's `DATABASE_URL` in your secret manager still has that old
   password, so the module connects as before. Restart its backend.
4. Pair the module again (**Modules → Pair**): its old pairing was revoked
   on removal.

The module's bucket was never deleted, so its files are still there.

## The database server

The PostgreSQL server (in-cluster `postgres` or managed) is lost, but the
cluster and the backups are fine.

1. Scale **every** backend that uses the server to zero, plus Keycloak:

    ```sh
    kubectl scale -n conservices-den deploy/den-backend --replicas=0
    kubectl scale -n conservices-identity deploy/keycloak --replicas=0
    kubectl scale -n conservices-stash deploy/stash-backend --replicas=0
    # …every other module
    ```

2. Get a new, empty PostgreSQL 16 server:
    - **Managed:** create it at your provider and update the host in every
      `DATABASE_URL`, `PG_ADMIN_URL` and `MODULE_DB_HOST`.
    - **In-cluster (trial only):** delete the old volume and let the
      StatefulSet create a new one:

        ```sh
        kubectl delete -n conservices-data statefulset/postgres
        kubectl delete -n conservices-data pvc/data-postgres-0
        kubectl apply -k deploy/kubernetes/overlays/<yours>
        ```

3. Make sure `den-operator` runs and can reach the new server (its
   `/tmp` is the work folder for the restore).
4. Follow [Restore](databases-and-backups.md#restore) steps 1, 2, 4 and 5
   for **every** file in `restore/databases/`, including `den` and
   `keycloak`.
5. Scale everything back up (Keycloak first, then Den, then the modules)
   and sign in once.

!!! warning "Restored logins keep their old passwords"
    `globals.sql` sets every login's password to what it was when the backup
    was taken, **including the superuser** (`postgres`). If you changed a
    password since then, the restored value no longer matches your secret
    manager. Fix it right after step 4, as the superuser:

    ```sh
    psql "$PG_ADMIN_URL" -c "ALTER ROLE stash PASSWORD 'value-from-secret-manager'"
    ```

    If the operator itself can no longer log in after `globals.sql`, its
    `PG_ADMIN_URL` password differs from the backup's: connect once with the
    old password and set the current one.

## The whole installation

The cluster is gone (or you move to a new one). The backup bucket, the age
key, Git and the secret manager survived.

1. **Build the cluster foundations**, in this order:
    1. a Kubernetes cluster with a CNI that enforces NetworkPolicy (Cilium
       recommended, see [Network policies](network-policies.md#installing-cilium));
    2. the ingress controller and the load balancer in front of it
       ([Production](production.md#load-balancer-in-front-of-the-ingress-controller));
    3. cert-manager (or your certificate source) and the External Secrets
       Operator with access to your secret manager.
2. **Apply the platform overlay** from Git:

    ```sh
    kubectl apply -k deploy/kubernetes/overlays/<yours>
    ```

    Keycloak, Den and the operator start on empty databases. That is fine;
    the next steps replace them.

3. **Stop everything that writes** to the database, but leave the operator
   running:

    ```sh
    kubectl scale -n conservices-den deploy/den-backend --replicas=0
    kubectl scale -n conservices-identity deploy/keycloak --replicas=0
    ```

4. **Restore every database** as in [The database server](#the-database-server),
   steps 3 to 4, including the password check.
5. **Restore files** for every bucket in the backup's `manifest.json`
   ([Restore, step 6](databases-and-backups.md#6-restore-files)). If the live
   S3 storage survived, skip this.
6. **Start the platform again**: Keycloak, then Den:

    ```sh
    kubectl scale -n conservices-identity deploy/keycloak --replicas=1
    kubectl rollout status -n conservices-identity deploy/keycloak
    kubectl scale -n conservices-den deploy/den-backend --replicas=1
    ```

7. **Deploy each module** with its overlay or Helm values from Git
   ([Helm](helm.md#install-a-module)), skipping *New module* in Den: Den's
   database already knows the modules, and their credentials are in the
   module databases you restored, so **no new pairing is needed**.
8. **Check**: sign in, Den → **Modules** lists every module as paired, each
   module opens, Den → **Backups** shows the restored databases. Click
   **Back up now**.

## The backups

The backup bucket was deleted or the provider is gone. The live data is
fine.

1. Create a new bucket (preferably at another provider), new write-only
   keys, and update `BACKUP_S3_*` on the operator.
2. Restart the operator and click **Back up now**. You have a backup again;
   older history is lost.
3. Protect the new bucket against deletion: turn on **versioning** and, if
   your provider supports it, **object lock** in compliance mode for at
   least the daily retention (7 days). Give the operator keys that can
   write but not delete, if your retention allows it.

!!! note
    With object lock, the operator's pruning cannot delete locked backups
    early; they disappear when the lock ends. Size the bucket for that.

## The encryption key

If every copy of the age secret key is lost, **existing backups cannot be
decrypted by anyone**. Act while the live data still exists:

1. Make a new key pair (`age-keygen -o conservices-backup.key`) and store
   the secret half offline, in two places.
2. Replace `BACKUP_AGE_RECIPIENTS` with the new public key, restart the
   operator, and click **Back up now**.
3. Delete the old, unreadable backups when you no longer need them as
   evidence; they protect nothing.

If the key **leaked** instead of being lost: do the same, then delete old
backups, because whoever has the key and the bucket can read them.

## A leaked secret

Rotate it as described in [Rotating secrets](secrets.md#rotating-secrets),
most dangerous first:

| Leaked | Urgency | First action |
| --- | --- | --- |
| `PG_ADMIN_URL` (superuser) | Immediately | New superuser password, restart the operator; check `pg_stat_activity` for unknown connections. |
| Age secret key | Immediately | [New key](#the-encryption-key), then delete old backups. |
| `KEYCLOAK_CLIENT_SECRET` of `den-keycloak`, `hr-provisioner`, `learn-provisioner` | Immediately | Regenerate in Keycloak; these clients can change realm settings or users. |
| A module's `DATABASE_URL` or S3 keys | Same day | New password or key, restart the module. |
| A module credential | Same day | Remove the module in Den (keep its data), add and pair it again. Den cannot revoke a single credential yet. |
| A pairing URL | Within 15 minutes | Nothing if it was already used by your module; otherwise remove and re-add the module. |

## Rehearse it

A restore you have never done will not work the first time. Every few
months, and before a big event:

1. Download yesterday's backup and decrypt it with the offline key.
2. Restore one module's database into a scratch database and check a few
   records.
3. Once a year, rebuild the whole installation on a throwaway cluster with
   [The whole installation](#the-whole-installation) and time it.
4. Write down what was unclear and fix this page or your runbook.

## Troubleshooting

**`age: error: no identity matched any of the recipients`**
: The file was encrypted for a different key. Check which public keys were
  in `BACKUP_AGE_RECIPIENTS` when the backup was made; you need one of the
  matching secret keys.

**`pg_restore: error: could not execute query: ERROR: database "stash" is being accessed by other users`**
: Something is still connected. Scale the module's backend to zero, and
  check for other sessions:

    ```sh
    psql "$PG_ADMIN_URL" -c "SELECT pid, usename, application_name FROM pg_stat_activity WHERE datname = 'stash'"
    ```

**`role "stash" does not exist` during `pg_restore`**
: Restore `globals.sql` first (step 4 of the restore).

**After a full rebuild, modules show *not paired* or Den shows them twice**
: The module databases and Den's database came from **different** backups,
  or you clicked *New module* again. Restore both from the same backup file,
  or remove the duplicate and pair the module again.

**`No space left on device` in the operator pod during a restore**
: `/tmp` is limited to 5 GiB. Raise the operator's `/tmp` `sizeLimit` in
  your overlay, or restore from your own computer with local `age`,
  `pg_restore` and a port-forward to PostgreSQL.

## Related pages

- [Databases, backups and restore](databases-and-backups.md)
- [Secrets](secrets.md)
- [Production and security](production.md)
- [Logs, health and monitoring](observability.md)
