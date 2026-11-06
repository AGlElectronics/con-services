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

Con Services programs read their settings from **environment variables**
only; they do not support `*_FILE` variables, and the backend images have no
shell, so Docker's `secrets:` (files under `/run/secrets`) cannot feed them
directly. On a production Docker host:

1. Keep one env file per service in a folder outside the Git checkout, for
   example `/etc/conservices/den-backend.env`, owned by root with mode
   `600`:

    ```sh
    sudo install -d -m 700 /etc/conservices
    sudo install -m 600 /dev/null /etc/conservices/den-backend.env
    ```

2. Fill those files from your secret manager when you deploy, instead of
   typing values by hand. For example with Vault:

    ```sh
    vault kv get -format=json secret/conservices/den/backend \
      | jq -r '.data.data | to_entries[] | "\(.key)=\(.value)"' \
      | sudo tee /etc/conservices/den-backend.env > /dev/null
    ```

    SOPS-encrypted env files in Git (`sops -d den-backend.enc.env`) or your
    password manager's CLI work the same way.

3. Reference them with `env_file:` in the compose file, as the
   [hardened example](docker-production.md) does.

The same rules as on Kubernetes apply: never commit the files, give each
service only its own file, and restart the service after changing one
(`docker compose up -d <service>`).

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

## Inventory

**Platform** (manifests in `deploy/kubernetes/base/`):

| Secret (key) | Kubernetes Secret | Namespace | Used by | Notes |
| --- | --- | --- | --- | --- |
| `POSTGRES_PASSWORD` | `postgres-secrets` | `conservices-data` | PostgreSQL | Superuser. Also inside `PG_ADMIN_URL`. In-cluster PostgreSQL only. |
| `DEN_DB_PASSWORD`, `KEYCLOAK_DB_PASSWORD` | `postgres-secrets` | `conservices-data` | PostgreSQL first start | Create the `den` and `keycloak` logins. Only read when the volume is first initialised. |
| `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD` | `minio-secrets` | `conservices-data` | MinIO | In-cluster MinIO only (dev). |
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

**S3 keys in production** come from your managed object storage, AWS S3
(IAM user or role with a per-bucket policy) or Hetzner Object Storage
(S3 credentials per project), which are the recommended choices; see
[Production](production.md#object-storage-use-managed-s3). Create one key
set per bucket so a leaked module key exposes only that module's files. The
`MINIO_ROOT_*` login exists only for the in-cluster trial MinIO.

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
| Finance | `DATABASE_URL` | `conservices-finance` |
| Rally | `DATABASE_URL`, `S3_*` keys, `TELEGRAM_BOT_TOKEN` | `conservices-rally` |

Service tokens are shared by two modules: `WIKI_SERVICE_TOKEN` must match the
token in HR's `OFFBOARD_HOOKS`, `TASKS_SERVICE_TOKEN` the one in
`DEPARTMENT_HOOKS`, and `LEARN_SERVICE_TOKEN` is set on both HR and Learn.

!!! note "Not a secret: Rally's `PUBLIC_API_BUILTIN_KEY`"
    This key is compiled into the public event submission site
    (`VITE_PUBLIC_SCHEDULE_KEY`), so every visitor can see it. Treat it as an
    identifier for rate limiting and revocation, not as a secret.

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
      S3_ACCESS_KEY_ID=change-me S3_SECRET_ACCESS_KEY=change-me
    ```

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
  superuser login.
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
