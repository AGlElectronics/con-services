# Secrets with OpenBao

Every password, token and key Con Services needs lives in **OpenBao**, not
in Git. The **External Secrets Operator** (ESO) reads them from OpenBao and
writes ordinary Kubernetes Secrets, which the pods use. Both are
[prerequisites](prerequisites.md#7-external-secrets-operator-and-openbao):
they already run in your cluster, and running them (installing,
initialising, unsealing, backing up, upgrading) is the job of whoever runs
the cluster.

This page explains how Con Services' entries are organised in OpenBao, what
the template does there, the one step the OpenBao administrator does by
hand, which secrets you enter yourself, and every key with the kind of value
it holds. For the general rules, see [Secrets](../operations/secrets.md).

## Terms used on this page

**OpenBao**
:   An open-source secret manager (a community fork of HashiCorp Vault,
    under the Linux Foundation). The CLI is `bao`; it accepts the same
    commands as `vault`.

**Sealed / unseal**
:   OpenBao encrypts everything it stores. After every start it is
    **sealed**: it has the data but not the key to read it, and answers no
    requests until someone (or an auto-unseal mechanism) **unseals** it.

**Mount / KV version 2**
:   OpenBao stores secrets in **secrets engines**, each **mounted** at a
    path at the root of OpenBao (for example `conservices/`, or `kv/` for
    something else). Con Services uses its own key/value engine, version 2,
    mounted at `conservices/` (`openbao.kvPath` in `cluster.yaml`). Each
    **entry** (for example `conservices/modules/stash/s3`) holds several
    **keys** (OpenBao calls them properties, for example `access_key` and
    `secret_key`) and keeps old versions.

**Policy / role**
:   A **policy** lists the paths a token may use and how (read, create,
    ...). A **role** of the Kubernetes auth method gives a policy to one
    Kubernetes service account: a pod running as that account can log in to
    OpenBao with its service account token and gets that policy.

**ClusterSecretStore / ExternalSecret / PushSecret**
:   ESO objects. The ClusterSecretStore `openbao` says how to reach and log
    in to OpenBao. An ExternalSecret copies keys of an OpenBao entry into a
    Kubernetes Secret. A PushSecret goes the other way: here it writes a
    freshly generated random value into OpenBao, but only if that key does
    not exist yet.

## How the entries are organised

Con Services has a mount of its own, `conservices/`, next to whatever else
your OpenBao holds. Inside it there are two folders:

- `modules/` for Den and the modules: one folder per application
  (`modules/den/`, `modules/stash/`, ...) with its S3 key and its own
  tokens.
- `infra/` for shared and platform entries: PostgreSQL, Keycloak, the
  Cloudflare token and the registry login.

```text
conservices/                       KV version 2 mount (openbao.kvPath)
├── modules/
│   ├── den/
│   │   ├── s3                     you        access_key, secret_key
│   │   ├── files-s3               you        access_key, secret_key (read only)
│   │   ├── backup-s3              you        access_key, secret_key
│   │   └── operator-token         generated  token
│   ├── stash/s3                   you        (rally, learn, wiki, tasks alike)
│   ├── learn/service-token        generated  token (wiki, tasks alike)
│   └── desk/secret-key            generated  key
└── infra/
    ├── postgres/
    │   ├── superuser              generated  password
    │   ├── roles/<role>           generated  password
    │   └── backup-s3              you        access_key, secret_key
    ├── keycloak/
    │   ├── bootstrap-admin        generated  password
    │   ├── clients                generated  den-keycloak, hr-provisioner, learn-provisioner
    │   └── smtp                   you        host, port, from, username, password
    ├── cloudflare                 you        api-token
    └── ghcr                       you        username, token
```

An ExternalSecret names an entry by its path **inside** the mount, for
example `modules/stash/s3` or `infra/cloudflare`. Another mount name is
possible (`openbao.kvPath`); the paths inside it stay the same.

## What happens when you use the template

This is the default (`openbao.setup.enabled: true` in `cluster.yaml`):

1. **Once, by hand: the OpenBao administrator** runs
   `bootstrap/scripts/openbao-configure.sh` (or `.ps1` on Windows, or the
   commands it runs, shown in
   [step 2](#2-the-administrators-one-time-step)). It creates two
   policies and one narrow role for the template's setup Job. This is the
   only moment someone needs an OpenBao admin token. Nothing in the cluster
   ever holds that token.
2. **Argo CD stops at the Application `openbao-setup`.** It is the only
   Application without automatic sync. Nothing after it starts (the waves
   after `-5` wait) until you have looked at what it will do and pressed
   **Sync**.
3. **The setup Job runs** when you press Sync. It logs in to OpenBao as its
   own service account and does exactly two things: it enables the KV
   engine at `conservices/` (if missing) and writes the role ESO logs in
   with. OpenBao refuses anything else, because the policy from step 1
   allows only these two writes, with the values from your `cluster.yaml`.
4. **ESO creates the random values** (database passwords, tokens, Keycloak
   client secrets) in OpenBao through PushSecrets. Existing values are
   never replaced.
5. **You enter the values only you have** (S3 keys, SMTP, Cloudflare
   token) in OpenBao. Applications that need one of them stay `Degraded`
   until it is there, then continue on their own.

From then on Argo CD and ESO run everything from `cluster.yaml`. If you do
not want the template to touch OpenBao at all, set
`openbao.setup.enabled: false` and do step 3 yourself; see
[Without the setup Job](#without-the-setup-job).

## What the template sets up

| Piece | Where | Created by | What |
| --- | --- | --- | --- |
| Kubernetes auth method | OpenBao, `openbao.auth.mountPath` (default `kubernetes/`) | administrator (step 2) | lets pods log in with their service account token |
| Policy `conservices-external-secrets` | OpenBao | administrator (step 2) | read every entry in `conservices/`; create and update entries below `modules/`, `infra/postgres/` and `infra/keycloak/` (the generated ones). `infra/cloudflare` and `infra/ghcr` stay read-only for ESO |
| Policy `conservices-setup` | OpenBao | administrator (step 2) | enable `conservices/`; write the role `external-secrets` with fixed values |
| Role `conservices-setup` (`openbao.setup.role`) | OpenBao | administrator (step 2) | gives `conservices-setup` to the setup Job's service account, tokens valid 10 minutes |
| KV v2 engine | OpenBao, `openbao.kvPath` (default `conservices/`) | setup Job | holds every Con Services entry |
| Role `external-secrets` (`openbao.auth.role`) | OpenBao | setup Job | gives `conservices-external-secrets` to ESO's service account |
| Application `openbao-setup` (wave -5, manual sync) | `charts/openbao-setup`, in ESO's namespace | Argo CD | ServiceAccount, the Job, its script (ConfigMap) and a NetworkPolicy |
| ClusterSecretStore `openbao` | cluster-wide, `charts/secret-store`, Application `cluster-secret-store` (wave -4) | Argo CD | `openbao.server`, KV v2 at `openbao.kvPath`, CA from `openbao.caBundle` |
| Generator `conservices-random` and the PushSecrets `generated-*` | ESO's namespace, same Application | Argo CD | create the random values (see [Every secret](#every-secret-keys-and-values)) |
| ExternalSecrets | next to each Secret they create, in Den's, the modules', Keycloak's, PostgreSQL's and `cert-manager` | Argo CD | one per Kubernetes Secret Con Services needs |

ESO logs in with the **Kubernetes auth method**: it shows OpenBao a token of
its service account, OpenBao checks it with the Kubernetes API and grants
the policy `conservices-external-secrets`.

!!! note "One store for the whole cluster"
    The template uses one ClusterSecretStore that can read every entry
    in `conservices/`, and ESO may create entries below `modules/`,
    `infra/postgres/` and `infra/keycloak/` (for the random values). It is
    simple and enough when the same people run the whole cluster. Who may
    create ExternalSecrets and PushSecrets in which namespace is then the
    boundary, so restrict that with Kubernetes RBAC. For stricter isolation
    use one SecretStore, policy and role per namespace, as described in
    [Secrets](../operations/secrets.md#recommended-external-secrets-operator).

## 1. Check that OpenBao is ready

OpenBao must be initialised and unsealed:

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

ESO must reach OpenBao (`openbao.server`, default
`https://openbao-active.openbao.svc:8200`) and trust its certificate
(`openbao.caBundle`, default ConfigMap `openbao-ca` in ESO's namespace). If
OpenBao's namespace has network policies, they must admit ESO's pods and
the setup Job (label `app.kubernetes.io/name: conservices-openbao-setup`
in ESO's namespace) on port 8200; see
[Network policies](../operations/network-policies.md).

## 2. The administrator's one-time step

Whoever administers OpenBao does this once per cluster, with a token that
may manage auth methods and policies (on a fresh OpenBao, the root token).
There are two ways; they do the same thing.

**With the script.** It runs `bao` inside the OpenBao pod, so `bao` is not
needed locally. Run it from the root of your copy of the template, with a
complete `cluster.yaml` ([Argo CD](argocd.md#2-fill-in-clusteryaml)).

=== "Linux / macOS"

    Needs `bash`, `kubectl`, `jq` and `helm`.

    ```sh
    bash bootstrap/scripts/openbao-configure.sh
    ```

=== "Windows (PowerShell)"

    Needs `kubectl` and `helm` (no `jq`, no Git Bash). Works in Windows
    PowerShell 5.1 and PowerShell 7.

    ```powershell
    .\bootstrap\scripts\openbao-configure.ps1
    ```

    If PowerShell refuses to run scripts, allow it for this window only:
    `Set-ExecutionPolicy -Scope Process Bypass`.

It asks for the token (input is hidden), or reads `BAO_TOKEN`, or the root
token from an init file (`INIT_FILE=$HOME/openbao-init.json`; in
PowerShell `$env:INIT_FILE = "$HOME\openbao-init.json"`). Output:

```text
== 1. Kubernetes auth method ==
  ok    Kubernetes auth kubernetes/ already enabled
  ok    Configured Kubernetes auth

== 2. Policy conservices-external-secrets ==
  ok    Wrote policy conservices-external-secrets (read conservices/*, write modules/*, infra/postgres/*, infra/keycloak/*)

== 3. Setup Job: policy conservices-setup and role conservices-setup ==
  ok    Wrote policy conservices-setup
  ok    Wrote role conservices-setup for external-secrets/conservices-openbao-setup

Done. Next: Argo CD stops at the Application "openbao-setup". Review its
diff, then press Sync (or: argocd app sync openbao-setup). It enables
conservices/ and writes the role external-secrets.
```

The script expects OpenBao to run as pods `openbao/openbao-0`, ... (the
upstream Helm chart with release name `openbao`). If yours differ, set
`OPENBAO_NAMESPACE` and `OPENBAO_RELEASE`. It is safe to run again.

**By hand.** The same, with the defaults of `cluster.yaml` (change the
names if you changed `openbao.*` or `externalSecrets.*`), in a shell with
`bao` logged in as administrator:

```sh
# Skip these two lines if the Kubernetes auth method already exists.
bao auth enable kubernetes
bao write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc:443

bao policy write conservices-external-secrets - <<'EOF'
path "conservices/data/*"                  { capabilities = ["read"] }
path "conservices/metadata/*"              { capabilities = ["read"] }
path "conservices/data/modules/*"          { capabilities = ["read", "create", "update"] }
path "conservices/metadata/modules/*"      { capabilities = ["read", "create", "update"] }
path "conservices/data/infra/postgres/*"     { capabilities = ["read", "create", "update"] }
path "conservices/metadata/infra/postgres/*" { capabilities = ["read", "create", "update"] }
path "conservices/data/infra/keycloak/*"     { capabilities = ["read", "create", "update"] }
path "conservices/metadata/infra/keycloak/*" { capabilities = ["read", "create", "update"] }
EOF

bao policy write conservices-setup - <<'EOF'
path "sys/mounts/conservices" { capabilities = ["create", "read", "update"] }
path "auth/kubernetes/role/external-secrets" {
  capabilities = ["create", "read", "update"]
  allowed_parameters = {
    "bound_service_account_names"      = ["external-secrets"]
    "bound_service_account_namespaces" = ["external-secrets"]
    "token_policies"                   = ["conservices-external-secrets"]
    "token_ttl"                        = ["1h"]
  }
}
EOF

bao write auth/kubernetes/role/conservices-setup \
  bound_service_account_names=conservices-openbao-setup \
  bound_service_account_namespaces=external-secrets \
  token_policies=conservices-setup token_ttl=10m token_max_ttl=10m
```

What the setup Job can and cannot do with this:

- It **can** enable the KV engine at `conservices/` and write the role
  `external-secrets` with exactly the values above.
- It **cannot** read any secret, delete the engine, write policies, bind
  the role to another service account or give it another policy. OpenBao
  rejects those requests (`allowed_parameters` pins every value).

OpenBao checks service account tokens with its own service account, which
needs the `system:auth-delegator` ClusterRole (the upstream chart grants it).
If your OpenBao already has a `kubernetes/` auth method for another
purpose, it can be shared: the script only sets `kubernetes_host`.

When you are done, hand the admin token back (or revoke it). Nothing in Con
Services needs it again.

## 3. Review and sync `openbao-setup`

After the root Application is applied ([Argo CD](argocd.md)), Argo CD
installs the first waves and then waits at `openbao-setup`:

```sh
kubectl get applications -n argocd openbao-setup
```

```text
NAME            SYNC STATUS   HEALTH STATUS
openbao-setup   OutOfSync     Missing
```

Review what it will create, in the Argo CD web interface (Application
`openbao-setup`, **App Diff**) or with the CLI:

```sh
argocd app diff openbao-setup
```

You should see four objects in ESO's namespace: the ServiceAccount
`conservices-openbao-setup`, the ConfigMap `conservices-openbao-setup` with
the script `setup.sh`, the Job `conservices-openbao-setup` and its
NetworkPolicy. The script is short; it is the same as
`charts/openbao-setup/files/setup.sh` in your copy.

Then press **Sync** (or `argocd app sync openbao-setup`) and read the Job's
log:

```sh
kubectl -n external-secrets logs job/conservices-openbao-setup
```

```text
==> Logged in to https://openbao-active.openbao.svc:8200 as role conservices-setup
==> Enabled KV v2 at conservices/
==> Wrote role external-secrets for external-secrets/external-secrets (policy conservices-external-secrets)
==> Done.
```

The Application turns `Healthy` and Argo CD continues with the next waves.
The finished Job stays, so its log remains as a record; OpenBao's audit log
(if enabled) has every request. Pressing Sync again runs the Job again;
that is safe.

## 4. Enter your provider credentials

ESO creates the random values on its own right after step 3. The values
only you have must be entered by a person. Which ones depends on
`cluster.yaml`; [Every secret](#every-secret-keys-and-values) lists them
all.

!!! warning "Every S3 entry gets its own access key, limited to its bucket"
    Create one S3 access key **per entry** at your provider and allow it
    only what that entry needs: read and write on its own bucket (for
    `modules/den/files-s3`: read only on the module buckets). Do this even
    if your provider would let one key reach every bucket. A leaked or
    stolen key then exposes one bucket, not all of them, and you can rotate
    it without touching the others. The seed script warns (it does not
    stop) when two entries use the same access key. How to create the
    buckets and keys: [Data](data.md).

Three ways to enter the values, use whichever you like:

**OpenBao web UI.** Open the `conservices` engine, **Create secret**, path
for example `modules/stash/s3`, and add the keys `access_key` and
`secret_key`.

**`bao` in the OpenBao pod.** A value given as `-` is read from standard
input, so the secret key does not appear on the command line:

```sh
kubectl -n openbao exec -it openbao-0 -- sh
export BAO_TOKEN=change-me        # a token that may write conservices/
bao kv put conservices/modules/stash/s3 access_key=change-me secret_key=-
# paste the secret key, Enter, then Ctrl-D
exit
```

**The helper script.** It asks for every entry the enabled modules and
options need, in order, and skips existing ones (an empty answer skips an
entry for now; the summary lists it in red with the Application that stays
`Degraded`). Hidden answers are checked before they are stored: a value
with a backslash, a space or a control character, or one that cannot be a
token of that kind (for example a Cloudflare token with other characters
than letters, digits, `_` and `-`, or far too short), is refused and asked
for again, up to three times. Unusual but possible values (a Cloudflare
token that is not 40 or 53 characters long) only get a warning. After each hidden answer it shows only its length and
its first and last four characters, so you can see whether the paste
arrived. Existing entries are checked the same way.

=== "Linux / macOS"

    ```sh
    bash bootstrap/scripts/openbao-seed.sh             # asks
    bash bootstrap/scripts/openbao-seed.sh --no-prompt # only lists what is missing
    bash bootstrap/scripts/openbao-seed.sh --overwrite conservices/infra/cloudflare
    ```

=== "Windows (PowerShell)"

    ```powershell
    .\bootstrap\scripts\openbao-seed.ps1              # asks
    .\bootstrap\scripts\openbao-seed.ps1 -NoPrompt    # only lists what is missing
    .\bootstrap\scripts\openbao-seed.ps1 -Overwrite conservices/infra/cloudflare
    ```

    Hidden answers are read with `Read-Host -AsSecureString`; paste with
    Ctrl+V or a right click. On Windows prefer this script to the bash one
    in Git Bash (see [Troubleshooting](#troubleshooting)).

| Option (bash / PowerShell) | What it does |
| --- | --- |
| `--no-prompt` / `-NoPrompt` | Ask nothing. Lists every entry: existing ones in green, missing ones in red with the Applications that stay `Degraded`, existing values that cannot be right, and the generated entries ESO has not created yet. |
| `--overwrite PATH` / `-Overwrite PATH` | Ask again for this entry even if it exists and replace it. Repeat it (bash) or separate paths with commas (PowerShell). Generated entries are refused: [rotate them](#rotate-a-generated-value) instead. |
| `--reenter` / `-Reenter` | Ask again for every entry. An empty answer keeps the current value. |
| `--modules a,b` / `-Modules a,b` | Check exactly these modules instead of the `enabled` settings of `cluster.yaml`. |
| `--cluster-file PATH` / `-ClusterFile PATH` | Another settings file than `cluster.yaml`. |

Colours: green for kept and written, yellow for skipped entries and
warnings, red for errors and missing entries. `NO_COLOR=1` turns them off;
they are also off when the output is not a terminal.

```text
== S3 keys (one per bucket, limited to that bucket) ==
==> conservices/infra/postgres/backup-s3
        read and write on bucket example-pg-backups only (CloudNativePG backups)
  Access key ID (empty = skip): change-me
  Secret access key (hidden):
  ok    received: 40 characters, wJal...EKEY
  ok    conservices/infra/postgres/backup-s3 written
  ok    conservices/modules/den/s3 exists, keeping it
==> conservices/modules/den/files-s3
        read only on example-conservices-den, example-conservices-stash (Den copies module files into its backups)
  Access key ID (empty = skip):
  warn  conservices/modules/den/files-s3 skipped; Application(s) den stay Degraded until it exists
...
== Summary ==
  ok    6 written, 2 kept
  error 1 missing:
        conservices/modules/den/files-s3 (access_key, secret_key): Application(s) den stay Degraded
  warn  Check the values you just entered in the OpenBao web UI (Secrets, conservices):
        ...
```

At the end the script reminds you to compare the hidden values in the
OpenBao web UI: it can check their form, not whether your provider accepts
them.

Applications whose secrets are missing stay `Degraded` and continue on
their own within a few minutes after you add the entry.

## 5. Check

```sh
kubectl get clustersecretstore openbao
kubectl get pushsecret -n external-secrets
kubectl get externalsecret -A
```

```text
NAME      AGE   STATUS   CAPABILITIES   READY
openbao   12m   Valid    ReadWrite      True
NAME                               AGE   STATUS
generated-postgres-superuser       12m   Synced
generated-postgres-roles-den       12m   Synced
...
NAMESPACE      NAME                   STORE     REFRESH INTERVAL   STATUS         READY
cert-manager   cloudflare-api-token   openbao   1h                 SecretSynced   True
...
```

Every ExternalSecret should be `SecretSynced`. One with `SecretSyncedError`
names the entry that is missing; `openbao-seed.sh --no-prompt` (or
`openbao-seed.ps1 -NoPrompt`) lists every missing entry at once.

## Every secret: keys and values

Paths are shown with the default `openbao.kvPath: conservices`.
**Generated** means ESO creates it: 48 random letters and digits (no
symbols, so the values fit into database URLs unescaped). Never write these
yourself on a new installation. **You** means you enter it (step 4). The
**Application** column is the Argo CD Application that stays `Degraded`
while the entry is missing.

| Path | Keys | Value | Created by | Application | Needed when |
| --- | --- | --- | --- | --- | --- |
| `conservices/infra/postgres/superuser` | `password` | password of the PostgreSQL superuser `postgres` | generated | `postgres`, `den` | always |
| `conservices/infra/postgres/roles/<role>` | `password` | password of a PostgreSQL login: `den`, `keycloak`, and one per enabled module (`stash`, `hr`, `events` for Rally, `finance`, `learn`, `wiki`, `desk`, `tasks`) | generated | `postgres` and the application | always (`den`, `keycloak`); per enabled module |
| `conservices/modules/den/operator-token` | `token` | token between Den's backend and its operator | generated | `den` | always |
| `conservices/modules/<module>/service-token` | `token` | token HR uses to call `learn`, `wiki`, `tasks` | generated | that module, `hr` | that module enabled |
| `conservices/modules/desk/secret-key` | `key` | encrypts the mailbox passwords Desk stores. **Keep it forever** | generated | `desk` | Desk enabled |
| `conservices/infra/keycloak/bootstrap-admin` | `password` | password of Keycloak's temporary admin `temp-admin` (only used on the first start) | generated | `keycloak` | always |
| `conservices/infra/keycloak/clients` | `den-keycloak`, `hr-provisioner`, `learn-provisioner` | secrets of Keycloak's confidential clients | generated | `keycloak`, `den`, `hr`, `learn` | always |
| `conservices/modules/den/s3` | `access_key`, `secret_key` | S3 access key ID and secret key, read and write on bucket `<prefix>-conservices-den` only | you | `den` | always |
| `conservices/modules/<module>/s3` | `access_key`, `secret_key` | the same for bucket `<prefix>-conservices-<module>` only: `stash`, `rally`, `learn`, `wiki`, `tasks` | you | that module | that module enabled |
| `conservices/modules/den/files-s3` | `access_key`, `secret_key` | S3 key with **read only** access to all module buckets (Den copies files into its backups) | you | `den` | always |
| `conservices/modules/den/backup-s3` | `access_key`, `secret_key` | S3 key, read and write on `<prefix>-den-backups` only | you | `den` | always |
| `conservices/modules/den/smtp` | `password` | Password paired modules use to log in to the shared mail server (`DEN_SMTP_PASSWORD`). Not generated and not stored in Den's database. Leave it unset to send mail without a login; Den stays Ready. | you | `den` | optional |
| `conservices/infra/postgres/backup-s3` | `access_key`, `secret_key` | S3 key, read and write on `<prefix>-pg-backups` only (CloudNativePG) | you | `postgres` | always |
| `conservices/infra/keycloak/smtp` | `host`, `port`, `from`, `username`, `password` | mail server for password reset and verification mail, for example `smtp.example.org`, `587`, `no-reply@example.org` | you | `keycloak` | `keycloak.smtp.enabled` (default `true`) |
| `conservices/infra/cloudflare` | `api-token` | Cloudflare API token with Zone:DNS:Edit and Zone:Zone:Read on your zone only: 40 characters (older tokens) or 53 starting with `cfut_` or `cfat_` | you | `letsencrypt` | `acme.dns01.provider: cloudflare` (default) |
| `conservices/infra/ghcr` | `username`, `token` | GitHub user and a classic token (`ghp_...`) with only `read:packages` | you | `den` and every module | `images.pullSecret.enabled` |

With every module enabled that is 18 generated entries (20 values) and 11
entries you enter (12 with `images.pullSecret.enabled`), each S3 entry with
its own key. The optional password at `conservices/modules/den/smtp` is
extra: leaving it unset does not Degrade Den. Which buckets the S3 keys are
for, and how to create them, is on [Data](data.md). Who reads which entry
is on [Secrets](../operations/secrets.md#inventory).

## Without the setup Job

With `openbao.setup.enabled: false` in `cluster.yaml` the template does not
touch OpenBao's configuration: there is no Application `openbao-setup`, and
Argo CD does not stop. Before the first sync, the OpenBao administrator then
creates everything the Job would:

1. the Kubernetes auth method and the policy `conservices-external-secrets`,
   as in [step 2](#2-the-administrators-one-time-step);
2. the KV version 2 engine at `openbao.kvPath` (default `conservices`);
3. the role `openbao.auth.role` for ESO's service account.

`openbao-configure.sh` (and `.ps1`) does all three when the setting is
`false`:

```text
== 2. Policy conservices-external-secrets ==
  ok    Wrote policy conservices-external-secrets (read conservices/*, write modules/*, infra/postgres/*, infra/keycloak/*)

== 3. KV version 2 engine conservices/ ==
  ok    Enabled KV v2 at conservices/

== 4. Role external-secrets ==
  ok    Wrote role external-secrets for external-secrets/external-secrets
```

By hand, after the policy:

```sh
bao secrets enable -path=conservices -version=2 kv
bao write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  token_policies=conservices-external-secrets token_ttl=1h
```

ESO still creates the random values and you still enter your credentials
(step 4).

## How ESO turns an OpenBao entry into a Secret

An ExternalSecret names the entry by its path **inside the mount
`conservices/`, without `data/`**. Example: the Cloudflare token for
cert-manager, from `charts/letsencrypt`:

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
        key: infra/cloudflare      # = conservices/infra/cloudflare
        property: api-token        # key inside the entry
```

And a generated value, from `charts/secret-store`: one PushSecret per entry,
named after the path without `modules/` or `infra/`, `IfNotExists` so an
existing value is never replaced, `deletionPolicy: None` so removing the
PushSecret keeps the value:

```yaml
apiVersion: external-secrets.io/v1alpha1
kind: PushSecret
metadata:
  name: generated-den-operator-token
  namespace: external-secrets
spec:
  refreshInterval: 1h
  updatePolicy: IfNotExists
  deletionPolicy: None
  secretStoreRefs:
    - kind: ClusterSecretStore
      name: openbao
  selector:
    generatorRef:
      apiVersion: generators.external-secrets.io/v1alpha1
      kind: Password
      name: conservices-random
  data:
    - match:
        secretKey: token
        remoteRef:
          remoteKey: modules/den/operator-token
          property: token
```

## Change a secret

1. Write the new value as a person with a token that may write the entry,
   with the seed script (`--overwrite conservices/modules/stash/s3`), in
   the web UI, or with `bao`:

    ```sh
    kubectl -n openbao exec -it openbao-0 -- sh
    export BAO_TOKEN=change-me    # then:
    bao kv patch conservices/modules/stash/s3 secret_key=-    # paste the value, Enter, Ctrl-D
    exit
    ```

    `kv patch` changes one key and keeps the others; every write is a new
    version (`bao kv get -version=1 conservices/modules/stash/s3` shows an
    old one, `bao kv rollback -version=1 conservices/modules/stash/s3`
    restores it).

2. Make ESO fetch it now instead of within `refreshInterval` (1 hour):

    === "Linux / macOS"

        ```sh
        kubectl -n conservices-stash annotate externalsecret stash-secrets force-sync="$(date +%s)" --overwrite
        ```

    === "Windows (PowerShell)"

        ```powershell
        kubectl -n conservices-stash annotate externalsecret stash-secrets "force-sync=$([DateTimeOffset]::Now.ToUnixTimeSeconds())" --overwrite
        ```

3. Restart the pods that read the Secret only at start (most Con Services
   programs do):

    ```sh
    kubectl -n conservices-stash rollout restart deploy/stash-backend
    ```

[Rotating secrets](../operations/secrets.md#rotating-secrets) gives each
secret's procedure.

### Rotate a generated value

Delete the entry; ESO creates a new random value at its next refresh. To
not wait up to an hour, force the PushSecret:

```sh
kubectl -n openbao exec -it openbao-0 -- sh
export BAO_TOKEN=change-me
bao kv metadata delete conservices/modules/den/operator-token
exit
kubectl -n external-secrets annotate pushsecret generated-den-operator-token force-sync="$(date +%s)" --overwrite
```

Then force-sync the ExternalSecrets that read it and restart the
Deployments, as above. This works for the database passwords
(CloudNativePG changes them in PostgreSQL), the Den operator token and the
service tokens. **Never** do it for `modules/desk/secret-key` (it encrypts
stored mailbox passwords) or the Keycloak entries (Keycloak keeps its own
copy after the first import; regenerate a client secret in the Keycloak
admin console, then store it with `bao kv patch`).

## What Con Services expects from whoever runs OpenBao

Con Services does not run, unseal or back up OpenBao. How OpenBao is run is
up to you, but plan for these:

- **Sealed pods.** While OpenBao is sealed, ESO cannot refresh secrets.
  Existing Kubernetes Secrets keep working, so running pods are not
  affected, but new secrets and changed values do not arrive. Unseal it
  after restarts, or use an auto-unseal seal
  ([OpenBao seal documentation](https://openbao.org/docs/configuration/seal/)).
- **Backups.** Everything in `conservices/` is needed to rebuild an
  installation; the generated values cannot be recreated (for example
  `modules/desk/secret-key`, which encrypts stored mailbox passwords). Back
  OpenBao up off the cluster, for example with Raft snapshots.
- **High availability.** With one OpenBao pod, a node failure stops secret
  refreshes until it is back. Three pods with Raft storage survive one.

## Troubleshooting

**cert-manager fails with `6111: Invalid format for Authorization header`**
:   The Cloudflare token in OpenBao is not a token, for example a single
    backslash `\` typed into the web UI or left by a paste that did not
    arrive (in the Git Bash window, Ctrl+V does not paste; it sends a
    control character). The seed scripts refuse such a value and show the
    length of every hidden answer; `openbao-seed.sh --no-prompt` reports a
    stored one, for example as `api-token contains a backslash`. Fix it:

    1. Store the right token, with the script or in the web UI
       (`conservices` → `infra/cloudflare` → **Create new version**):

        === "Linux / macOS"

            ```sh
            bash bootstrap/scripts/openbao-seed.sh --overwrite conservices/infra/cloudflare
            ```

        === "Windows (PowerShell)"

            ```powershell
            .\bootstrap\scripts\openbao-seed.ps1 -Overwrite conservices/infra/cloudflare
            ```

    2. Make ESO copy it to cert-manager now:

        === "Linux / macOS"

            ```sh
            kubectl -n cert-manager annotate externalsecret cloudflare-api-token force-sync="$(date +%s)" --overwrite
            ```

        === "Windows (PowerShell)"

            ```powershell
            kubectl -n cert-manager annotate externalsecret cloudflare-api-token "force-sync=$([DateTimeOffset]::Now.ToUnixTimeSeconds())" --overwrite
            ```

    3. Delete the failed CertificateRequest of the wildcard certificate, so
       cert-manager starts a new one at once instead of waiting for its
       back-off:

        ```sh
        kubectl -n conservices-gateway get certificaterequest
        kubectl -n conservices-gateway delete certificaterequest wildcard-tls-1   # the name from the list
        kubectl -n conservices-gateway get certificate wildcard-tls               # READY True after a minute or two
        ```

**An ExternalSecret shows `SecretSyncedError` with `Secret does not exist` (or `secret not found`)**
:   The entry it reads is not in OpenBao. List every missing entry, with
    the Applications that wait for it:

    ```sh
    bash bootstrap/scripts/openbao-seed.sh --no-prompt      # or: .\bootstrap\scripts\openbao-seed.ps1 -NoPrompt
    ```

    Entries you enter: run the script without `--no-prompt` (step 4).
    Generated ones listed as `not created yet`: check
    `kubectl get pushsecret -n external-secrets`. A custom ExternalSecret
    may also use the wrong `key`: it is the path inside the mount without
    `data/` (`infra/cloudflare`, not `conservices/data/infra/cloudflare`).

**The seed script warns `uses the same access key as`**
:   Two entries share one S3 key. It works, but every bucket should have its
    own key limited to that bucket (see
    [step 4](#4-enter-your-provider-credentials)). Create a separate key at
    your provider and replace the entry with `--overwrite`.

**Git Bash on Windows: hidden answers are refused or arrive empty**
:   In the Git Bash window (mintty), paste with Shift+Insert or a right
    click; Ctrl+V sends a control character instead. In other terminals Git
    Bash may lose pasted text while echo is off. Use the PowerShell scripts
    (`openbao-seed.ps1`), which read hidden input with
    `Read-Host -AsSecureString` and need neither Git Bash nor `jq`.

**`openbao-setup` stays `OutOfSync` / `Missing` and nothing else installs**
:   That is the review step: Argo CD waits for you. Review the diff and
    press Sync ([step 3](#3-review-and-sync-openbao-setup)).

**The Job's log says `login with role conservices-setup failed`**
:   The administrator's step was not done, or with other names. Run
    `openbao-configure.sh` (step 2) with the same `cluster.yaml`, then press
    Sync again. `permission denied` here can also mean OpenBao cannot check
    the token: its service account lacks `system:auth-delegator`.

**The Job's log says `could not enable conservices/`**
:   The policy `conservices-setup` names another mount: `openbao.kvPath`
    changed after `openbao-configure.sh` ran. Run it again with the current
    `cluster.yaml`, then press Sync.

**The Job's log says `could not write role external-secrets`**
:   The values in `cluster.yaml` (`externalSecrets.*`, `openbao.auth.role`)
    differ from the ones in the policy `conservices-setup`. Run
    `openbao-configure.sh` again after changing `cluster.yaml`; it rewrites
    the policy.

**The Job fails with `connection refused`, `i/o timeout` or `no such host`**
:   A network policy blocks it, or `openbao.server` is wrong. The Job may
    only reach the namespace `openbao.namespace` (default `openbao`); set it
    to where your OpenBao pods run. OpenBao's namespace must admit the Job
    (see [step 1](#1-check-that-openbao-is-ready)).

**`openbao-configure` says `pod openbao/openbao-0 not found`**
:   OpenBao runs under another namespace or release name. Set them, for
    example `OPENBAO_NAMESPACE=vault OPENBAO_RELEASE=bao` (PowerShell:
    `$env:OPENBAO_NAMESPACE = "vault"; $env:OPENBAO_RELEASE = "bao"`), and
    run it again.

**A script says `token rejected`**
:   OpenBao is sealed, or the token is invalid or lacks the rights. Check
    `kubectl -n openbao exec openbao-0 -- bao status` and ask for a new
    token. For `openbao-seed`, the mount `conservices/` must also exist
    (sync `openbao-setup` first).

**The Job or a script says `conservices/ exists but is not KV version 2`**
:   Your OpenBao already has a version 1 engine at that path. Set another
    `openbao.kvPath` in `cluster.yaml` (for example `conservices-kv`), push,
    run `openbao-configure` again and sync `openbao-setup`.

**A script says `the root chart rejected cluster.yaml`**
:   The scripts render the root chart to learn the names; the message above
    it says what is wrong. Run it from the root of your copy, with a
    complete `cluster.yaml` ([Argo CD](argocd.md#2-fill-in-clusteryaml)).

**`kubectl get clustersecretstore openbao` is not `Valid`, message `permission denied` or `403`**
:   The role `external-secrets` is missing or does not match ESO's service
    account. Sync `openbao-setup` again (with `openbao.setup.enabled:
    false`: run `openbao-configure` again). If OpenBao's log shows
    `service account lookup failed`, its own service account lacks the
    `system:auth-delegator` ClusterRole.

**A PushSecret shows `secret not managed by external-secrets`**
:   The entry exists but was written by a person or by a copy without its
    custom metadata, and lacks the key the PushSecret wants to add. Add that
    key yourself with `bao kv patch`, or delete the entry so ESO creates
    it. An entry written by hand may lack the custom metadata
    (`bao kv metadata put -custom-metadata=managed-by=external-secrets <path>`
    adds it).

**A PushSecret shows `permission denied`**
:   The policy `conservices-external-secrets` does not allow writing that
    path, usually because `openbao.kvPath` changed after
    `openbao-configure.sh` ran. Run it again with the current
    `cluster.yaml`.

**ClusterSecretStore message `x509: certificate signed by unknown authority`**
:   ESO does not trust OpenBao's certificate. Put the CA that signed it in
    the ConfigMap or Secret named by `openbao.caBundle` (default: ConfigMap
    `openbao-ca`, key `ca.crt`, in ESO's namespace), or set
    `openbao.caBundle.name: ""` if OpenBao has a publicly trusted
    certificate. The setup Job uses the same CA.

**ClusterSecretStore message `connection refused` or `i/o timeout`**
:   `openbao.server` is wrong, or a network policy blocks ESO from OpenBao.
    Allow ESO's namespace to reach OpenBao on port 8200, and OpenBao to
    reach the Kubernetes API (for the token check).

**ESO errors come and go after an OpenBao pod restart**
:   `openbao.server` points at a Service that also routes to sealed pods.
    Use the Service of the active node (`openbao-active` with the upstream
    chart), or unseal the pod.

Next: [Data](data.md).
