# Data: object storage and PostgreSQL

This guide sets up where Con Services keeps its data:

- **Object storage** for files (uploads, logos, attachments) and backups.
  Con Services talks to it with the **S3 API**, the protocol Amazon S3
  introduced and most storage providers now speak. In production this is a
  **managed S3 service** outside the cluster.
- **PostgreSQL** for everything else, run inside the cluster by
  [CloudNativePG](https://cloudnative-pg.io) (CNPG), an operator that keeps
  three PostgreSQL instances in sync and promotes a new primary when one
  fails.

**You need:** the previous guides done ([Argo CD](argocd.md),
[DNS and certificates](dns-and-certificates.md),
[Secrets with OpenBao](secrets-openbao.md)), so Argo CD, cert-manager,
trust-manager, External Secrets and an unsealed OpenBao are running.

**You are done when:** `kubectl get cluster -n conservices-data` shows
`Cluster in healthy state` with 3 ready instances, the first base backup is
`completed`, and `aws s3 ls` with each key shows its bucket.

Secrets mentioned on this page (S3 keys, database passwords) live in
OpenBao, never in Git. The full list is on [Secrets](../operations/secrets.md).

## Object storage: use a managed S3 service

**Production installations use a managed S3 service.** Any S3-compatible
service works: Hetzner Object Storage, AWS S3, Cloudflare R2, Backblaze B2,
Wasabi, Scaleway, OVHcloud and others. You give the template the endpoint,
region and a bucket name prefix in `cluster.yaml` (`s3.*`); this page uses
[Hetzner Object Storage](https://www.hetzner.com/storage/object-storage/)
as the worked example.

Why not run object storage inside the cluster:

- **Backups must survive the cluster.** Storage inside the cluster dies with
  it: a lost cluster would take the files *and* the backups meant to restore
  them.
- **The provider runs replication, durability and capacity**, so there is no
  storage software to upgrade, rebalance or repair at 3 a.m.
- The cluster only needs outbound HTTPS to the provider.

The template installs no object storage in the cluster.

### Providers

All of these work. Only the endpoint, region and addressing style change.

| Provider | Endpoint (`s3.endpoint`) | Region (`s3.region`) | Addressing | Notes |
| --- | --- | --- | --- | --- |
| [Hetzner Object Storage](https://docs.hetzner.com/storage/object-storage/) | `https://<location>.your-objectstorage.com`, location `fsn1`, `nbg1` or `hel1` | the location, e.g. `fsn1` | path or virtual-host | Keys belong to a **project** and reach every bucket in it; use separate projects or bucket policies (see the worked example). Bucket names are unique across all Hetzner customers. |
| [AWS S3](https://docs.aws.amazon.com/AmazonS3/latest/userguide/) | `https://s3.<region>.amazonaws.com` | e.g. `eu-central-1` | virtual-host (set `s3.pathStyle: false`) | One IAM user per key with a policy limited to its bucket. Object Lock and lifecycle rules available. |
| [Cloudflare R2](https://developers.cloudflare.com/r2/) | `https://<account-id>.r2.cloudflarestorage.com` (EU jurisdiction: `<account-id>.eu.r2.cloudflarestorage.com`) | `auto` | path or virtual-host | API tokens can be limited to single buckets. No egress fees. |
| [Backblaze B2](https://www.backblaze.com/docs/cloud-storage-s3-compatible-api) | `https://s3.<region>.backblazeb2.com` | e.g. `eu-central-003` | path or virtual-host | Application keys can be limited to one bucket. Object Lock available. |
| [Wasabi](https://docs.wasabi.com/) | `https://s3.<region>.wasabisys.com` | e.g. `eu-central-1` | path or virtual-host | Objects are billed for at least 90 days, including deleted WAL files. |
| [Scaleway](https://www.scaleway.com/en/docs/object-storage/) | `https://s3.<region>.scw.cloud` | `fr-par`, `nl-ams` or `pl-waw` | path or virtual-host | Keys are per project; use IAM policies to limit them. |
| [OVHcloud](https://help.ovhcloud.com/csm/en-public-cloud-storage-s3-getting-started) | `https://s3.<region>.io.cloud.ovh.net` | e.g. `gra`, `de` | path or virtual-host | Users per project with per-bucket policies. |

**Path style** puts the bucket in the path
(`https://fsn1.your-objectstorage.com/<prefix>-conservices-stash/...`);
**virtual-host style** puts it in the host name
(`https://<prefix>-conservices-stash.fsn1.your-objectstorage.com/...`). The
template uses path style (`s3.pathStyle: true`). Switch to `false` only for
providers that require virtual-host style, such as new AWS buckets, and
then add `*.<endpoint host>` to `s3.fqdns`.

All of these providers use certificates from public certificate
authorities. The applications keep trusting those while also trusting the
cluster's internal CA; see
[Public certificates stay trusted](../operations/internal-tls.md#public-certificates-stay-trusted).
Never set `SSL_CERT_FILE` on a workload: it would replace the public CAs.

### Buckets and keys

Use **one bucket per module** and **one key per bucket**, plus separate
backup buckets with their own keys. Then a leaked module key exposes one
module's files and can never delete backups.

| Bucket | Used by | Key in OpenBao (`access_key`, `secret_key`) | Access |
| --- | --- | --- | --- |
| `<prefix>-conservices-den` | Den (logos, branding) | `kv/conservices/den/s3` | read and write |
| `<prefix>-conservices-stash` | Stash | `kv/conservices/stash/s3` | read and write |
| `<prefix>-conservices-rally` | Rally | `kv/conservices/rally/s3` | read and write |
| `<prefix>-conservices-learn` | Learn | `kv/conservices/learn/s3` | read and write |
| `<prefix>-conservices-wiki` | Wiki | `kv/conservices/wiki/s3` | read and write |
| `<prefix>-conservices-tasks` | Tasks | `kv/conservices/tasks/s3` | read and write |
| all six module buckets | Den's operator, copying files into its backups | `kv/conservices/den/files-s3` | **read only** |
| `<prefix>-pg-backups` | CloudNativePG (WAL archive, base backups) | `kv/conservices/postgres/backup-s3` | read and write |
| `<prefix>-den-backups` | Den's operator (encrypted daily backups) | `kv/conservices/den/backup-s3` | read and write |

`<prefix>` is `s3.bucketPrefix` from `cluster.yaml`. HR, Finance and Desk
store no files and get no bucket; create buckets only for the modules you
enable (Den's three are always needed).

**Put the backup buckets in another region, or at another provider**, from
the module buckets. A bucket lives in exactly one location; if that
location has an outage or loses data, a backup stored next to the data is
lost with it. The worked example below keeps data in Hetzner `fsn1`
(Falkenstein) and backups in `hel1` (Helsinki).

### Worked example: Hetzner Object Storage

Replace `<prefix>` with your `s3.bucketPrefix` (a short name for your
installation, for example `acme`) and `example.org` with your domain.
Hetzner bucket names are unique across all customers, so if a name is
taken, pick another prefix and use it in `cluster.yaml` (step 7).

At Hetzner, an S3 key (Hetzner calls them *S3 credentials*) belongs to a
**project** and can reach every bucket of that project. To keep the backup
keys apart from the application keys, use **two projects**:

| Project | Location | Buckets | Credentials |
| --- | --- | --- | --- |
| `conservices-<prefix>` | `fsn1` | `<prefix>-conservices-den`, `-stash`, `-rally`, `-learn`, `-wiki`, `-tasks` | `den`, `stash`, `rally`, `learn`, `wiki`, `tasks`, `den-files` |
| `conservices-<prefix>-backups` | `hel1` | `<prefix>-pg-backups`, `<prefix>-den-backups` | `pg-backups`, `den-backups` |

1. **Create the two projects.** In the
   [Hetzner Console](https://console.hetzner.com), choose **+ New project**
   and create `conservices-<prefix>`, then `conservices-<prefix>-backups`.

2. **Create the module buckets.** Open the project `conservices-<prefix>`,
   go to **Object Storage** and choose **Create Bucket** six times:

    - Location: **Falkenstein (fsn1)**
    - Name: `<prefix>-conservices-den` (then `-stash`, `-rally`, `-learn`,
      `-wiki`, `-tasks`)
    - Visibility: **Private**

    You should see the six buckets listed with location `fsn1`.

3. **Create the backup buckets.** In `conservices-<prefix>-backups`, create
   `<prefix>-pg-backups` and `<prefix>-den-backups` in **Helsinki (hel1)**,
   visibility **Private**. Turn on **Object Lock** in the creation dialog if
   you want backups that cannot be deleted before their retention ends (it
   can only be turned on when the bucket is created); see
   [Protect the backup buckets](#protect-the-backup-buckets).

4. **Create the credentials.** In each project, go to
   **Security → S3 credentials → Generate credentials**, one per row of the
   table above, with the name as description (`stash`, `pg-backups`, ...).
   Hetzner shows the **secret key only once**: keep the window open until
   step 8 has stored it, or put it in your password manager.

5. **Restrict each module key to its bucket (recommended).** Within one
   project every key reaches every bucket, so the Stash key could read
   Wiki's files. A **bucket policy** limits a bucket to the keys you name.
   Hetzner identifies a key as `arn:aws:iam:::user/p<project-id>:<access-key>`;
   the project ID is shown in the project's settings. For Stash's bucket,
   allow the Stash key everything and the `den-files` key reading:

    ```json title="policy-stash.json"
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Principal": { "AWS": ["arn:aws:iam:::user/p<project-id>:<stash-access-key>"] },
          "Action": ["s3:*"],
          "Resource": ["arn:aws:s3:::<prefix>-conservices-stash", "arn:aws:s3:::<prefix>-conservices-stash/*"]
        },
        {
          "Effect": "Allow",
          "Principal": { "AWS": ["arn:aws:iam:::user/p<project-id>:<den-files-access-key>"] },
          "Action": ["s3:GetObject", "s3:ListBucket"],
          "Resource": ["arn:aws:s3:::<prefix>-conservices-stash", "arn:aws:s3:::<prefix>-conservices-stash/*"]
        }
      ]
    }
    ```

    Apply it with the Stash key (the AWS CLI is introduced in step 9):

    ```sh
    aws s3api put-bucket-policy --bucket <prefix>-conservices-stash \
      --policy file://policy-stash.json \
      --endpoint-url https://fsn1.your-objectstorage.com --region fsn1
    ```

    Repeat for the other module buckets. Check that it works: listing
    `<prefix>-conservices-stash` with the **Wiki** key must now fail with
    `AccessDenied`. The Hetzner Console no longer shows the contents of a
    bucket with such a policy; that is expected. Hetzner does not support
    `NotAction` in policies, so write `Allow` statements as above.

6. **Allow browsers to fetch files (CORS).** Browsers download (and, in
   some modules, upload) files straight from the bucket with signed links.
   A CORS rule lets the module's web address do that:

    ```json title="cors-stash.json"
    {
      "CORSRules": [
        {
          "AllowedOrigins": ["https://stash.example.org"],
          "AllowedMethods": ["GET", "HEAD", "PUT"],
          "AllowedHeaders": ["*"],
          "ExposeHeaders": ["ETag"],
          "MaxAgeSeconds": 3600
        }
      ]
    }
    ```

    ```sh
    aws s3api put-bucket-cors --bucket <prefix>-conservices-stash \
      --cors-configuration file://cors-stash.json \
      --endpoint-url https://fsn1.your-objectstorage.com --region fsn1
    ```

    Use each module's own address (`https://events.example.org` for Rally,
    `https://den.example.org` for Den, ...).

7. **Set the S3 values in `cluster.yaml`.** The template computes every
   app's endpoint, region, bucket names and network policy from them:

    ```yaml
    s3:
      endpoint: https://fsn1.your-objectstorage.com
      region: fsn1
      pathStyle: true
      bucketPrefix: acme
      fqdns: ["fsn1.your-objectstorage.com"]
      backup:
        endpoint: https://hel1.your-objectstorage.com
        region: hel1
        fqdns: ["hel1.your-objectstorage.com"]
    ```

    Check that it renders:

    ```sh
    helm template root charts/root -f cluster.yaml > /dev/null && echo OK
    ```

    ```text
    OK
    ```

8. **Store the keys in OpenBao.** Run the seed script; it asks for each
   missing key (only for the modules you enabled) and never prints the
   secret:

    ```sh
    BAO_TOKEN=<token> bash bootstrap/scripts/openbao-seed.sh
    ```

    You should see, for every S3 key:

    ```text
    ==> kv/conservices/stash/s3: S3 access key from your object storage provider
      Access key (empty = skip): 9LP3XRBS0K7T2EXAMPLE
      Secret key:
    ==> kv/conservices/stash/s3 written
    ```

    The S3 paths are listed in [Buckets and keys](#buckets-and-keys).
    Entries that already exist are kept. How to get a token is in
    [Secrets with OpenBao](secrets-openbao.md).

9. **Verify every key.** Install the [AWS CLI](https://aws.amazon.com/cli/)
   and list the bucket with each key. Read the secret from your password
   manager into the environment (`read -s` keeps it off the screen and out
   of your shell history):

    ```sh
    export AWS_ACCESS_KEY_ID=<stash access key>
    read -rs AWS_SECRET_ACCESS_KEY && export AWS_SECRET_ACCESS_KEY
    aws s3 ls s3://<prefix>-conservices-stash \
      --endpoint-url https://fsn1.your-objectstorage.com --region fsn1
    echo "ok: $?"
    ```

    An empty bucket prints nothing and then `ok: 0`. Upload and delete a
    test file to check writing:

    ```sh
    echo test | aws s3 cp - s3://<prefix>-conservices-stash/healthcheck.txt \
      --endpoint-url https://fsn1.your-objectstorage.com --region fsn1
    aws s3 rm s3://<prefix>-conservices-stash/healthcheck.txt \
      --endpoint-url https://fsn1.your-objectstorage.com --region fsn1
    ```

    You should see `upload: - to s3://<prefix>-conservices-stash/healthcheck.txt`
    and `delete: s3://<prefix>-conservices-stash/healthcheck.txt`. Do the same
    for the backup keys with `--endpoint-url https://hel1.your-objectstorage.com --region hel1`.

### Using another provider

Everything provider-specific is the `s3` block of `cluster.yaml`. For
example, AWS S3 in `eu-central-1` with backups in `eu-west-1`:

```yaml
s3:
  endpoint: https://s3.eu-central-1.amazonaws.com
  region: eu-central-1
  pathStyle: false
  bucketPrefix: acme
  fqdns: ["s3.eu-central-1.amazonaws.com", "*.s3.eu-central-1.amazonaws.com"]
  backup:
    endpoint: https://s3.eu-west-1.amazonaws.com
    region: eu-west-1
    fqdns: ["s3.eu-west-1.amazonaws.com", "*.s3.eu-west-1.amazonaws.com"]
```

Then create the buckets and keys at the new provider and store the keys in
OpenBao (step 8 above).

### Network policy for S3

The namespaces of Con Services deny all traffic that is not explicitly
allowed (see [Network policies](../operations/network-policies.md)). Calls
to the S3 provider are allowed **by host name**, with Cilium's `toFQDNs`
rules: Cilium watches the DNS answers (the rule sends lookups through its
DNS proxy) and opens port 443 to exactly the addresses those names resolve
to. A provider changing its IP addresses needs no edit.

You list the host names once, in `cluster.yaml`, and the root chart passes
them on:

- **Den and the modules with files** get `s3.fqdns` (Den also
  `s3.backup.fqdns`, for its backups). Each chart renders a
  `CiliumNetworkPolicy` named `<module>-external-s3` for the backend (and
  Den's operator).
- **PostgreSQL** gets `s3.fqdns` plus `s3.backup.fqdns` in a
  `CiliumNetworkPolicy` for all pods labelled `conservices.io/postgres: "true"`.

For Hetzner Object Storage with virtual-host style:

```yaml
s3:
  fqdns:
    - "fsn1.your-objectstorage.com"
    - "*.fsn1.your-objectstorage.com"   # <bucket>.fsn1.your-objectstorage.com
```

A name containing `*` becomes a Cilium `matchPattern`. A `*` matches within
one label only (it does not cross a dot), which is why virtual-host style
needs the second entry.
Check that a backend can reach the provider:

```sh
kubectl -n conservices-stash debug -it deploy/stash-backend \
  --image=curlimages/curl:8.11.1 --target=backend -- \
  curl -sI https://fsn1.your-objectstorage.com
```

You should see an HTTP status line (often `HTTP/1.1 403 Forbidden` without
credentials). A timeout means the policy does not match.

### Protect the backup buckets

A backup that an attacker or a mistake can delete is not a backup. On both
backup buckets:

1. **Turn on versioning.** A deleted or overwritten object stays available
   as an older version:

    ```sh
    aws s3api put-bucket-versioning --bucket <prefix>-pg-backups \
      --versioning-configuration Status=Enabled \
      --endpoint-url https://hel1.your-objectstorage.com --region hel1
    ```

    `aws s3api get-bucket-versioning ...` should then print
    `"Status": "Enabled"`.

2. **Optionally use Object Lock** (turned on when the bucket is created,
   step 3 above) with a default retention of, for example, 30 days in
   *governance* or *compliance* mode. Locked versions cannot be deleted
   before the retention ends, not even with the bucket's key. CloudNativePG
   and Den keep working: their deletions only add a *delete marker*.

3. **Add a lifecycle rule** so old versions do not pile up forever. Do
   not expire *current* objects: CloudNativePG (30-day retention) and Den
   (daily, weekly, monthly retention) delete their old backups themselves.

    ```json title="lifecycle-backups.json"
    {
      "Rules": [
        {
          "ID": "expire-old-versions",
          "Status": "Enabled",
          "Filter": { "Prefix": "" },
          "NoncurrentVersionExpiration": { "NoncurrentDays": 30 },
          "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 }
        }
      ]
    }
    ```

    ```sh
    aws s3api put-bucket-lifecycle-configuration --bucket <prefix>-pg-backups \
      --lifecycle-configuration file://lifecycle-backups.json \
      --endpoint-url https://hel1.your-objectstorage.com --region hel1
    ```

Repeat for `<prefix>-den-backups`. Check your provider's documentation for
which of these features it supports; all providers in the
[table above](#providers) support versioning.

## PostgreSQL with CloudNativePG

### What runs

| Piece | Where | Argo CD Application (sync wave) |
| --- | --- | --- |
| Namespaces `cnpg-system`, `conservices-data`, `conservices-identity` with default-deny policies | `components/platform-namespaces` | `platform-namespaces` (0) |
| CloudNativePG operator 1.30.1 (chart `cloudnative-pg` 0.29.1), 2 replicas | `cnpg-system` | `cnpg-operator` (1) |
| Barman Cloud plugin v0.15.1 (chart `plugin-barman-cloud` 0.8.1): backups to S3 | `cnpg-system` | `cnpg-barman-cloud` (2) |
| PostgreSQL cluster `conservices-pg`, roles, databases, backups (chart `charts/postgres`) | `conservices-data` | `postgres` (3) |

Argo CD syncs the waves in order and waits until each is healthy before
starting the next. Keycloak (wave 4), Den (5) and the modules (10) follow.
The `platform-namespaces` and `postgres` Applications have no finalizer:
deleting them in Argo CD leaves the namespaces and the database running.

The cluster `conservices-pg` (`charts/postgres/templates/cluster.yaml`),
with the defaults of the `postgres` block in `cluster.yaml`:

- **3 instances** (`postgres.instances`) of PostgreSQL 16.15 on 3 different
  nodes (required anti-affinity), each with a 20 GiB data volume
  (`postgres.storage.size`) and a 10 GiB WAL volume
  (`postgres.storage.walSize`) on `postgres.storage.className`. When that
  is empty, the volumes use `longhorn-single` if
  `storage.longhornSingle.enabled` is `true`, otherwise `storage.className`
  (empty: the default StorageClass). PostgreSQL replicates itself, so a
  class that keeps one copy per volume, such as `longhorn-single`, is
  enough.
- **Quorum synchronous replication:** a commit returns only when the
  primary **and at least one standby** have it. Losing any one node loses
  no committed data. If both standbys are gone, writes wait instead of
  continuing without a copy.
- **Automatic failover:** when the primary fails, CNPG promotes a standby
  that is known to hold every committed transaction, usually within 10 to
  30 seconds. Applications reconnect through the Service
  `conservices-pg-rw`, which always points at the current primary.
- **TLS only:** the server certificate comes from the internal CA
  (cert-manager), and the `pg_hba` rules reject every connection without
  TLS. Each login may connect only to the database of the same name
  (`sameuser`); only `postgres`, the superuser Den's operator uses, reaches
  all of them.
- **PostgreSQL 16** on purpose: Den's operator runs `pg_dump` 16, which
  refuses to dump a newer server. Upgrade both together.

### Bring it up

1. **Check the secrets exist.** The database passwords are generated by the
   seed script (run as part of [Secrets with OpenBao](secrets-openbao.md)),
   and the backup key was stored in step 8 of the worked example. Check:

    ```sh
    BAO_TOKEN=<token> bash bootstrap/scripts/openbao-seed.sh --no-prompt
    ```

    You should see `already exists, keeping it` for every entry and no
    `Still missing` list. A missing `kv/conservices/postgres/backup-s3`
    keeps the `postgres` Application `Degraded`.

2. **Sync.** The root Application picks up the platform Applications by
   itself. Watch them:

    ```sh
    kubectl get applications -n argocd | grep -E "platform|cnpg|postgres"
    ```

    After a few minutes every line shows `Synced   Healthy`.

3. **Check the cluster:**

    ```sh
    kubectl get cluster -n conservices-data
    ```

    ```text
    NAME             AGE   INSTANCES   READY   STATUS                     PRIMARY
    conservices-pg   6m    3           3       Cluster in healthy state   conservices-pg-1
    ```

4. **Install the `cnpg` kubectl plugin** (on your computer) for status,
   switchovers and on-demand backups. With [krew](https://krew.sigs.k8s.io):

    ```sh
    kubectl krew install cnpg
    kubectl cnpg version
    ```

    or with the project's install script, pinned to the operator's version:

    ```sh
    curl -sSfL https://github.com/cloudnative-pg/cloudnative-pg/raw/v1.30.1/hack/install-cnpg-plugin.sh \
      | sudo sh -s -- -b /usr/local/bin v1.30.1
    ```

5. **Look at the details:**

    ```sh
    kubectl cnpg status conservices-pg -n conservices-data
    ```

    ```text
    Cluster Summary
    Name                 conservices-data/conservices-pg
    PostgreSQL Image:    ghcr.io/cloudnative-pg/postgresql:16.15-standard-trixie
    Primary instance:    conservices-pg-1
    Status:              Cluster in healthy state
    Instances:           3
    Ready instances:     3
    ...
    Instances status
    Name              Current LSN  Replication role  Status  QoS        Manager Version  Node
    conservices-pg-1  0/6000060    Primary           OK      Burstable  1.30.1           node-1
    conservices-pg-2  0/6000060    Standby (sync)    OK      Burstable  1.30.1           node-2
    conservices-pg-3  0/6000060    Standby (sync)    OK      Burstable  1.30.1           node-3
    ```

### How applications connect

Every application has its own login and database, and connects to the
primary with full certificate checking:

```text
postgres://stash:<password>@conservices-pg-rw.conservices-data.svc.cluster.local:5432/stash?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt
```

The `DATABASE_URL` is assembled by an ExternalSecret
(`charts/module-extras/templates/<module>.yaml`) from the same OpenBao entry CNPG uses to
set the password, so both always agree. `/etc/conservices-internal-ca/ca.crt`
is the internal CA, which the charts mount into every pod. Keycloak uses
the same server through JDBC with `sslmode=verify-full`.

| Service | Points at | Use |
| --- | --- | --- |
| `conservices-pg-rw` | the primary | everything (reads and writes) |
| `conservices-pg-ro` | standbys only | read-only reporting, if you add any |
| `conservices-pg-r` | any instance | not used |

### Roles and databases

Roles (logins) and databases are declared in Git, not created by hand. The
root chart creates one of each for Den, Keycloak and every module enabled
in `cluster.yaml`:

| Role and database | Used by |
| --- | --- |
| `den` | Den |
| `keycloak` | Keycloak |
| `stash`, `hr`, `finance`, `learn`, `wiki`, `desk`, `tasks` | the module of that name |
| `events` | Rally |

- Roles: `spec.managed.roles` in `charts/postgres/templates/cluster.yaml`,
  each with a password Secret from `kv/conservices/postgres/roles/<role>`.
- Databases: `Database` objects in `charts/postgres/templates/databases.yaml`,
  with `databaseReclaimPolicy: retain`, so deleting the object (for example
  by disabling a module) never drops the data.

Because the databases are in Git, **Den does not create or drop
databases** in this setup: its operator runs with `MANAGED_DATABASES=false`
(set by the root chart), and the *Create a database for it* option
in Den admin is hidden. Den's operator still backs up every database. See
[Managed databases](../operations/databases-and-backups.md#managed-databases).

### Add a database for a new module

The role, database, password Secret and network policy come from the
module list of the root chart. For a module `shop` (role and database
`shop`), as part of adding the module (see
[Applications](apps.md#add-a-new-module)):

1. Add `shop` to `root.moduleNames` and a line to `root.moduleMeta` in
   `charts/root/templates/_helpers.tpl`:

    ```yaml
    shop:    { host: shop,    role: shop,    label: shop,    s3: false, migrate: true,  access: false }
    ```

2. Add `shop` to `modules` in `cluster.yaml` (and in
   `charts/root/values.yaml` and `values.schema.json`) with `enabled: true`.
3. Generate the password in OpenBao. The seed script reads the module list
   from the chart, so it creates `kv/conservices/postgres/roles/shop`
   without the password ever showing on screen:

    ```sh
    BAO_TOKEN=<token> bash bootstrap/scripts/openbao-seed.sh --no-prompt
    ```

4. Commit and push. After the sync, check:

    ```sh
    kubectl get database -n conservices-data conservices-pg-shop
    ```

    ```text
    NAME                  AGE   CLUSTER          PG NAME   APPLIED   MESSAGE
    conservices-pg-shop   1m    conservices-pg   shop      true
    ```

The module's namespace gets the label `conservices.io/tier: module` from
its Application, which the PostgreSQL network policy admits.

## Backups

Two independent kinds of backup run every day. Keep both.

| | CloudNativePG (Barman Cloud plugin) | Den's operator |
| --- | --- | --- |
| What | physical: base backup plus every WAL file | logical: `pg_dump` of every database, all roles, and the module buckets |
| When | WAL continuously, base backup daily 02:15 UTC (`postgres.backup.schedule`; and once right after the first start) | daily (time set in Den admin → Backups) |
| Restore to | any second of the last 30 days (point-in-time recovery) | a whole backup, or single databases and buckets |
| Encrypted | by the provider at rest; TLS in transit | yes, with your [age](https://age-encryption.org) key before upload |
| Bucket and key | `<prefix>-pg-backups`, `kv/conservices/postgres/backup-s3` | `<prefix>-den-backups`, `kv/conservices/den/backup-s3` |
| Retention | 30 days (`postgres.backup.retention`) | daily 7, weekly 4, monthly 6 (Den admin) |

Den's backups need your age public key in `den.backupAgeRecipients` in
`cluster.yaml` (it becomes `BACKUP_AGE_RECIPIENTS`); until then they fail. How to create the
key and where to keep it: [The encryption key](../operations/databases-and-backups.md#the-encryption-key).

### Check the backups

```sh
kubectl get backups -n conservices-data
```

```text
NAME                                  AGE   CLUSTER          METHOD   PHASE       ERROR
conservices-pg-daily-20261107021500   9h    conservices-pg   plugin   completed
```

Check that WAL archiving works (it should print `True`):

```sh
kubectl get cluster conservices-pg -n conservices-data \
  -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}'
```

Take a base backup now, for example before an upgrade:

```sh
kubectl cnpg backup conservices-pg -n conservices-data \
  --method plugin --plugin-name barman-cloud.cloudnative-pg.io
```

Den's backups are listed in Den admin → Backups.

### Restore

Restore never overwrites the running cluster. You create a **new**
cluster from the backups, check it, and then decide what to copy back.

1. Pick the moment to go back to, in UTC, for example just before a bad
   migration ran at 09:31: `2026-11-07 09:30:00+00`.
2. Create the restore cluster. Save this as `restore.yaml` (it reads the
   same backups; it does not archive anything itself):

    ```yaml title="restore.yaml"
    apiVersion: postgresql.cnpg.io/v1
    kind: Cluster
    metadata:
      name: conservices-pg-restore
      namespace: conservices-data
    spec:
      instances: 1
      imageName: ghcr.io/cloudnative-pg/postgresql:16.15-standard-trixie
      # Same label as the live cluster, so the network policies let it
      # reach the backup bucket and the Kubernetes API.
      inheritedMetadata:
        labels:
          conservices.io/postgres: "true"
      # Same class and sizes as postgres.storage in cluster.yaml; leave
      # storageClass out to use the default StorageClass.
      storage:
        storageClass: longhorn-single
        size: 20Gi
      walStorage:
        storageClass: longhorn-single
        size: 10Gi
      bootstrap:
        recovery:
          source: origin
          recoveryTarget:
            targetTime: "2026-11-07 09:30:00+00"
      externalClusters:
        - name: origin
          plugin:
            name: barman-cloud.cloudnative-pg.io
            parameters:
              barmanObjectName: conservices-pg-backups
              serverName: conservices-pg
    ```

    ```sh
    kubectl apply -f restore.yaml
    kubectl get cluster -n conservices-data conservices-pg-restore -w
    ```

    After a few minutes (longer for big databases) it shows
    `Cluster in healthy state`.

3. Look at the data:

    ```sh
    kubectl cnpg psql conservices-pg-restore -n conservices-data -- -d stash
    ```

4. Copy back what you need. For one module's database, stop the module,
   then dump from the restore cluster and load into the live one:

    ```sh
    kubectl scale deploy/stash-backend -n conservices-stash --replicas=0
    kubectl exec -n conservices-data conservices-pg-restore-1 -c postgres -- \
      pg_dump -Fc -d stash > stash.dump
    kubectl exec -i -n conservices-data conservices-pg-1 -c postgres -- \
      pg_restore --clean --if-exists --no-owner --role=stash -d stash < stash.dump
    kubectl scale deploy/stash-backend -n conservices-stash --replicas=1
    ```

    Use the current primary instead of `conservices-pg-1` (see
    `kubectl get cluster`).
5. Delete the restore cluster when done:

    ```sh
    kubectl delete cluster -n conservices-data conservices-pg-restore
    ```

To replace the **whole** server (for example after losing the cluster),
recover `conservices-pg` itself with the same `bootstrap.recovery` section
and give its own backups a new `serverName` (for example
`conservices-pg-r1` in the `plugins` parameters), because Barman refuses
to archive into a folder that already holds another server's WAL. The
full procedure, including Den's backups, is in
[Disaster recovery](../operations/disaster-recovery.md).

## Troubleshooting

**The `postgres` Application stays `Progressing` or `Degraded` with
`SecretSyncedError`**
: An OpenBao entry is missing, usually `kv/conservices/postgres/backup-s3`.
  Run `kubectl get externalsecret -n conservices-data` and look for
  `SecretSyncedError`, then
  `kubectl describe externalsecret -n conservices-data <name>`. Store the
  missing entry (step 8 of the worked example) and wait up to a minute.

**An instance stays `Pending`**
: Instances require different nodes. With fewer than 3 schedulable nodes
  the third cannot be placed; `kubectl describe pod` says
  `didn't match pod anti-affinity rules`. Add a node or make a
  control-plane node schedulable.

**`ContinuousArchiving` is `False`, or a backup fails with `AccessDenied`,
`InvalidAccessKeyId` or `SignatureDoesNotMatch`**
: The backup key, bucket or region is wrong. Compare
  `kv/conservices/postgres/backup-s3` with the provider, and
  `s3.backup.endpoint`, `s3.backup.region` and `s3.bucketPrefix` in
  `cluster.yaml` (the bucket is `<prefix>-pg-backups`). The plugin's log is
  in the `plugin-barman-cloud` container of the instance pods:
  `kubectl logs -n conservices-data conservices-pg-1 -c plugin-barman-cloud`.

**WAL archiving fails with `InvalidArgument`, `MissingContentLength` or
`XAmzContentSHA256Mismatch`**
: The S3 service does not accept the newer integrity checksums of the
  AWS libraries. `charts/postgres/templates/backups.yaml` already sets
  `AWS_REQUEST_CHECKSUM_CALCULATION=when_required`; if you removed it, put
  it back. The same applies to the AWS CLI on your computer: export both
  `AWS_REQUEST_CHECKSUM_CALCULATION=when_required` and
  `AWS_RESPONSE_CHECKSUM_VALIDATION=when_required`.

**WAL archiving or uploads time out (`i/o timeout`, `context deadline exceeded`)**
: The network policy does not allow the provider's host name. Compare the
  endpoint with `s3.fqdns` and `s3.backup.fqdns` in `cluster.yaml`, and see
  [Network policy for S3](#network-policy-for-s3). With virtual-host style
  the bucket name is part of the host name, so you need a `*.<endpoint>`
  pattern too.

**`aws s3 ls` says `The specified bucket does not exist` or
`PermanentRedirect`**
: The endpoint or region does not match the bucket's location. At Hetzner
  a bucket exists in one location only: `<prefix>-pg-backups` is reachable
  through `hel1.your-objectstorage.com`, not `fsn1`.

**A Hetzner bucket returns `AccessDenied` to its own key after adding a
policy**
: The principal is wrong. It must be
  `arn:aws:iam:::user/p<project-id>:<access-key>` with the numeric project
  ID and the **access** key (never the secret key). Remove the policy with
  `aws s3api delete-bucket-policy` using a key that still has access, or
  in the Hetzner Console.

**Bucket creation fails with `BucketAlreadyExists`**
: Someone else has that name. Choose another `s3.bucketPrefix` in
  `cluster.yaml` (step 7) and create all buckets with it.

**An application cannot log in: `password authentication failed for user`**
: The role's password Secret and the application's `DATABASE_URL` come
  from the same OpenBao entry, but are refreshed separately (every hour).
  After a password change, wait or force a refresh with
  `kubectl annotate externalsecret -n <namespace> <name> force-sync=$(date +%s) --overwrite`,
  then restart the application.

**`no pg_hba.conf entry ... no encryption`**
: The client connected without TLS. The URL needs
  `sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt`.

**`no pg_hba.conf entry for host ..., user "stash", database "hr"`**
: Working as designed: a login may only open the database of the same
  name.

**Den backups fail with `pg_dump: error: aborting because of server version
mismatch`**
: The server was upgraded past PostgreSQL 16. Den's operator can only dump
  PostgreSQL 16 for now; go back to a 16.x image.

## Related pages

- [Databases, backups and restore](../operations/databases-and-backups.md): Den's backups in detail.
- [Disaster recovery](../operations/disaster-recovery.md): lost server, lost cluster, lost key.
- [Secrets](../operations/secrets.md): every OpenBao path.
- [Internal TLS](../operations/internal-tls.md): the internal CA and public certificates.
- [Network policies](../operations/network-policies.md): which pod may talk to which.
- [High availability](high-availability.md): what survives which failure.
