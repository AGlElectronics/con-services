# Secrets

A **secret** is any value that grants access: a password, an API key, a
token, an encryption key. This page lists every secret Con Services uses,
where each one lives, how to keep them in a proper **secret manager**, and
how to change (rotate) them.

!!! danger "Plain Kubernetes Secrets are for trials only"
    The quickstart's `overlays/example/secrets.yaml` holds public `-dev-`
    values as plain Kubernetes Secrets in Git. That is acceptable on your
    own computer and nowhere else. For any installation that holds real
    data, keep secrets in a secret manager and let the cluster fetch them.
    Never commit a real secret to Git, not even in a private repository.

## Secrets in each way of running Con Services

The inventory below is the same whichever way you run Con Services; only
where the values are kept changes:

| Way of running | Where secrets live | Acceptable for real data |
| --- | --- | --- |
| [Full platform on Kubernetes](../getting-started/index.md#choose-your-path) | A secret manager, fetched by the External Secrets Operator into Kubernetes Secrets (or Sealed Secrets / SOPS for GitOps). | **Yes** (recommended). |
| [Standalone module on Kubernetes](../getting-started/standalone-kubernetes.md) | The same, in the module's own namespace. | **Yes**. |
| [Full stack on Docker (production)](docker-production.md) | Env files **outside Git**, readable only by root, written from your secret manager at deploy time. See [Secrets on Docker](#secrets-on-docker). | **Yes**, with care. |
| [Docker for development](../contributing/local-development.md) | The committed `.env.example` / `.env` and dev values in `docker-compose.yml`. | **No.** Local computer only. |
| Example overlay (`overlays/example`) | Plain `Secret`s in `secrets.yaml` with public dev values. | **No.** Local trial only. |

## Secrets on Docker

Con Services programs read most settings from **environment variables**.
A few settings are a path to a file, and the program reads that file
itself: `DEN_SMTP_PASSWORD_FILE` (Den re-reads the SMTP password on every
use, so replacing the mounted file needs no restart),
`GOOGLE_WORKSPACE_CREDENTIALS_FILE` (the Google service-account key),
`TLS_CERT_FILE` and `TLS_KEY_FILE` (the pod's certificate), and the config
paths such as `ACCESS_CONFIG_PATH` and `BRAND_LOCAL_PATH`. There is no
general `SOME_SECRET_FILE` companion for every secret. The backend images
have no shell, so Docker's `secrets:` (files under `/run/secrets`) do not
feed those programs unless you also set one of the path variables above.
The supported [Docker production](docker-production.md) setup
reads every setting and secret from one file, `.env`, next to
`deploy/docker/compose.production.yml`; Compose fills them into each
service's environment, and each service gets only the values its
`environment:` names.

1. Create `.env` readable only by the deploying user:

    ```sh
    install -m 600 /dev/null .env
    ```

2. Fill it from your secret manager when you deploy, instead of typing
   values by hand. For example with OpenBao or Vault, keeping the whole
   file as the entry `secret/conservices/docker` with one property per
   variable:

    ```sh
    bao kv get -format=json secret/conservices/docker \
      | jq -r '.data.data | to_entries[] | "\(.key)=\(.value)"' > .env
    ```

    A SOPS-encrypted file in your deployment repository
    (`sops --decrypt --input-type dotenv --output-type dotenv env.sops > .env`)
    or your password manager's CLI work the same way.

3. Check it: `docker compose -f compose.production.yml config --quiet`
   fails with `required variable … is missing a value` for every platform
   value still empty.

The same rules as on Kubernetes apply: never commit `.env` (the folder's
`.gitignore` excludes it), keep the secret manager as the source, and run
`docker compose -f compose.production.yml up -d` after changing a value so
the affected services are recreated. A plain `.env` on the server is the
weakest link: restrict SSH access, encrypt the disk, and do not copy the
file anywhere else.

## Why a secret manager

A plain Kubernetes Secret is only base64-encoded, not encrypted. Anyone who
can read the manifest, the Git history, a backup of the cluster's database
(etcd) or the namespace can read it. A secret manager (HashiCorp Vault,
OpenBao, AWS Secrets Manager, Azure Key Vault, Google Secret Manager, …)
gives you:

- one place where secrets are stored encrypted, with an audit log of who
  read what;
- access rules per application and per namespace;
- rotation without editing manifests.

### Which secret manager to use

- **Self-hosted cluster (your own servers or VMs): OpenBao.** OpenBao is the
  open-source, Linux Foundation fork of HashiCorp Vault; it runs inside the
  cluster, and the commands and ESO configuration on this page work with it
  unchanged (`bao` instead of `vault`). The
  [GitOps reference deployment](../deploy/index.md) expects OpenBao and ESO
  to be installed by the cluster's admin (a
  [prerequisite](../deploy/prerequisites.md#7-external-secrets-operator-and-openbao))
  and connects ESO to it through a ClusterSecretStore named `openbao`.
  Preparing OpenBao for Con Services, seeding and rotation:
  [Secrets with OpenBao](../deploy/secrets-openbao.md). Installing,
  unsealing and backing up OpenBao itself follow the
  [OpenBao documentation](https://openbao.org/docs/).
- **Managed cluster in a cloud: that cloud's secret manager** (AWS Secrets
  Manager, Azure Key Vault, Google Secret Manager), which needs no
  unsealing or backups from you. See [Other providers](#other-providers).
- **An existing Vault or OpenBao** in your organisation: use it, with a
  SecretStore per namespace as below.

## Inventory

**Platform** (manifests in `deploy/kubernetes/base/`):

| Secret (key) | Kubernetes Secret | Namespace | Used by | Notes |
| --- | --- | --- | --- | --- |
| `POSTGRES_PASSWORD` | `postgres-secrets` | `conservices-data` | PostgreSQL | Superuser. Also inside `PG_ADMIN_URL`. In-cluster PostgreSQL only. |
| `DEN_DB_PASSWORD`, `KEYCLOAK_DB_PASSWORD` | `postgres-secrets` | `conservices-data` | PostgreSQL first start | Create the `den` and `keycloak` logins. Only read when the volume is first initialised. |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | `s3-secrets` | `conservices-data` | S3 server `s3` (SeaweedFS) | Admin key of the in-cluster trial S3 server only (dev); it must equal the `S3_*`, `BACKUP_S3_*` and `FILES_S3_*` keys the backends and the operator use. Rotate: change it in your secret manager and in those module secrets, then `kubectl rollout restart -n conservices-data deployment/s3` and restart the backends. The `production-external-secrets` example reads it from the Vault path `conservices/data/s3`. |
| `KC_DB_PASSWORD` | `keycloak-secrets` | `conservices-identity` | Keycloak | = `KEYCLOAK_DB_PASSWORD`. |
| `KC_BOOTSTRAP_ADMIN_USERNAME`, `KC_BOOTSTRAP_ADMIN_PASSWORD` | `keycloak-secrets` | `conservices-identity` | Keycloak | Temporary admin of the master realm, used on first start. Replace it with a real admin account, then remove it. |
| `DATABASE_URL` | `den-secrets` | `conservices-den` | Den backend and migrate | Contains Den's database password. |
| `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` | `den-secrets` | `conservices-den` | Den backend | Keys for Den's bucket only. |
| `KEYCLOAK_CLIENT_SECRET` | `den-secrets` | `conservices-den` | Den backend | Secret of the `den-keycloak` client in Keycloak (can change realm settings). |
| `OPERATOR_TOKEN` | `den-secrets` **and** `den-operator-secrets` | `conservices-den` | Den backend, operator | Shared; must be equal in both. |
| `PG_ADMIN_URL` | `den-operator-secrets` | `conservices-den` | Den operator | **PostgreSQL superuser login.** The most powerful secret in the suite. |
| `BACKUP_S3_ACCESS_KEY_ID`, `BACKUP_S3_SECRET_ACCESS_KEY` | `den-operator-secrets` | `conservices-den` | Den operator | Write access to the backup bucket, ideally at another provider. |
| `FILES_S3_ACCESS_KEY_ID`, `FILES_S3_SECRET_ACCESS_KEY` | `den-operator-secrets` | `conservices-den` | Den operator | Read access to every module bucket in `FILES_S3_BUCKETS`. |
| age **secret** key | none | **offline** | people restoring a backup | Never in the cluster. The cluster only has the public key (`BACKUP_AGE_RECIPIENTS`, not secret). See [The encryption key](databases-and-backups.md#the-encryption-key). |
| TLS private key | `conservices-tls` | each namespace with an Ingress | ingress controller | Normally managed by cert-manager. |
| Internal CA private key (`tls.key`) | `conservices-internal-ca` | `cert-manager` | cert-manager (`ClusterIssuer/conservices-internal-ca`) | Signs every internal certificate. Created by cert-manager inside the cluster, never in your secret manager. Back it up with the cluster; rotate only if leaked, as in [Rotating the internal CA](internal-tls.md#rotating-the-internal-ca). |
| Service TLS keys (`tls.key`, `tls.crt`, `ca.crt`) | `postgres-tls`, `s3-tls`, `keycloak-tls`, `den-backend-tls`, `den-operator-tls`, `den-frontend-tls`, `<module>-backend-tls`, `<module>-frontend-tls` | the service's namespace | that service | Created and renewed by cert-manager every 60 days. Rotate now by deleting the Secret; cert-manager issues a new key in seconds. See [Internal TLS](internal-tls.md#renewal). |
| `api-token` | `cloudflare-api-token` (from OpenBao `conservices/infra/cloudflare` through the `ExternalSecret` of the same name) | `cert-manager` | cert-manager (Let's Encrypt DNS-01) | GitOps reference only. A Cloudflare API token limited to **Zone: DNS: Edit** and **Zone: Zone: Read** on one zone. Rotate by creating a new token in Cloudflare, `bao kv patch`, then revoking the old one. See [DNS and certificates](../deploy/dns-and-certificates.md). |
| OpenBao admin token for `openbao-configure.sh` / `.ps1` | none | your shell only (asked for, or `BAO_TOKEN`) | the OpenBao administrator, once per cluster | GitOps reference only. Writes the policies and the setup role; never store it in the cluster or in Git, and revoke a temporary one afterwards. Entering your provider credentials needs only a token that may write `conservices/`. The setup Job and External Secrets log in with their service accounts and need no token. OpenBao's own unseal keys, root token and TLS key belong to its operator. See [Secrets with OpenBao](../deploy/secrets-openbao.md). |

**GitOps reference: OpenBao paths of the platform.** In
[con-services-gitops](../deploy/index.md) every secret below is read from
OpenBao (its own KV v2 mount, `conservices/` by default) by External Secrets.
External Secrets creates the random ones (PushSecrets, never replacing an
existing value) and you enter the provider credentials, only for the
modules and options enabled in `cluster.yaml`
([Every secret](../deploy/secrets-openbao.md#every-secret-keys-and-values)).
Entries marked *rotatable* can be rotated by deleting them
([Rotate a generated value](../deploy/secrets-openbao.md#rotate-a-generated-value)).

| OpenBao path | Keys | Becomes (Secret, namespace) | Used by | Source, rotation |
| --- | --- | --- | --- | --- |
| `conservices/infra/postgres/superuser` | `password` (user `postgres`) | `conservices-pg-superuser` (`conservices-data`); `PG_ADMIN_URL` in `den-operator-secrets` | CloudNativePG, Den operator | generated; rotatable (CNPG applies the new password) |
| `conservices/infra/postgres/roles/<role>` (`den`, `keycloak`, `stash`, `hr`, `events`, `finance`, `learn`, `wiki`, `desk`, `tasks`) | `password` | `conservices-pg-role-<role>` (`conservices-data`); `DATABASE_URL` of the application; `keycloak-db` | CloudNativePG, each application | generated; rotatable, then restart the application |
| `conservices/infra/postgres/backup-s3` | `access_key`, `secret_key` | `cnpg-backups-s3` (`conservices-data`) | Barman Cloud plugin (WAL archive, base backups) | your S3 provider; rotate there, then `bao kv put` |
| `conservices/modules/<module>/s3` (`den`, `stash`, `rally`, `finance`, `learn`, `wiki`, `tasks`) | `access_key`, `secret_key` | `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` in `<module>-secrets` | the module's backend | your S3 provider, one key per bucket |
| `conservices/modules/den/backup-s3` | `access_key`, `secret_key` | `BACKUP_S3_*` in `den-operator-secrets` | Den operator | your S3 provider, backup bucket only |
| `conservices/modules/den/files-s3` | `access_key`, `secret_key` | `FILES_S3_*` in `den-operator-secrets` | Den operator | your S3 provider, read-only on the module buckets |
| `conservices/modules/den/operator-token` | `token` | `OPERATOR_TOKEN` in `den-secrets` and `den-operator-secrets` | Den backend, operator | generated; rotatable |
| `conservices/modules/<module>/service-token` (`learn`, `wiki`, `tasks`) | `token` | the module's service token and HR's `LEARN_SERVICE_TOKEN`, `OFFBOARD_HOOKS`, `DEPARTMENT_HOOKS` | HR calling Learn, Wiki, Tasks | generated; rotatable |
| `conservices/modules/desk/secret-key` | `key` | `DESK_SECRET_KEY` in `desk-secrets` | Desk | generated; **never rotate** (stored mailbox passwords become unreadable) |
| `conservices/modules/<module>/den-link` (every enabled module) | `key` | `DEN_LINK_ENCRYPTION_KEY` in `<module>-secrets` | the module's backend (shared `denlink`) | generated (43 letters and digits = 32 bytes as unpadded base64); rotate with the [two-step rotation](#den-link-encryption-key), never by deleting the entry alone |
| `conservices/infra/keycloak/bootstrap-admin` | `password` (user `temp-admin`) | `keycloak-bootstrap-admin` (`conservices-identity`) | Keycloak, first start only | generated; delete the user after the [first admin login](../deploy/identity.md#first-admin-login) |
| `conservices/infra/keycloak/clients` | `den-keycloak`, `hr-provisioner`, `learn-provisioner` | `keycloak-realm-secrets` (realm import); `KEYCLOAK_CLIENT_SECRET` of Den, HR, Learn | Keycloak, Den, HR, Learn | generated; to rotate, regenerate in Keycloak, then `bao kv patch` |
| `conservices/infra/keycloak/smtp` | `host`, `port`, `from`, `username`, `password` | `keycloak-realm-secrets` | Keycloak e-mail | your mail provider; you enter it |
| `conservices/infra/ghcr` | `username`, `token` | `ghcr-pull` (`kubernetes.io/dockerconfigjson`) in every application namespace | image pulls | optional, only with `images.pullSecret.enabled: true` (private images); GitHub personal access token with **only `read:packages`**; see [Private images](../deploy/apps.md#private-images-the-ghcr-pull-secret) |
| `conservices/infra/cloudflare` | `api-token` | `cloudflare-api-token` (`cert-manager`) | cert-manager (Let's Encrypt DNS-01) | optional, only with `acme.dns01.provider: cloudflare`; see [DNS and certificates](../deploy/dns-and-certificates.md) |

The age **public** key for Den's backups (`BACKUP_AGE_RECIPIENTS`) is not
secret and lives in `cluster.yaml` (`den.backupAgeRecipients`).

**S3 keys in production** come from your managed object storage, AWS S3
(IAM user or role with a per-bucket policy) or Hetzner Object Storage
(S3 credentials per project), which are the recommended choices; see
[Production](production.md#object-storage-use-managed-s3). Create one key
set per bucket so a leaked module key exposes only that module's files, and
keep the backup keys separate from the application keys
([Buckets and keys](../deploy/data.md#buckets-and-keys)). The
`s3-secrets` key exists only for the in-cluster trial S3 server.

**Keycloak client secrets** are stored in Keycloak's database, and the test
realm file `infra/keycloak/realm-conservices.json` contains **public dev
values** for `den-keycloak`, `hr-provisioner` and `learn-provisioner`. After
importing that realm anywhere real, regenerate each of them in the Keycloak
admin console (**Clients → client → Credentials → Regenerate**) and put the
new value in your secret manager.

**Created by Den at run time** (not Kubernetes Secrets):

| Secret | Where it lives | Notes |
| --- | --- | --- |
| Module database URL | Shown once by Den when it creates a module's database | Contains a random password. Put it in the module's secret manager entry straight away; Den does not keep it. |
| Pairing token | Den's database stores only its SHA-256 hash | Valid 15 minutes, single use. |
| Module credential | Den stores only the hash; the module stores the value in **its own database** | Lets the module call Den's integration API. |

**Modules** (from the root `docker-compose.yml`; manifests for these come
with each module's docs):

| Module | Secrets | Namespace |
| --- | --- | --- |
| Stash | `DATABASE_URL`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` | `conservices-stash` |
| HR | `DATABASE_URL`, `S3_*` keys, `KEYCLOAK_CLIENT_SECRET` (`hr-provisioner`, can manage users), `LEARN_SERVICE_TOKEN`, the tokens inside `OFFBOARD_HOOKS` and `DEPARTMENT_HOOKS`, SMTP password if any | `conservices-hr` |
| Learn | `DATABASE_URL`, `S3_*` keys, `KEYCLOAK_CLIENT_SECRET` (`learn-provisioner`), `LEARN_SERVICE_TOKEN`, `TELEGRAM_BOT_TOKEN` | `conservices-learn` |
| Wiki | `DATABASE_URL`, `S3_*` keys, `WIKI_SERVICE_TOKEN` | `conservices-wiki` |
| Tasks | `DATABASE_URL`, `S3_*` keys, `TASKS_SERVICE_TOKEN` | `conservices-tasks` |
| Desk | `DATABASE_URL`, `DESK_SECRET_KEY` (encrypts stored mailbox passwords), SMTP password if any | `conservices-desk` |
| Finance | `DATABASE_URL`, `S3_*` keys | `conservices-finance` |
| Rally | `DATABASE_URL`, `S3_*` keys, `TELEGRAM_BOT_TOKEN` | `conservices-rally` |

Service tokens are shared by two modules: `WIKI_SERVICE_TOKEN` must match the
token in HR's `OFFBOARD_HOOKS`, `TASKS_SERVICE_TOKEN` the one in
`DEPARTMENT_HOOKS`, and `LEARN_SERVICE_TOKEN` is set on both HR and Learn.

**Shared-code secrets** ([Shared code](../concepts/shared-code.md)). Each
module needs these from the release in which it adopts the shared package;
its changelog says when, and its chart then lists the key under
`existingSecret`:

| Secret (key) | Kubernetes Secret | Namespace | Used by | Notes |
| --- | --- | --- | --- | --- |
| `DEN_LINK_ENCRYPTION_KEY` | `<module>-secrets` | `conservices-<module>` | every module (shared `denlink`) | 32 random bytes, base64; **one per module**, never shared. Encrypts the Den credential the module stores. Required unless `APP_ENV=development`. Rotate as in [Den link encryption key](#den-link-encryption-key). |
| `DEN_LINK_ENCRYPTION_KEY_PREVIOUS` | `<module>-secrets` | `conservices-<module>` | same | Only during a rotation: the old key. Remove it after the restart that follows. |
| `credentials.json` (service-account key) | `<module>-google-workspace`, mounted as a file; `GOOGLE_WORKSPACE_CREDENTIALS_FILE` points at it | the module's namespace | modules using the shared `gworkspace` | A Google service-account key with domain-wide delegation: it can act as **any** account in the domain for the scopes you authorised. See [Google Workspace service-account key](#google-workspace-service-account-key). |
| `HR_SERVICE_TOKEN` | `hr-secrets` and `<module>-secrets` | HR's and each module's | HR reading role catalogs | Planned with the [role catalog contract](../concepts/role-catalog.md); not used by any release yet. Same value on every side; allows only catalog reads. |

### Den link encryption key

Every module that uses the shared `denlink` encrypts the module credential
it gets from Den with its own `DEN_LINK_ENCRYPTION_KEY`. If the key is lost,
the module cannot read its credential and must be paired again; nothing
else is lost.

1. Generate one key per module:

    ```sh
    openssl rand -base64 32
    ```

    ```text
    q3V0w6m3cXn8m1x0ZrQm9b7c2H4v5o6p7q8r9s0t1u4=
    ```

    In PowerShell:
    `$b = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); [Convert]::ToBase64String($b)`.

2. Store it in the module's entry of your secret manager, for example
   `vault kv patch secret/conservices/stash/backend DEN_LINK_ENCRYPTION_KEY=<value>`,
   so it reaches `stash-secrets` (see [Add a module's secrets](#add-a-modules-secrets)).
   The Argo CD template skips steps 1 and 2: it generates the key in
   OpenBao (`conservices/modules/<module>/den-link`, property `key`) and
   wires it into `<module>-secrets`. To rotate it there, write the current
   value as `DEN_LINK_ENCRYPTION_KEY_PREVIOUS` into the module's Secret
   values (add it to the module's ExternalSecret in
   `charts/module-extras`), then `bao kv patch` a new `key`.
3. Restart the module. A credential stored before is encrypted on its
   first read; the log says `den link: re-encrypted the stored credential with the current key`.

To **rotate** it, keep the old key readable for one restart:

1. Set `DEN_LINK_ENCRYPTION_KEY_PREVIOUS` to the current value and
   `DEN_LINK_ENCRYPTION_KEY` to a new one, in the secret manager.
2. Force the sync and restart the module. On its next read (within a
   minute) the module re-encrypts the credential with the new key.
3. Remove `DEN_LINK_ENCRYPTION_KEY_PREVIOUS` and restart again.

### Google Workspace service-account key

The key file of a Google service account with domain-wide delegation lets
its holder act as any user of the Workspace domain for the scopes you
authorised. Treat it like the PostgreSQL superuser login: one key per
module that needs it, only the scopes it needs, kept in the secret manager
and mounted read-only.

1. Store the JSON file in the secret manager, for example as the field
   `credentials.json` of `secret/conservices/hr/google-workspace`.
2. Let ESO write it into a Secret of its own, which the Deployment mounts
   as a file:

    ```yaml
    apiVersion: external-secrets.io/v1
    kind: ExternalSecret
    metadata:
      name: hr-google-workspace
      namespace: conservices-hr
    spec:
      refreshInterval: 1h
      secretStoreRef:
        name: vault
        kind: SecretStore
      target:
        name: hr-google-workspace
      data:
        - secretKey: credentials.json
          remoteRef:
            key: conservices/hr/google-workspace
            property: credentials.json
    ```

    ```yaml
    # in the backend container of the Deployment
    env:
      - name: GOOGLE_WORKSPACE_CREDENTIALS_FILE
        value: /etc/conservices/google-workspace/credentials.json
    volumeMounts:
      - name: google-workspace
        mountPath: /etc/conservices/google-workspace
        readOnly: true
    # in the pod
    volumes:
      - name: google-workspace
        secret:
          secretName: hr-google-workspace
          defaultMode: 0400
    ```

3. **Rotate** it by creating a second key for the service account in the
   Google Cloud console, replacing the file in the secret manager,
   restarting the module, and then deleting the old key in the console.
   Delete the key at once if it leaked; the domain-wide delegation entry
   stays valid for the new key.

### OpenBao paths of the GitOps reference

In the [GitOps reference deployment](../deploy/index.md) every secret above
comes from one OpenBao entry (KV version 2, in Con Services' own mount
`conservices/`: `modules/` for Den and the modules, `infra/` for
PostgreSQL, Keycloak, Cloudflare and the registry login), read by
External Secrets through the ClusterSecretStore `openbao`. Several
Kubernetes Secrets read the same entry, so the two sides of a shared value
can never disagree. External Secrets generates the random values (48
letters and digits) and never replaces an existing one; you enter the ones
that come from a provider. Both only for what `cluster.yaml` enables.

| OpenBao path | Keys | Kubernetes Secrets (namespace) | Source | Rotate |
| --- | --- | --- | --- | --- |
| `conservices/infra/postgres/superuser` | `password` | `conservices-pg-superuser` (`conservices-data`); `PG_ADMIN_URL` in `den-operator-secrets` (`conservices-den`) | generated | delete the entry ([how](../deploy/secrets-openbao.md#rotate-a-generated-value)); CloudNativePG changes the password, restart `den-operator` |
| `conservices/infra/postgres/roles/<role>` (`den`, `keycloak`, `stash`, `hr`, `events`, `finance`, `learn`, `wiki`, `desk`, `tasks`) | `password` | `conservices-pg-role-<role>` (`conservices-data`); the `DATABASE_URL` of the module; `keycloak-db` (`conservices-identity`) | generated | delete the entry; then restart the module |
| `conservices/modules/den/operator-token` | `token` | `OPERATOR_TOKEN` in `den-secrets` and `den-operator-secrets` | generated | delete the entry; restart both Den deployments |
| `conservices/modules/learn/service-token`, `.../wiki/service-token`, `.../tasks/service-token` | `token` | `LEARN_SERVICE_TOKEN` (HR, Learn); `WIKI_SERVICE_TOKEN` and the token in HR's `OFFBOARD_HOOKS`; `TASKS_SERVICE_TOKEN` and the token in HR's `DEPARTMENT_HOOKS` | generated | delete the entry; restart HR and the module |
| `conservices/modules/desk/secret-key` | `key` | `DESK_SECRET_KEY` in `desk-secrets` | generated | **never** (stored mailbox passwords become unreadable) |
| `conservices/modules/<module>/den-link` | `key` | `DEN_LINK_ENCRYPTION_KEY` in `<module>-secrets` | generated | two steps, see [Den link encryption key](#den-link-encryption-key); deleting the entry alone makes the module pair again |
| `conservices/infra/keycloak/bootstrap-admin` | `password` | `keycloak-bootstrap-admin` (`conservices-identity`) | generated | not needed: used once, then the user is deleted ([First admin login](../deploy/identity.md#first-admin-login)) |
| `conservices/infra/keycloak/clients` | `den-keycloak`, `hr-provisioner`, `learn-provisioner` | `keycloak-realm-secrets` (first realm import); `KEYCLOAK_CLIENT_SECRET` of Den, HR and Learn | generated | regenerate in the Keycloak admin console, then `bao kv patch conservices/infra/keycloak/clients <client>=-` and restart the module |
| `conservices/infra/keycloak/smtp` | `host`, `port`, `from`, `username`, `password` | `keycloak-realm-secrets` (first realm import only) | your mail provider | at the provider, then in Keycloak: **Realm settings → Email** |
| `conservices/modules/<module>/s3` (`den`, `stash`, `rally`, `finance`, `learn`, `wiki`, `tasks`) | `access_key`, `secret_key` | `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` of the module | your S3 provider, one key per bucket | new key at the provider, `bao kv put`, restart the module, delete the old key |
| `conservices/modules/den/files-s3` | `access_key`, `secret_key` | `FILES_S3_*` in `den-operator-secrets` | S3 provider, **read-only** on all module buckets | as above |
| `conservices/modules/den/backup-s3` | `access_key`, `secret_key` | `BACKUP_S3_*` in `den-operator-secrets` | S3 provider, own key for the Den backup bucket | as above |
| `conservices/infra/postgres/backup-s3` | `access_key`, `secret_key` | `cnpg-backups-s3` (`conservices-data`) | S3 provider, own key for the PostgreSQL backup bucket | as above; CloudNativePG picks up the new key by itself |
| `conservices/infra/ghcr` (only with `images.pullSecret.enabled`) | `username`, `token` | `ghcr-pull` (type `kubernetes.io/dockerconfigjson`) in every Den and module namespace | a GitHub classic token with **only `read:packages`** | new token, `bao kv patch conservices/infra/ghcr token=-`, revoke the old one ([Private images](../deploy/apps.md#private-images-the-ghcr-pull-secret)) |
| `conservices/infra/cloudflare` (only with `acme.dns01.provider: cloudflare`) | `api-token` | `cloudflare-api-token` (`cert-manager`) | a Cloudflare API token limited to one zone | new token in Cloudflare, `bao kv patch conservices/infra/cloudflare api-token=-`, revoke the old one |

Every S3 entry gets its **own** access key, allowed only on its own bucket
(read only for `modules/den/files-s3`), even where one key could reach all
buckets: a leaked key then exposes one bucket, and you rotate it alone. The
seed script warns when two entries share a key.

External Secrets refreshes every Secret hourly. To apply a rotated value
at once, run
`kubectl annotate externalsecret -n <namespace> <name> force-sync=$(date +%s) --overwrite`,
then restart the workload (environment variables are read at start).

!!! note "Not a secret: Rally's `PUBLIC_API_BUILTIN_KEY`"
    The public event submission site hands this key to every visitor (it is
    `publicScheduleKey` in the site's `/config.json`; the Helm chart copies
    it there). Treat it as an identifier for rate limiting and revocation,
    not as a secret. The same goes for everything else in a web app's
    `/config.json`: the file is public, so never put a secret in it.

## How the manifests are organised

The base never contains Secrets. Each overlay supplies them in **one file**,
with the names and keys the base expects:

| Overlay | Secrets file | Use |
| --- | --- | --- |
| `overlays/example/` | `secrets.yaml`: plain `Secret` objects with public dev values | Local trial only |
| `overlays/production-external-secrets/` | `external-secrets.yaml`: `SecretStore` + `ExternalSecret` objects | Production |

Switching is a one-line change in the overlay's `kustomization.yaml`:

```yaml
resources:
  - ../../base
  - external-secrets.yaml   # instead of secrets.yaml
```

## Recommended: External Secrets Operator

The [External Secrets Operator](https://external-secrets.io) (ESO) runs in
your cluster, reads secrets from your secret manager and writes them into
ordinary Kubernetes Secrets, which the pods use unchanged.

1. Install ESO (once per cluster), following
   <https://external-secrets.io/latest/introduction/getting-started/>.
2. Store the values in your secret manager, one entry per Kubernetes Secret.
   With Vault or OpenBao (KV version 2, mount `secret`):

    ```sh
    vault kv put secret/conservices/den/backend \
      DATABASE_URL='postgres://den:change-me@db.example.org:5432/den?sslmode=require' \
      S3_ACCESS_KEY_ID=change-me S3_SECRET_ACCESS_KEY=change-me \
      KEYCLOAK_CLIENT_SECRET=change-me OPERATOR_TOKEN=change-me
    ```

    The [GitOps reference deployment](../deploy/secrets-openbao.md) mounts
    KV version 2 at `conservices/`, not `secret/`, and keeps the entries
    under `modules/` and `infra/` there (for example
    `conservices/infra/postgres/superuser`). Use `path: conservices` in the
    store there.

3. Give each namespace its own read-only access. In Vault, a policy and a
   Kubernetes-auth role per namespace:

    ```sh
    vault policy write conservices-den - <<'EOF'
    path "secret/data/conservices/den/*" { capabilities = ["read"] }
    EOF
    vault write auth/kubernetes/role/conservices-den \
      bound_service_account_names=external-secrets \
      bound_service_account_namespaces=conservices-den \
      policies=conservices-den ttl=15m
    ```

4. Apply the production overlay. For Den it contains:

    ```yaml
    apiVersion: external-secrets.io/v1
    kind: SecretStore
    metadata:
      name: vault
      namespace: conservices-den
    spec:
      provider:
        vault:
          server: https://vault.example.org
          path: secret
          version: v2
          auth:
            kubernetes:
              mountPath: kubernetes
              role: conservices-den
              serviceAccountRef:
                name: external-secrets
    ---
    apiVersion: external-secrets.io/v1
    kind: ExternalSecret
    metadata:
      name: den-secrets
      namespace: conservices-den
    spec:
      refreshInterval: 1h
      secretStoreRef:
        name: vault
        kind: SecretStore
      target:
        name: den-secrets        # the name the Den Deployment expects
      dataFrom:
        - extract:
            key: conservices/den/backend
    ```

5. Check that ESO synced it:

    ```sh
    kubectl get externalsecret -n conservices-den
    ```

    ```text
    NAME                   STORE   REFRESH INTERVAL   STATUS         READY
    den-operator-secrets   vault   1h                 SecretSynced   True
    den-secrets            vault   1h                 SecretSynced   True
    ```

### Add a module's secrets

Every module gets its own namespace, its own `SecretStore` and its own path
in the secret manager, so it can never read Den's or another module's
secrets. Example for Stash with Vault (the other modules work the same way;
the keys each one needs are in the [inventory](#inventory) and in the
module's `values.yaml` under `existingSecret`):

1. Store the values. `DATABASE_URL` is the connection URL Den showed once
   when it created the module's database:

    ```sh
    vault kv put secret/conservices/stash/backend \
      DATABASE_URL='postgres://stash:change-me@db.example.org:5432/stash?sslmode=require' \
      S3_ACCESS_KEY_ID=change-me S3_SECRET_ACCESS_KEY=change-me \
      DEN_LINK_ENCRYPTION_KEY="$(openssl rand -base64 32)"
    ```

    `DEN_LINK_ENCRYPTION_KEY` is read from the Stash release that adopts the
    shared `denlink` ([Den link encryption key](#den-link-encryption-key));
    an older Stash ignores it.

2. Give the namespace read access to that path only:

    ```sh
    vault policy write conservices-stash - <<'EOF'
    path "secret/data/conservices/stash/*" { capabilities = ["read"] }
    EOF
    vault write auth/kubernetes/role/conservices-stash \
      bound_service_account_names=external-secrets \
      bound_service_account_namespaces=conservices-stash \
      policies=conservices-stash ttl=15m
    ```

3. Apply the service account, store and `ExternalSecret` in the module's
   namespace:

    ```yaml
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: external-secrets
      namespace: conservices-stash
    automountServiceAccountToken: false
    ---
    apiVersion: external-secrets.io/v1
    kind: SecretStore
    metadata:
      name: vault
      namespace: conservices-stash
    spec:
      provider:
        vault:
          server: https://vault.example.org
          path: secret
          version: v2
          auth:
            kubernetes:
              mountPath: kubernetes
              role: conservices-stash
              serviceAccountRef:
                name: external-secrets
    ---
    apiVersion: external-secrets.io/v1
    kind: ExternalSecret
    metadata:
      name: stash-secrets
      namespace: conservices-stash
    spec:
      refreshInterval: 1h
      secretStoreRef:
        name: vault
        kind: SecretStore
      target:
        name: stash-secrets      # the name the chart's existingSecret expects
      dataFrom:
        - extract:
            key: conservices/stash/backend
    ```

4. Check it synced:

    ```sh
    kubectl get externalsecret -n conservices-stash
    ```

    ```text
    NAME            STORE   REFRESH INTERVAL   STATUS         READY
    stash-secrets   vault   1h                 SecretSynced   True
    ```

Then install the module ([Helm](helm.md#install-a-module) or Kustomize).

### Other providers

Only the `SecretStore`'s `provider` block changes; the `ExternalSecret`
objects stay the same (with the key names your provider uses).

=== "AWS Secrets Manager"

    ```yaml
    spec:
      provider:
        aws:
          service: SecretsManager
          region: eu-central-1
          auth:
            jwt:
              serviceAccountRef:
                name: external-secrets   # annotated with an IAM role (IRSA)
    ```

=== "Azure Key Vault"

    ```yaml
    spec:
      provider:
        azurekv:
          vaultUrl: https://conservices-kv.vault.azure.net
          authType: WorkloadIdentity
          serviceAccountRef:
            name: external-secrets
    ```

=== "Google Secret Manager"

    ```yaml
    spec:
      provider:
        gcpsm:
          projectID: conservices-prod
          auth:
            workloadIdentity:
              clusterLocation: europe-west3
              clusterName: conservices
              serviceAccountRef:
                name: external-secrets
    ```

Key Vault and Secret Manager store one value per secret; there, use
`data:` entries (one per key) instead of `dataFrom.extract`, or store each
group as a JSON object and keep `extract`.

### Alternatives for Git-based workflows

- **[Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets)**:
  encrypt a Secret with the cluster's public key (`kubeseal`) and commit the
  encrypted `SealedSecret`; only the cluster can decrypt it.
- **[SOPS](https://github.com/getsops/sops)**: encrypt the values in
  `secrets.yaml` with age or a cloud KMS key and let your GitOps tool
  (Flux, or Argo CD with a plugin) decrypt during deployment.

Both keep encrypted secrets in Git. A secret manager is still preferable
for rotation and auditing.

## Protect secrets inside the cluster

- **Encrypt etcd at rest.** Kubernetes stores Secrets in its database,
  etcd. Managed clusters (EKS, AKS, GKE) encrypt it or offer KMS
  encryption; on your own control plane configure an
  [EncryptionConfiguration](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
  with a KMS provider.
- **Least privilege.** Grant people and tools `get`/`list` on Secrets only
  in the namespaces they look after. Nobody needs read access to
  `conservices-den`'s secrets except whoever runs Den. The Con Services pods
  themselves have no Kubernetes API access at all
  ([details](network-policies.md#service-accounts-and-kubernetes-api-access)).
- **One store per namespace.** Use namespaced `SecretStore`s, not one
  cluster-wide store, so a module namespace can never read the operator's
  superuser login. The GitOps reference deployment uses one
  ClusterSecretStore `openbao` for simplicity, which any namespace can use
  for any entry under `conservices/`. There, limit who may create `ExternalSecret`
  objects with RBAC, and restrict the store to the namespaces that need it
  with its `spec.conditions` (`namespaceSelector` or `namespaces`), or
  switch to per-namespace stores as described above
  ([trade-off](../deploy/secrets-openbao.md#what-the-template-sets-up)).
- **Keep secrets out of logs and tickets.** Den shows a module's database
  password and pairing tokens exactly once; copy them straight into the
  secret manager.

## Rotating secrets

Every Con Services program reads its settings when it **starts**. After a
secret changes in Kubernetes (by hand or by ESO), restart the pods that use
it:

```sh
kubectl rollout restart -n conservices-den deploy/den-backend
```

Tools such as [Reloader](https://github.com/stakater/Reloader) can do this
automatically when a Secret changes.

### Rotate a secret with ESO and Vault

Example: a new password for Stash's database login. The same five steps
work for any secret; only step 1 changes.

1. **Make the new value valid at the source.** For a database password, as
   superuser (for example inside the `den-operator` pod, where
   `PG_ADMIN_URL` is set):

    ```sh
    kubectl exec -it -n conservices-den deploy/den-operator -- sh
    psql "$PG_ADMIN_URL" -c "ALTER ROLE stash PASSWORD 'new-long-random-value'"
    exit
    ```

    ```text
    ALTER ROLE
    ```

    Generate the value with `openssl rand -hex 24`. Hex keeps it safe inside
    a URL; other characters such as `@`, `/` or `:` would need escaping in
    `DATABASE_URL`.

    Existing connections keep working; new ones need the new password.

2. **Store it in Vault.** `kv patch` changes one key and keeps the others:

    ```sh
    vault kv patch secret/conservices/stash/backend \
      DATABASE_URL='postgres://stash:new-long-random-value@db.example.org:5432/stash?sslmode=require'
    ```

3. **Make ESO fetch it now** instead of waiting for `refreshInterval`:

    ```sh
    kubectl annotate externalsecret -n conservices-stash stash-secrets \
      force-sync=$(date +%s) --overwrite
    kubectl get externalsecret -n conservices-stash stash-secrets
    ```

    ```text
    NAME            STORE   REFRESH INTERVAL   STATUS         READY
    stash-secrets   vault   1h                 SecretSynced   True
    ```

4. **Restart** the pods that use it:

    ```sh
    kubectl rollout restart -n conservices-stash deploy/stash-backend
    kubectl rollout status -n conservices-stash deploy/stash-backend
    ```

5. **Check** the module is healthy (`/api/health` says `"database":"ok"`)
   and, for keys, delete the old one at the provider.

On PowerShell, replace `$(date +%s)` with
`$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())`.

| Secret | How to rotate | Downtime |
| --- | --- | --- |
| Database password of a module or Den | `ALTER ROLE <name> PASSWORD '<new>'` as superuser, update `DATABASE_URL`, restart the module. | A restart. Existing connections keep working until then. |
| `PG_ADMIN_URL` (superuser) | `ALTER ROLE postgres PASSWORD '<new>'`, update the secret, restart `den-operator`. | Backups and module database changes pause during the restart. |
| `OPERATOR_TOKEN` | Change it in **both** `den-secrets` and `den-operator-secrets`, restart both. | Backups page shows an error until both restarted. |
| `KEYCLOAK_CLIENT_SECRET` | Regenerate in Keycloak (Clients → `den-keycloak` → Credentials), update, restart Den. | Login branding sync fails until restarted; sign-in is not affected. |
| S3 keys | Create a new key, update the secret, restart, then delete the old key. | A restart. |
| Service tokens (`WIKI_SERVICE_TOKEN`, …) | Change on both sides at the same time, restart both. | Calls between the two fail until both restarted. |
| Pairing token | Nothing to rotate: single use, expires after 15 minutes. | |
| Module credential | Pair the module again (Den → Modules → Pair, paste in the module). This adds a new credential, but **Den cannot yet revoke the old one** on its own; only removing the module from Den revokes all of its credentials. | None. |
| `DESK_SECRET_KEY` | No rotation procedure yet. It encrypts the mailbox passwords Desk stores; after a change Desk reports *stored password cannot be decrypted (was DESK_SECRET_KEY changed?)* and every mailbox password must be entered again. Treat it as fixed. | |
| `DEN_LINK_ENCRYPTION_KEY` | Old value into `DEN_LINK_ENCRYPTION_KEY_PREVIOUS`, new value into `DEN_LINK_ENCRYPTION_KEY`, restart; after a minute remove the previous key and restart again. [Details](#den-link-encryption-key). | Two restarts. |
| Google Workspace service-account key | New key in the Google Cloud console, replace the file in the secret manager, restart, delete the old key. [Details](#google-workspace-service-account-key). | A restart. |
| Backup age key | Add the new public key to `BACKUP_AGE_RECIPIENTS` and restart the operator. Only new backups use it; **keep the old secret key** as long as backups made with it are kept. | None. |
| Keycloak bootstrap admin | Create a permanent admin in the master realm, then remove the bootstrap one and its secret. | None. |

## Troubleshooting

**`kubectl get externalsecret` shows `SecretSyncedError`**
: ESO could not read the value. The reason is in the events:

    ```sh
    kubectl describe externalsecret -n conservices-den den-secrets | tail -5
    ```

    | Message contains | Meaning |
    | --- | --- |
    | `permission denied` / `403` | The Vault policy or role does not cover this path or namespace. Check `vault read auth/kubernetes/role/conservices-den`. |
    | `secret not found` / `404` | Wrong `key` (it is the path **without** `data/` for KV v2: `conservices/den/backend`). |
    | `could not get provider client` | The `SecretStore` is broken; see next entry. |

**`kubectl get secretstore -n conservices-den` is not `Valid`**
: ESO cannot log in to Vault. Check that the `external-secrets` service
  account exists in that namespace, that Vault's Kubernetes auth knows your
  cluster (`vault read auth/kubernetes/config`), and that a NetworkPolicy or
  firewall does not block ESO's pods (in their own namespace) from Vault.

**The Secret has the new value but the program still uses the old one**
: Programs read settings only at start. Restart the Deployment
  (`kubectl rollout restart …`) or install Reloader.

**A pod fails with `CreateContainerConfigError: couldn't find key OPERATOR_TOKEN in Secret`**
: The secret manager entry lacks a key the base expects. Compare the keys
  with the [inventory](#inventory) and `kubectl get secret -n conservices-den den-operator-secrets -o jsonpath='{.data}' | jq 'keys'`.

**A module's log says `the stored Den credential cannot be decrypted` after a key change**
: `DEN_LINK_ENCRYPTION_KEY` changed without keeping the old value in
  `DEN_LINK_ENCRYPTION_KEY_PREVIOUS`. Put the old value there and restart;
  if it is lost, pair the module again.

**Backups page shows `unauthorized` after rotating `OPERATOR_TOKEN`**
: Only one side has the new value or was restarted. Update both
  `den-secrets` and `den-operator-secrets`, then restart `den-backend` and
  `den-operator`.

**A module stopped working after rotating its database password, with `password authentication failed`**
: The URL in the secret manager and the role's password differ. Often the
  password contains a character that must be URL-encoded. Set a hex password
  again with step 1 of [the rotation procedure](#rotate-a-secret-with-eso-and-vault).

## Related pages

- [Network policies and isolation](network-policies.md#secrets-per-namespace): which namespace holds which secret.
- [Installing modules with Helm](helm.md): charts take an `existingSecret`.
- [Disaster recovery](disaster-recovery.md#a-leaked-secret): what to do when a secret leaked.
- [Databases, backups and restore](databases-and-backups.md#the-encryption-key): the backup key.
