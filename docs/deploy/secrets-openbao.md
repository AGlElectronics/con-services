# Secrets with OpenBao

Every password, token and key the cluster needs lives in **OpenBao**, not
in Git. The **External Secrets Operator** (ESO) reads them from OpenBao and
writes ordinary Kubernetes Secrets, which the pods use. This guide
initialises OpenBao, fills it, and explains the daily operations: unsealing
after restarts, changing secrets, backups and recovery. For the full list
of secrets and the general rules, see [Secrets](../operations/secrets.md).

## Terms used on this page

**OpenBao**
:   An open-source secret manager (a community fork of HashiCorp Vault,
    under the Linux Foundation). The CLI is `bao`; it accepts the same
    commands as `vault`.

**Raft**
:   OpenBao's built-in replicated storage. Each OpenBao pod keeps a full
    copy; one is the **active** (leader) node, the others are standbys.
    With 3 pods it keeps working while 2 are up.

**Sealed / unseal**
:   OpenBao encrypts everything it stores. After every start it is
    **sealed**: it has the data but not the key to read it. **Unsealing**
    gives it that key. With the default **Shamir** seal, the key is split
    into 5 **unseal keys**; any 3 of them unseal it.

**Root token**
:   The all-powerful OpenBao login created at initialisation. Use it for
    setup, then revoke it.

**KV version 2**
:   The key/value secrets engine, mounted at `kv/`. Each entry (for example
    `kv/conservices/stash/s3`) holds several properties and keeps old
    versions.

**ClusterSecretStore / ExternalSecret**
:   ESO objects. The ClusterSecretStore `openbao` says how to reach and log
    in to OpenBao; an ExternalSecret says "copy these properties of this
    entry into that Kubernetes Secret".

## How it is set up

| Piece | Where | What |
| --- | --- | --- |
| OpenBao 2.7.2 | namespace `openbao`, chart `openbao` 0.30.7, Application `openbao` (wave -5) | `openbao.replicas` pods (default 3), Raft storage, audit log on its own volume, one pod per node, PodDisruptionBudget |
| Volumes | `openbao.storage` in `cluster.yaml` | `longhorn-single` with `storage.longhornSingle.enabled` (Raft replicates by itself), else the cluster default |
| TLS | Certificate `openbao-tls` from the [internal CA](../operations/internal-tls.md) (`charts/openbao-extras`) | on the API and between the Raft peers |
| UI | `https://bao.<domain>` on the internal Gateway (`adminRoutes.openbao`) | re-encrypted to OpenBao, verified against the internal CA |
| ESO 2.14.0 | namespace `external-secrets` | 2 replicas of controller, webhook and cert-controller |
| ClusterSecretStore `openbao` | cluster-wide (`components/cluster-secret-store`) | `https://openbao-active.openbao.svc:8200`, KV v2 at `kv`, Kubernetes auth role `external-secrets` |

ESO logs in with the **Kubernetes auth method**: it shows OpenBao a token of
its service account `external-secrets/external-secrets`, OpenBao checks it
with the Kubernetes API and grants the policy `external-secrets-read`
(read `kv/data/*`).

!!! note "One store for the whole cluster"
    The template uses one ClusterSecretStore that can read every entry
    under `kv/`. It is simple and enough when the same people run the whole
    cluster. Who may create ExternalSecrets in which namespace is then the
    boundary, so restrict that with Kubernetes RBAC. For stricter isolation
    use one SecretStore, policy and role per namespace, as described in
    [Secrets](../operations/secrets.md#recommended-external-secrets-operator).

## 1. Wait for the OpenBao pods

During the first sync ([Argo CD](argocd.md), wave -5) the `openbao`
Application stops at `Progressing`:

```sh
kubectl -n openbao get pods
```

```text
NAME        READY   STATUS    RESTARTS   AGE
openbao-0   0/1     Running   0          2m
```

`0/1 Running` is right: OpenBao is uninitialised and sealed. The pods
start one after the other, so `openbao-1` and `openbao-2` appear only after
`openbao-0` is unsealed.

## 2. Initialise and unseal

You need `kubectl` (with access to the cluster), `jq` and `bash` on your
computer; the scripts run `bao` inside the pods, so you do not need it
locally. Run them from the root of your copy of the template.

1. Pick a place for the init file **outside** any Git checkout, on an
   encrypted disk, and run:

    ```sh
    INIT_FILE=$HOME/openbao-init.json bash bootstrap/scripts/openbao-init.sh
    ```

    ```text
    ==> Initialising (5 key shares, threshold 3) -> /home/you/openbao-init.json
    ==> Init done. Keys and root token are in /home/you/openbao-init.json (not shown).
    ==> Unsealing openbao-0
    ==> Waiting for openbao-1 to join the Raft cluster
    ==> Unsealing openbao-1
    ==> Waiting for openbao-2 to join the Raft cluster
    ==> Unsealing openbao-2
    ==> Enabled KV v2 at kv/
    ==> Audit log active (declared in the server configuration)
    ==> Enabled Kubernetes auth
    ==> Configured Kubernetes auth
    ==> Wrote policy external-secrets-read
    ==> Wrote role external-secrets
    ```

    The script initialises OpenBao with 5 unseal keys (3 needed), writes
    them and the root token **only** into `$INIT_FILE` (mode 600), unseals
    every pod (it reads the number of pods from the StatefulSet), enables
    KV v2 at `kv/` and Kubernetes auth, and creates the policy and role for
    ESO. It is safe to run again: every step checks what is already done.

2. Check:

    ```sh
    kubectl -n openbao get pods
    kubectl -n openbao exec openbao-0 -- bao status
    ```

    ```text
    NAME        READY   STATUS    RESTARTS   AGE
    openbao-0   1/1     Running   0          6m
    openbao-1   1/1     Running   0          3m
    openbao-2   1/1     Running   0          2m
    ...
    Sealed          false
    HA Enabled      true
    HA Mode         active
    ```

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
INIT_FILE=$HOME/openbao-init.json bash bootstrap/scripts/openbao-seed.sh
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

What it writes:

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
| `kv/infra/github-arc` | `github_app_id`, `github_app_installation_id`, `github_app_private_key` | `arc.enabled` | asked ([Self-hosted CI runners](self-hosted-runners.md)) |
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

## 4. Put the init file away and revoke the root token

1. Split the 5 unseal keys between people you trust (each person keeps one
   or two, in a password manager or on paper in a safe), so no single
   person can unseal alone and losing one key is not a disaster. Keep the
   root token only until setup is finished.
2. Revoke the root token when you no longer need it:

    ```sh
    kubectl -n openbao exec -it openbao-0 -- sh -c 'BAO_TOKEN=$(cat) bao token revoke -self'
    ```

    (paste the root token, then press Ctrl-D). When you need root access
    again, create a new root token with 3 unseal keys:
    `bao operator generate-root` ([docs](https://openbao.org/docs/commands/operator/generate-root/)).
3. Delete `$INIT_FILE` from the computer: `shred -u $HOME/openbao-init.json`.

!!! danger "Losing the unseal keys loses every secret"
    Without 3 of the 5 unseal keys, nobody can ever unseal OpenBao again,
    not even with a Raft snapshot. Store them offline, in more than one
    place.

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
kubectl get externalsecret -A
```

```text
NAMESPACE      NAME                   STORE     REFRESH INTERVAL   STATUS         READY
cert-manager   cloudflare-api-token   openbao   1h                 SecretSynced   True
...
```

## Unseal after a restart

**Every OpenBao pod that restarts comes back sealed**: after a node reboot,
an upgrade, an eviction, or a power cut. A sealed pod is not Ready and
serves nothing. While one pod is sealed, the others keep working; when all
are sealed, ESO cannot refresh secrets (existing Kubernetes Secrets keep
working) and no new secret can be read.

Runbook:

1. See which pods are sealed:

    ```sh
    kubectl -n openbao get pods
    ```

    `0/1` = sealed (or still starting).

2. Unseal, with 3 key holders at the keyboard (keys are not echoed):

    ```sh
    bash bootstrap/scripts/openbao-unseal.sh
    ```

    ```text
    ==> openbao-0: unsealed
    Unseal key 1 of 3:
    Unseal key 2 of 3:
    Unseal key 3 of 3:
    ==> openbao-1: unsealing
    ==> openbao-1: unsealed
    ==> openbao-2: unsealed
    ```

3. Check that `kubectl -n openbao get pods` shows `1/1` for every pod, and
   `kubectl get clustersecretstore openbao` shows `Valid`.

**After all pods restarted** (whole cluster down): after `openbao-0` is
unsealed the StatefulSet starts the next pod, so run the script again until
all pods are unsealed.

Planned maintenance: drain one node at a time and unseal its OpenBao pod
before draining the next ([High availability](high-availability.md)).

### Auto-unseal: the alternatives

Manual unseal keeps the keys off the cluster, which is the point: someone
who steals the disks or a backup of the cluster cannot read the secrets.
The price is that a person must act after every restart. OpenBao can unseal
itself with a key held somewhere else (**auto-unseal**), configured with a
`seal` stanza in the server configuration (`openbao.values` in
`cluster.yaml`, see the
[chart's values](https://github.com/openbao/openbao-helm/blob/main/charts/openbao/values.yaml)):

| Seal | Where the key lives | Trade-off |
| --- | --- | --- |
| `shamir` (default here) | 5 key shares held by people | Most secure; manual unseal after every restart. |
| `transit` | Another OpenBao or Vault (its transit engine) | Good if you already run a second, independently secured OpenBao, ideally on other hardware. That one then needs unsealing. |
| `awskms`, `gcpckms`, `azurekeyvault`, `ocikms` and other cloud KMS | A cloud KMS | Unattended restarts; trusts the cloud provider and needs cloud credentials in the cluster. |
| `pkcs11`, `kmip` | A hardware security module or KMIP server | Strong, needs the hardware. |
| `static` | A 32-byte key given to OpenBao as a file or environment variable | Unattended, but the key sits next to the data: anyone with the Kubernetes Secret holding it, or a cluster backup, can decrypt everything. **Not recommended.** |

Switching from Shamir to an auto-unseal seal is a **seal migration**
(`bao operator unseal -migrate`), see
[Seal migration](https://openbao.org/docs/concepts/seal/#seal-migration).
With auto-unseal, `bao operator init` produces **recovery keys** instead of
unseal keys; keep them offline the same way.

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
INIT_FILE=$HOME/openbao-init.json bash bootstrap/scripts/openbao-seed.sh --rotate
```

replaces the database role and superuser passwords (CloudNativePG changes
them in PostgreSQL), the Den operator token and the service tokens. Then
force-sync the ExternalSecrets (or wait an hour) and restart the module
Deployments. It never rotates `desk/secret-key` (it encrypts stored mailbox
passwords) or the Keycloak entries (Keycloak keeps its own copy after the
first import; regenerate a client secret in the Keycloak admin console,
then store it with `bao kv patch`).

### OpenBao's own certificate and keys

`openbao-tls` (valid one year) is renewed by cert-manager 30 days before
expiry. OpenBao reads it only at start or on `SIGHUP`, and a restart seals
the pod, so reload it in place after a renewal:

```sh
for i in 0 1 2; do kubectl -n openbao exec openbao-$i -- sh -c 'kill -HUP $(pidof bao)'; done
```

Unseal keys can be replaced with `bao operator rekey` (needs 3 current
keys) when a key holder leaves.

## Back up OpenBao

The volumes keep the Raft data on the nodes; that does not protect against
losing the cluster or a mistake. Take Raft snapshots and copy them off the
cluster:

```sh
kubectl -n openbao exec -it openbao-0 -- sh -c \
  'BAO_TOKEN=$(cat) bao operator raft snapshot save /tmp/bao.snap'   # paste a token, Ctrl-D
kubectl -n openbao cp openbao-0:/tmp/bao.snap ./openbao-$(date +%F).snap
kubectl -n openbao exec openbao-0 -- rm /tmp/bao.snap
```

The snapshot is encrypted with OpenBao's keys: it is useless without the
unseal keys, and safe to store at your backup provider. Restore into a
running, unsealed OpenBao with `bao operator raft snapshot restore`; it
needs the unseal keys that were valid when the snapshot was taken.
Automate it with a CronJob and a token limited to
`sys/storage/raft/snapshot` (policy `path "sys/storage/raft/snapshot" { capabilities = ["read"] }`).

## Troubleshooting

**`openbao-init.sh` says `cannot read 'bao status' from openbao-0`**
:   The pod is not running yet (`kubectl -n openbao describe pod openbao-0`).
    Common causes: its volume cannot be created (check the StorageClass and
    `kubectl -n openbao get pvc`), or the Certificate `openbao-tls` is not
    issued yet (`kubectl -n openbao get certificate`).

**`openbao-seed.sh` says `the root chart rejected cluster.yaml`**
:   The script renders the root chart to learn what to seed; the message
    above it says what is wrong. Run it from the root of your copy, with a
    complete `cluster.yaml` ([Argo CD](argocd.md#2-fill-in-clusteryaml)).

**`openbao-seed.sh` says `token rejected`**
:   OpenBao is sealed, or `BAO_TOKEN` / the root token in `INIT_FILE` is
    revoked. Unseal, or create a token with `bao operator generate-root`.

**`openbao-1` never appears**
:   The StatefulSet starts pods one by one and waits for `openbao-0` to be
    Ready, which needs it unsealed. Unseal `openbao-0` first.

**A pod stays sealed after unsealing with 3 keys, logs show `failed to join raft cluster`**
:   It cannot reach the leader over TLS. Check the certificate names
    (`kubectl -n openbao get secret openbao-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -ext subjectAltName`
    must list `*.openbao-internal`) and that the pods resolve
    `openbao-0.openbao-internal`.

**`kubectl get clustersecretstore openbao` is not `Valid`, message `permission denied` or `403`**
:   The Kubernetes auth role or policy is missing or does not match the
    service account. Run `openbao-init.sh` again (it rewrites both).

**ClusterSecretStore message `x509: certificate signed by unknown authority`**
:   The internal CA bundle is missing in the `external-secrets` namespace:
    `kubectl -n external-secrets get cm conservices-internal-ca`. The
    namespace needs the label `app.kubernetes.io/part-of=conservices` (set by
    the `external-secrets` Application) and trust-manager must be running.

**An ExternalSecret shows `SecretSyncedError` with `secret not found`**
:   The entry was never seeded (run `openbao-seed.sh` again; with
    `--no-prompt` it lists what is missing), or a custom ExternalSecret uses
    the wrong `key`: it is the path under `kv/` without `data/`
    (`infra/cloudflare`, not `kv/data/infra/cloudflare`).

**ESO errors come and go after a pod restart**
:   One OpenBao pod is sealed. Unseal it.

**You lost the init file but have 3 unseal keys**
:   Unseal works as usual. For a new root token use
    `bao operator generate-root`.

Next: [Data](data.md).
