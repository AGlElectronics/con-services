# Secrets with OpenBao

Every password, token and key Con Services needs lives in **OpenBao**, not
in Git. The **External Secrets Operator** (ESO) reads them from OpenBao and
writes ordinary Kubernetes Secrets, which the pods use. Both are
[prerequisites](prerequisites.md#7-external-secrets-operator-and-openbao):
they already run in your cluster, and running them (installing,
initialising, unsealing, backing up, upgrading) is the job of whoever runs
the cluster. This guide prepares that OpenBao for Con Services, fills it,
and explains how to change secrets later. For the full list of secrets and
the general rules, see [Secrets](../operations/secrets.md).

## Terms used on this page

**OpenBao**
:   An open-source secret manager (a community fork of HashiCorp Vault,
    under the Linux Foundation). The CLI is `bao`; it accepts the same
    commands as `vault`.

**Sealed / unseal**
:   OpenBao encrypts everything it stores. After every start it is
    **sealed**: it has the data but not the key to read it, and answers no
    requests until someone (or an auto-unseal mechanism) **unseals** it.

**KV version 2**
:   The key/value secrets engine, mounted at `kv/` by default. Each entry
    (for example `kv/conservices/stash/s3`) holds several properties and
    keeps old versions.

**ClusterSecretStore / ExternalSecret**
:   ESO objects. The ClusterSecretStore `openbao` says how to reach and log
    in to OpenBao; an ExternalSecret says "copy these properties of this
    entry into that Kubernetes Secret".

## What the template sets up

| Piece | Where | What |
| --- | --- | --- |
| KV v2 engine | OpenBao, `openbao.kvPath` (default `kv/`) | holds every Con Services entry; created by `openbao-configure.sh` |
| Kubernetes auth method | OpenBao, `openbao.auth.mountPath` (default `kubernetes/`) | lets ESO log in with its service account token; created by `openbao-configure.sh` |
| Policy `conservices-external-secrets-read` | OpenBao | read `kv/data/*`, nothing else |
| Role `external-secrets` (`openbao.auth.role`) | OpenBao | binds the policy to ESO's service account `externalSecrets.namespace`/`externalSecrets.serviceAccount` |
| ClusterSecretStore `openbao` | cluster-wide, `charts/secret-store`, Application `cluster-secret-store` (wave -4) | `openbao.server`, KV v2 at `openbao.kvPath`, CA from `openbao.caBundle` |
| ExternalSecrets | next to each Secret they create, in Den's, the modules', Keycloak's, PostgreSQL's and `cert-manager` | one per Kubernetes Secret Con Services needs |

ESO logs in with the **Kubernetes auth method**: it shows OpenBao a token of
its service account, OpenBao checks it with the Kubernetes API and grants
the policy `conservices-external-secrets-read`.

!!! note "One store for the whole cluster"
    The template uses one ClusterSecretStore that can read every entry
    under `kv/`. It is simple and enough when the same people run the whole
    cluster. Who may create ExternalSecrets in which namespace is then the
    boundary, so restrict that with Kubernetes RBAC. For stricter isolation
    use one SecretStore, policy and role per namespace, as described in
    [Secrets](../operations/secrets.md#recommended-external-secrets-operator).

## 1. Check that OpenBao is ready

You need `kubectl` (with access to the cluster), `helm`, `jq` and `bash`
on your computer; the scripts run `bao` inside the OpenBao pods, so you do
not need it locally. Run them from the root of your copy of the template,
with a complete `cluster.yaml` ([Argo CD](argocd.md#2-fill-in-clusteryaml)).

The scripts expect OpenBao to run **in this cluster** as pods
`openbao/openbao-0`, `openbao-1`, ... (the upstream Helm chart with release
name `openbao`). If yours differ, set `OPENBAO_NAMESPACE` and
`OPENBAO_RELEASE` before running them. OpenBao must be initialised and
unsealed:

```sh
kubectl -n openbao exec openbao-0 -- bao status
```

```text
...
Initialized     true
Sealed          false
HA Enabled      true
HA Mode         active
```

Ask whoever runs OpenBao for a **token** that may enable secrets engines
and auth methods and write policies (on a fresh OpenBao, the root token).
You need it once, for step 2; step 3 only needs to write under `kv/`.

## 2. Prepare OpenBao

```sh
BAO_TOKEN=change-me bash bootstrap/scripts/openbao-configure.sh
```

Without `BAO_TOKEN` the script asks for the token (input is hidden).

```text
==> Enabled KV v2 at kv/
==> Enabled Kubernetes auth at kubernetes/
==> Configured Kubernetes auth
==> Wrote policy conservices-external-secrets-read
==> Wrote role external-secrets for external-secrets/external-secrets

Done. OpenBao is ready for External Secrets Operator.

Next: seed the secrets:   bash bootstrap/scripts/openbao-seed.sh
```

The script reads `openbao.kvPath`, `openbao.auth.*` and
`externalSecrets.*` from `cluster.yaml`, then:

1. enables the KV version 2 engine at `openbao.kvPath`, or keeps it if it
   exists (it stops if an existing mount is KV version 1);
2. enables the Kubernetes auth method at `openbao.auth.mountPath` and points
   it at the cluster's API server. OpenBao checks tokens with its own
   service account, which needs the `system:auth-delegator` ClusterRole
   (the upstream chart grants it by default);
3. writes the policy `conservices-external-secrets-read`;
4. writes the role `openbao.auth.role` for ESO's service account.

It is safe to run again: every step checks what is already done. If your
OpenBao already has a `kubernetes/` auth method configured for another
purpose, set another `openbao.auth.mountPath` so the script does not change
its configuration.

## 3. Seed the secrets

`openbao-seed.sh` writes every entry your installation needs. It reads
`cluster.yaml` through the root chart (so it needs `helm`), and only
creates entries for the modules and options you enabled:

- it **generates** the values nobody needs to know (database passwords,
  tokens, Keycloak client secrets);
- it **asks** for the values only you have: S3 keys, the SMTP server, the
  Cloudflare token, the GitHub App and the registry token (the last three
  only when the matching option is on). Input is hidden; an empty answer
  skips the entry so you can run the script again later.

```sh
BAO_TOKEN=change-me bash bootstrap/scripts/openbao-seed.sh
```

```text
==> Modules: stash, hr, rally, finance, learn, wiki, desk, tasks
==> kv/conservices/postgres/superuser written
==> kv/conservices/postgres/roles/den written
...
==> kv/conservices/keycloak/clients written
==> kv/conservices/postgres/backup-s3: S3 access key from your object storage provider
  Access key (empty = skip): AKIAEXAMPLE
  Secret key:
==> kv/conservices/postgres/backup-s3 written
...
==> kv/infra/cloudflare: Cloudflare API token with Zone:DNS:Edit and Zone:Zone:Read for your zone only
  API token (empty = skip):
==> kv/infra/cloudflare written
==> Seeding done. Check with: kubectl get externalsecret -A
```

What it writes (paths shown with the default `openbao.kvPath: kv`):

| Path | Properties | When | Source |
| --- | --- | --- | --- |
| `kv/conservices/postgres/superuser` | `username`, `password` | always | generated |
| `kv/conservices/postgres/roles/<role>` | `password` | `den`, `keycloak`, and one per enabled module (Rally: `events`) | generated |
| `kv/conservices/den/operator-token` | `token` | always | generated |
| `kv/conservices/service-tokens/<module>` | `token` | Learn, Wiki, Tasks if enabled | generated |
| `kv/conservices/desk/secret-key` | `key` | Desk enabled | generated |
| `kv/conservices/keycloak/bootstrap-admin` | `username`, `password` | always | generated |
| `kv/conservices/keycloak/clients` | `den-keycloak`, `hr-provisioner`, `learn-provisioner` | always | generated |
| `kv/conservices/<app>/s3` | `access_key`, `secret_key` | Den, and Stash, Rally, Learn, Wiki, Tasks if enabled | asked ([Data](data.md)) |
| `kv/conservices/den/files-s3`, `kv/conservices/den/backup-s3`, `kv/conservices/postgres/backup-s3` | `access_key`, `secret_key` | always | asked ([Data](data.md)) |
| `kv/conservices/keycloak/smtp` | `host`, `port`, `from`, `username`, `password` | `keycloak.smtp.enabled` (default) | asked |
| `kv/infra/cloudflare` | `api-token` | `acme.dns01.provider: cloudflare` (default) | asked ([DNS and certificates](dns-and-certificates.md#4-give-cert-manager-access-to-your-dns)) |
| `kv/infra/ghcr` | `username`, `token` | `images.pullSecret.enabled` | asked |

Options:

| Option | What it does |
| --- | --- |
| `--no-prompt` | Ask for nothing; list the entries that are still missing |
| `--modules stash,wiki` | Seed for exactly these modules instead of `cluster.yaml`'s `modules.<name>.enabled` |
| `--cluster-file path` | Use another settings file |
| `--rotate` | Replace the rotatable generated values (see [Rotation](#rotate-the-generated-values)) |

Existing entries are never overwritten (except with `--rotate`), so running
the script again is safe; run it after you enable a module, too. No secret
value is printed. The full inventory, with who uses what, is on
[Secrets](../operations/secrets.md#inventory).

When you are done, hand the token back (or revoke it). Day-to-day, nothing
in Con Services needs it: ESO logs in with its own service account.

## How ESO turns an OpenBao entry into a Secret

An ExternalSecret names the entry by its path **under `kv/`, without
`data/`**. Example: the Cloudflare token for cert-manager, from
`charts/letsencrypt`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: cloudflare-api-token
  namespace: cert-manager
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: cloudflare-api-token     # the Kubernetes Secret ESO writes
  data:
    - secretKey: api-token         # key in the Kubernetes Secret
      remoteRef:
        key: infra/cloudflare      # = kv/infra/cloudflare
        property: api-token        # property inside the entry
```

Check all of them:

```sh
kubectl get clustersecretstore openbao
kubectl get externalsecret -A
```

```text
NAME      AGE   STATUS   CAPABILITIES   READY
openbao   12m   Valid    ReadWrite      True
NAMESPACE      NAME                   STORE     REFRESH INTERVAL   STATUS         READY
cert-manager   cloudflare-api-token   openbao   1h                 SecretSynced   True
...
```

## Change a secret

1. Write the new value as a person with a token that may write the entry:

    ```sh
    kubectl -n openbao exec -it openbao-0 -- sh
    export BAO_TOKEN=...          # paste, then:
    bao kv patch kv/conservices/stash/s3 secret_key=-    # reads the value from stdin; paste it, Enter, Ctrl-D
    exit
    ```

    `kv patch` changes one property and keeps the others; every write is
    a new version (`bao kv get -version=1 kv/conservices/stash/s3` shows an
    old one, `bao kv rollback -version=1 kv/conservices/stash/s3` restores
    it).

2. Make ESO fetch it now instead of within `refreshInterval` (1 hour):

    ```sh
    kubectl -n conservices-stash annotate externalsecret stash-secrets force-sync=$(date +%s) --overwrite
    ```

3. Restart the pods that read the Secret only at start (most Con Services
   programs do):

    ```sh
    kubectl -n conservices-stash rollout restart deploy/stash-backend
    ```

[Rotating secrets](../operations/secrets.md#rotating-secrets) gives each
secret's procedure.

### Rotate the generated values

```sh
BAO_TOKEN=change-me bash bootstrap/scripts/openbao-seed.sh --rotate
```

replaces the database role and superuser passwords (CloudNativePG changes
them in PostgreSQL), the Den operator token and the service tokens. Then
force-sync the ExternalSecrets (or wait an hour) and restart the module
Deployments. It never rotates `desk/secret-key` (it encrypts stored mailbox
passwords) or the Keycloak entries (Keycloak keeps its own copy after the
first import; regenerate a client secret in the Keycloak admin console,
then store it with `bao kv patch`).

## What Con Services expects from whoever runs OpenBao

Con Services only reads from OpenBao; it does not run, unseal or back it
up. How OpenBao is run is up to you, but plan for these:

- **Sealed pods.** While OpenBao is sealed, ESO cannot refresh secrets.
  Existing Kubernetes Secrets keep working, so running pods are not
  affected, but new secrets and changed values do not arrive. Unseal it
  after restarts, or use an auto-unseal seal
  ([OpenBao seal documentation](https://openbao.org/docs/configuration/seal/)).
- **Backups.** Everything in `kv/conservices/` and `kv/infra/` is needed to
  rebuild an installation; the generated values cannot be recreated (for
  example `desk/secret-key`, which encrypts stored mailbox passwords). Back
  OpenBao up off the cluster, for example with Raft snapshots.
- **High availability.** With one OpenBao pod, a node failure stops secret
  refreshes until it is back. Three pods with Raft storage survive one.

## Troubleshooting

**`openbao-configure.sh` says `pod openbao/openbao-0 not found`**
:   OpenBao runs under another namespace or release name. Set them, for
    example `OPENBAO_NAMESPACE=vault OPENBAO_RELEASE=bao`, and run it again.

**`openbao-configure.sh` or `openbao-seed.sh` says `token rejected`**
:   OpenBao is sealed, or the token is invalid or lacks the rights. Check
    `kubectl -n openbao exec openbao-0 -- bao status` and ask for a new
    token.

**`openbao-configure.sh` says `kv/ exists but is KV version 1`**
:   Your OpenBao already has a version 1 engine at that path. Set another
    `openbao.kvPath` in `cluster.yaml` (for example `conservices-kv`), push,
    and run the script again.

**`openbao-seed.sh` says `the root chart rejected cluster.yaml`**
:   The script renders the root chart to learn what to seed; the message
    above it says what is wrong. Run it from the root of your copy, with a
    complete `cluster.yaml` ([Argo CD](argocd.md#2-fill-in-clusteryaml)).

**`kubectl get clustersecretstore openbao` is not `Valid`, message `permission denied` or `403`**
:   The Kubernetes auth role or policy is missing or does not match ESO's
    service account. Check `externalSecrets.namespace` and
    `externalSecrets.serviceAccount` in `cluster.yaml`, then run
    `openbao-configure.sh` again (it rewrites both). If OpenBao's log shows
    `service account lookup failed`, its own service account lacks the
    `system:auth-delegator` ClusterRole.

**ClusterSecretStore message `x509: certificate signed by unknown authority`**
:   ESO does not trust OpenBao's certificate. Put the CA that signed it in
    the ConfigMap or Secret named by `openbao.caBundle` (default: ConfigMap
    `openbao-ca`, key `ca.crt`, in ESO's namespace), or set
    `openbao.caBundle.name: ""` if OpenBao has a publicly trusted
    certificate.

**ClusterSecretStore message `connection refused` or `i/o timeout`**
:   `openbao.server` is wrong, or a network policy blocks ESO from OpenBao.
    Allow ESO's namespace to reach OpenBao on port 8200, and OpenBao to
    reach the Kubernetes API (for the token check).

**An ExternalSecret shows `SecretSyncedError` with `secret not found`**
:   The entry was never seeded (run `openbao-seed.sh` again; with
    `--no-prompt` it lists what is missing), or a custom ExternalSecret uses
    the wrong `key`: it is the path under `kv/` without `data/`
    (`infra/cloudflare`, not `kv/data/infra/cloudflare`).

**ESO errors come and go after an OpenBao pod restart**
:   `openbao.server` points at a Service that also routes to sealed pods.
    Use the Service of the active node (`openbao-active` with the upstream
    chart), or unseal the pod.

Next: [Data](data.md).
