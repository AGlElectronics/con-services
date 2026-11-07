# How the platform starts (Den first)

Con Services is brought up in a fixed order: **Den first, then the modules,
one at a time.** Den is the portal and admin console. Once it runs, it is
the place where you check the database and storage connection, create each
module's database, and pair each module so it follows the organisation's
brand and settings.

This page explains that order, what happens at each step, and which parts
are already automatic and which you still do by hand. The
[quickstart](den-quickstart.md) is the hands-on version of steps 1 to 3 on
a local cluster; this page continues with Stash as the worked example of a
module.

!!! info "Words used on this page"
    A **namespace** is a named section of a Kubernetes cluster; Con Services
    puts each part in its own one. A **module** is one of the apps (Stash,
    HR, Rally, …). **Pairing** connects a module to Den
    ([details](../concepts/pairing.md)). The **operator** is Den's small
    internal service that holds the database administrator login.

## The sequence at a glance

```mermaid
sequenceDiagram
    autonumber
    actor Ops as You (operator)
    participant K8s as Kubernetes
    participant KC as Keycloak<br/>(conservices-identity)
    participant Data as PostgreSQL + S3<br/>(conservices-data)
    participant Den as Den backend + operator<br/>(conservices-den)
    participant Stash as Stash<br/>(conservices-stash)

    Ops->>K8s: kubectl apply -k overlays/example
    K8s->>Data: start PostgreSQL (creates den + keycloak databases)
    K8s->>KC: start Keycloak, import realm "conservices"
    K8s->>Den: migrate (initContainer), then start Den
    Den->>KC: OIDC discovery (sign-in keys)
    Den->>Data: connect to its database and bucket
    Den->>Data: operator connects with the admin login
    Ops->>Den: sign in, Admin console → Backups
    Den-->>Ops: databases listed, backup target shown
    Ops->>Den: Modules → New module "stash",<br/>"Create a database for it"
    Den->>Data: operator creates database + login "stash"
    Den-->>Ops: connection URL (shown once)
    Ops->>K8s: put URL in overlay, kubectl apply -k overlays/example-stash
    K8s->>Stash: start Stash (migrates, creates its bucket)
    Ops->>Den: Modules → Pair → pairing URL
    Ops->>Stash: Settings → Den connection → paste URL
    Stash->>Den: redeem token → module credential
    loop every minute
        Stash->>Den: GET /api/v1/integrations/bundle
    end
    Note over Ops,Stash: Repeat from "New module" for HR, Rally, …
```

## What works today, and what is still planned

The idea is that you deploy Den, and then *through Den* connect the
database server and the S3 storage and add modules. Today part of that is
done in Den's admin console and part is still configuration you write into
the Kubernetes manifests:

| Step | Today | Planned |
| --- | --- | --- |
| Connect the PostgreSQL server | Configuration: `PG_ADMIN_URL` on the operator, `DATABASE_URL` on Den. Den's **Backups** page then shows the server and every database on it. | Enter and test the connection in Den. |
| Connect S3 storage | Configuration: `S3_*` on Den, `BACKUP_S3_*` and `FILES_S3_*` on the operator. Den creates its own bucket, the operator creates the backup bucket. | Enter and test storage in Den. |
| Create a module's database | **In Den**: Modules → New module → *Create a database for it*. The operator creates the database and its login and Den shows the connection URL once. | Same, plus handing the URL to the module automatically. |
| Create a module's bucket and storage keys | By hand: the module creates its bucket on first start with the storage keys you give it. Den does not create buckets or per-module keys. | Den provisions a bucket and scoped keys per module. |
| Add the module's bucket to backups | By hand: add it to `FILES_S3_BUCKETS` and re-apply. | Automatic when the module is added. |
| Deploy the module | By hand: `kubectl apply -k` its overlay. Den does not create Kubernetes objects. | Unchanged (deploying stays your job). |
| Pair the module | **In Den and the module**: pairing URL and token. | Unchanged. |
| Sign-in client for the module | Already in the imported realm for the known modules. New modules need a client added in Keycloak. | Unchanged. |

## Step 1: Deploy the platform

The platform is everything a module depends on. It lives in these
namespaces:

| Namespace | Runs |
| --- | --- |
| `conservices-gateway` | The Gateway `public`: the entry point for every web address, holding the HTTPS certificate. Each app attaches an `HTTPRoute` to it. |
| `conservices-identity` | Keycloak, the sign-in server. |
| `conservices-data` | PostgreSQL and the S3 server `s3` (SeaweedFS). *Only for local trials*; in production use CloudNativePG or managed PostgreSQL, and a managed S3 service (any S3-compatible one works, for example AWS S3, Hetzner Object Storage, Cloudflare R2 or Backblaze B2; see [Production](../operations/production.md#object-storage-use-managed-s3)). |
| `conservices-den` | Den's backend, web app and operator. |

The cluster needs **Cilium** with its Gateway API support, **cert-manager**
and **trust-manager** first: Cilium runs the Gateway and enforces the
network rules, and the other two make the certificates that encrypt every
connection between these parts (see
[Internal TLS](../operations/internal-tls.md#set-it-up), and step 4 of the
[quickstart](den-quickstart.md)). Then one command creates all of them:

```sh
kubectl apply -k deploy/kubernetes/overlays/example
```

Behind that command, in this order (Kubernetes retries until each
dependency is up):

1. cert-manager issues a certificate for every server (PostgreSQL, the S3
   server, Keycloak, Den), and trust-manager copies the internal certificate
   authority into each namespace. Pods wait until their certificate exists.
2. PostgreSQL starts and, on its very first start, creates two databases
   with their own logins: `den` and `keycloak`. Nothing else.
2. Keycloak starts and imports the `conservices` realm (users, groups and the
   sign-in clients of every module) from `infra/keycloak/realm-conservices.json`.
3. Den's `migrate` initContainer applies Den's database migrations and exits.
4. Den's backend starts. It downloads Keycloak's sign-in keys (it refuses to
   start without them), connects to its database, and creates its bucket
   `den-data` if it does not exist.
5. Den's operator starts with the PostgreSQL admin login and creates the
   backup bucket `conservices-backups` if it does not exist.

The [quickstart](den-quickstart.md) shows the exact output to expect.

!!! info "In production"
    This page uses the local trial's commands. A production cluster runs
    the same steps through Argo CD from a Git repository, with a load
    balancer address for the Gateway, PostgreSQL with failover and a
    managed S3 service; follow [Deploy with Argo CD](../deploy/index.md).
    Whatever the cluster, its network plugin must **enforce
    NetworkPolicy**; check it with the
    [enforcement test](../operations/network-policies.md#checking-that-your-cluster-enforces-policies).
    See [Production and security](../operations/production.md#the-production-shape).

## Step 2: Check that Den is ready

```sh
kubectl get pods -n conservices-den
```

```text
NAME                            READY   STATUS    RESTARTS   AGE
den-backend-6d9c8b7f5d-x2kqp    1/1     Running   0          2m
den-frontend-7b9f6c4d8-4hzvn    1/1     Running   0          2m
den-frontend-7b9f6c4d8-q8tml    1/1     Running   0          2m
den-operator-5c6f9d7b84-mn2rs   1/1     Running   0          2m
```

Then open <https://den.conservices.test>, sign in as an administrator and
open the **Admin console**.

## Step 3: Check the database and storage connection

Open **Admin console → Backups**. This page is Den's view of the operator,
and therefore of the database server and the backup storage:

- the list of **databases** on the server, with their sizes (`den` and
  `keycloak` at this point);
- the **backup target** (endpoint and bucket) and the encryption keys in use;
- the last and next backup.

If the page says the operator is *not set up*, Den has no `OPERATOR_URL`. If
it shows an error such as *Can't reach the operator* or *can't reach the
database server*, see [Troubleshooting](troubleshooting.md#den-shows-cant-reach-the-operator).

Click **Back up now**. A minute later the backup appears under *Stored
backups*. Now you know that Den, its operator, PostgreSQL and S3 storage
can all talk to each other.

!!! note "Planned: connecting storage and database from Den"
    Today the database server and S3 storage are set in configuration
    (see [Den configuration](../modules/den/configuration.md)), and this page
    only *shows* them. Entering and testing them in Den is planned.

## Step 4: Deploy a module (Stash)

Each module gets its own namespace, `conservices-<module>`, with the label
`conservices.io/tier: module`. That label is what lets the platform's
[network policies](../operations/network-policies.md) admit the module's
backend to Den, PostgreSQL and S3 storage, and nothing else.

### 4a. Register Stash in Den and create its database

In Den: **Admin console → Modules → New module**.

| Field | Value |
| --- | --- |
| Short name | `stash` |
| Display name | `Stash` |
| Address | `https://stash.conservices.test` |
| Environment | `production` |
| Create a database for it | ticked |

Click **Create module**. The operator creates a database `stash` owned by a
new login `stash` with a random password, and makes sure no other login can
connect to it. Den shows the connection URL **once**:

```text
postgres://stash:3f9c…e1@postgres.conservices-data.svc.cluster.local:5432/stash?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt
```

Copy it now. The address in it is PostgreSQL's in-cluster name
(`<service>.<namespace>.svc.cluster.local`), so Stash can use it as it is.

### 4b. Put the connection into Stash's overlay

Open `deploy/kubernetes/overlays/example-stash/secrets.yaml` and paste the
URL as `DATABASE_URL`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: stash-secrets
  namespace: conservices-stash
type: Opaque
stringData:
  DATABASE_URL: postgres://stash:3f9c…e1@postgres.conservices-data.svc.cluster.local:5432/stash?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt
  S3_ACCESS_KEY_ID: conservices
  S3_SECRET_ACCESS_KEY: conservicesdev
```

!!! warning "Local trial only"
    A plain Secret in a file is fine on your own computer. In a real
    installation, store the URL in your secret manager instead and let an
    `ExternalSecret` create `stash-secrets`; see [Secrets](../operations/secrets.md).
    Do not commit the file with the real password.

Storage: Stash creates its bucket (`stash-data`) itself when it first
starts, with the storage keys in the same secret. The example overlay uses
the local S3 server's keys; in production give each module its own keys that can
only reach its own bucket. The bucket is already listed in the platform
overlay's `FILES_S3_BUCKETS`, so it is included in backups.

Follow the remaining preparation in the overlay's header comment (copy
`rootCA.pem` from the platform overlay's `local/` folder and
`stash/infra/access-config.toml` into the Stash overlay's `local/`). The
HTTPS certificate is not needed again: Stash's `HTTPRoute` attaches to the
same Gateway, which already holds the `*.conservices.test` certificate.
Then apply:

```sh
kubectl apply -k deploy/kubernetes/overlays/example-stash
kubectl get pods -n conservices-stash -w
```

```text
NAME                              READY   STATUS    RESTARTS   AGE
stash-backend-5f7d9c6b8-kq2xd     1/1     Running   0          40s
stash-frontend-6c8b5d9f7-7wqzm    1/1     Running   0          40s
stash-frontend-6c8b5d9f7-p4ncs    1/1     Running   0          40s
```

Stash applies its own database migrations when it starts. Add
`stash.conservices.test` to your hosts file (the quickstart already did) and
open <https://stash.conservices.test>. Stash runs with `DEN_MODE=required`
like every module on Kubernetes, so until step 4c it shows
*Connect this module to Den* to Stash admins and *Waiting for Den* to
everyone else, and its API answers `503 den_pairing_required`
([Required or standalone](../concepts/pairing.md#required-or-standalone)).

### 4c. Pair Stash with Den

1. In Den: **Admin console → Modules**, click **Pair** on the Stash row. Den
   shows a pairing URL, valid for 15 minutes and usable once:

    ```text
    https://den.conservices.test/api/v1/integrations/pairing/redeem?token=Q2b9…
    ```

2. In Stash (signed in as a Stash admin, for example `admin`): paste the
   URL into the field on the *Connect this module to Den* page and confirm.
   (Once paired, the same field is under **Settings → Den connection**.)
3. Stash's backend swaps the public address for its `DEN_INTERNAL_URL`
   (`https://den-backend.conservices-den.svc.cluster.local:8080`), redeems
   the token and stores the module credential it gets back.
4. Den's Modules page now shows Stash as **paired**. The waiting page is
   gone and Stash works normally. Within a minute Stash shows Den's brand,
   and Den's portal home lists Stash under **Your services**.

## Step 5: Repeat for each module

For every further module (HR, Rally, Finance, Learn, Wiki, Desk, Tasks):

1. In Den: New module, with *Create a database for it*.
2. Create its namespace `conservices-<module>` with the labels
   `conservices.io/tier: module` and `pod-security.kubernetes.io/enforce: restricted`.
3. Put the database URL and its storage keys into its secret; add its bucket
   to `FILES_S3_BUCKETS` on the operator.
4. Add the NetworkPolicies for the integrations it uses (for example HR
   calling Wiki and Tasks); the list is in
   [Network policies](../operations/network-policies.md#calls-between-modules).
5. Apply it, then pair it.

Kustomize manifests exist for Stash only so far. The other modules have
Helm charts in `deploy/charts/` (a first, untested version): see
[Installing modules with Helm](../operations/helm.md) and each module's
**Setup** page under [Modules](../modules/index.md). The full checklist is
in [Add a module](../operations/running.md#add-a-module).

## Troubleshooting

**Backups page says *Not set up* (step 3)**
: Den's backend has no `OPERATOR_URL`. The example overlay sets it; in your
  own overlay, add it to `den-config`.

**Backups page lists no databases, or shows *can't reach the database server***
: The operator's `PG_ADMIN_URL` is wrong or PostgreSQL is not ready:

    ```sh
    kubectl logs -n conservices-den deploy/den-operator --tail 20
    kubectl get pods -n conservices-data
    ```

**New module: there is no *Create a database for it* option (step 4a)**
: The operator runs with `MANAGED_DATABASES=false`, or Den has no
  operator. Create the database and login yourself and put the URL into
  the module's secret.

**You lost the connection URL Den showed once**
: Den does not keep it. Set a new password for the module's login as
  described in [Rotate a secret](../operations/secrets.md#rotate-a-secret-with-eso-and-vault)
  (step 1), and build the URL from the address Den showed
  (`postgres://stash:<new password>@<host>:5432/stash?sslmode=…`).

**Stash says it cannot reach Den when you paste the pairing URL (step 4c)**
: Check `DEN_INTERNAL_URL` on Stash, and that its namespace has the label
  `conservices.io/tier=module` (`kubectl get ns conservices-stash --show-labels`).
  See [Timeouts between namespaces](troubleshooting.md#timeouts-between-namespaces).

**Pairing fails with *pairing token expired* or *pairing token already redeemed***
: Pairing URLs last 15 minutes and work once. Click **Pair** again in Den
  for a new one.

**Stash shows Den's brand only after several minutes**
: It fetches Den's bundle once a minute; wait a minute and reload.

## Related pages

- [Run Den on Kubernetes](den-quickstart.md): steps 1 to 3 by hand.
- [Pairing](../concepts/pairing.md): what pairing does.
- [Databases, backups and restore](../operations/databases-and-backups.md): how Den creates module databases.
- [Network policies](../operations/network-policies.md): why the namespace labels matter.
