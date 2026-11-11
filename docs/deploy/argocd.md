# Argo CD and cluster.yaml

This is the main installation guide. You copy the template, fill in its
one settings file, connect it to your Argo CD, prepare OpenBao and apply one object;
Argo CD then installs every component in the right order. With a cluster
that meets the [Prerequisites](prerequisites.md) (including Argo CD,
cert-manager, External Secrets Operator, OpenBao and CloudNativePG, which
the template uses but does not install), plan about one hour.

Commands are shown for **Linux / macOS** (bash) and **Windows
(PowerShell)** where the two differ; pick your tab once and the rest of the
page follows. The tools you need, and how to install them on each system,
are listed in [Prerequisites: Tools on your computer](prerequisites.md#10-tools-on-your-computer).

## Terms used on this page

**Argo CD**
:   A program in the cluster that reads a Git repository and makes the
    cluster equal to it ([documentation](https://argo-cd.readthedocs.io/)).

**Application**
:   An Argo CD object that says "render this chart and apply it to that
    namespace". Each component (PostgreSQL, Keycloak, Den, ...) is one
    Application.

**Root Application (app of apps)**
:   The one Application you create by hand. It renders the template's root
    Helm chart (`charts/root`) with your `cluster.yaml`, and the output is
    all the other Applications. It also manages itself.

**Sync / Synced, Healthy**
:   *Synced*: the cluster equals Git. *Healthy*: what was applied works
    (Deployments have their pods, Certificates are issued, ...).

**Sync wave**
:   A number on each Application. Argo CD applies lower waves first and
    waits until they are Healthy before it starts the next wave.

**Automatic and manual sync**
:   Almost every Application syncs **automatically**: Argo CD applies each
    change it sees in Git. One, `openbao-setup`, syncs only **manually**:
    Argo CD shows it as `OutOfSync` and waits until a person starts the
    sync ([step 7](#7-do-the-steps-only-a-person-can-do)).

**kubeconfig**
:   The file that tells `kubectl` which cluster to talk to and how to log
    in (default `~/.kube/config`; the variable `KUBECONFIG` selects
    another file).

## How the template is organised

```text
cluster.yaml              <- the only file you edit
charts/root/              <- renders every Application from cluster.yaml
  values.yaml             <- defaults for every setting (do not edit; override in cluster.yaml)
  values.schema.json      <- rejects unknown or misspelt keys
charts/<component>/       <- small charts for cluster-specific objects (gateway, postgres, keycloak, secret-store, ...)
components/               <- fixed Kustomize folders (internal CA, namespaces, ...)
bootstrap/                <- install-root.sh / install-root.ps1, OpenBao configure and seed scripts, reference Argo CD values
examples/cluster.example-filled.yaml   <- a complete example with example.org
ci/                       <- render and check scripts, extra value files for CI
```

Den and the module charts are not copied into the template: Argo CD reads
them from the main repository
[`AGlElectronics/con-services`](https://github.com/AGlElectronics/con-services)
(`deploy/charts/<app>`), each at its own release: `den.version: "1.0.0-1"`
means Den's images with the tag `1.0.0-1` and Den's chart at the Git tag
`den/v1.0.0`. Each module has its own `modules.<name>.version` the same
way.

The root Application is called `conservices-stack` (setting
`rootApplication.name`), so it does not clash with an Application named
`root` that many clusters already have.

## 1. Copy the template

1. On GitHub, open
   [`AGlElectronics/con-services-gitops`](https://github.com/AGlElectronics/con-services-gitops)
   and choose **Use this template → Create a new repository**. Make it
   **private**: it will describe your installation.
2. Clone your copy into a folder named `con-services-gitops` (the same
   command works in bash and PowerShell):

    ```sh
    git clone https://github.com/your-org/con-services-gitops.git con-services-gitops
    cd con-services-gitops
    ```

    Replace `your-org/con-services-gitops` with the owner and name of your
    copy. Your copy may have another name (for example `acme-cluster`);
    the last argument of `git clone` still puts it into the folder
    `con-services-gitops`, which is the folder the rest of this guide
    assumes. Every later command runs **from the root of that folder**.

    ```text
    Cloning into 'con-services-gitops'...
    ...
    Resolving deltas: 100% (...), done.
    ```

## 2. Fill in cluster.yaml

1. Open `cluster.yaml`. The required values are at the top, each set to
   `change-me` with an example in the comment above it:

    | Key | Example | Where it comes from |
    | --- | --- | --- |
    | `domain` | `example.org` | your domain |
    | `git.repoURL` | `https://github.com/your-org/con-services-gitops.git` | the copy you made in step 1 |
    | `acme.email` | `admin@example.org` | Let's Encrypt sends expiry warnings here |
    | `s3.endpoint`, `s3.region` | `https://s3.example-provider.com`, `eu-central-1` | your S3 provider ([Data](data.md)) |
    | `s3.bucketPrefix` | `acme` | your choice; buckets are `<prefix>-conservices-<app>`, `<prefix>-pg-backups`, `<prefix>-den-backups` |
    | `s3.fqdns` | `["s3.example-provider.com"]` | the host name of `s3.endpoint` (add `*.<host>` for virtual-host style) |
    | `den.backupAgeRecipients` | `age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p` | `age-keygen -o den-backup.key` prints `Public key: age1...`; keep `den-backup.key` offline |

    **The age key for Den's backups.** `age-keygen` comes with
    [age](https://age-encryption.org). If it is not installed yet:

    === "Linux / macOS"

        ```sh
        sudo apt install age    # Debian, Ubuntu
        sudo dnf install age    # Fedora
        brew install age        # macOS
        ```

    === "Windows (PowerShell)"

        ```powershell
        winget install FiloSottile.age
        $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
        ```

        The second line makes the current terminal see the new program;
        a terminal opened after the installation does not need it.

    Create the key **outside** your copy of the template, so it can never
    be committed:

    ```sh
    age-keygen -o ../den-backup.key
    ```

    ```text
    Public key: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
    ```

    Put the `age1...` value into `den.backupAgeRecipients`. The file holds
    the secret key that opens the backups: move it to your password
    manager or an offline medium, never into Git
    ([The encryption key](../operations/databases-and-backups.md#the-encryption-key)).
    The other tools and their installation are on
    [Prerequisites](prerequisites.md#install-the-tools).

2. Set the optional values you need. The end of `cluster.yaml` shows the
   common ones commented out; the [full reference](#clusteryaml-reference)
   is below. Typical choices:
    - Fixed Gateway IPs from your Cilium LB IPAM pool
      (`gateway.public.loadBalancerIP`, `gateway.internal.loadBalancerIP`),
      **strongly recommended**: without them the two Gateways may get their
      addresses in either order, and your port forward may reach the
      internal one. See
      [DNS and certificates](dns-and-certificates.md#1-choose-the-gateway-ips).
    - Smaller PostgreSQL volumes for a small event or trial, for example
      `postgres.storage.size: 5Gi` and `postgres.storage.walSize: 2Gi`
      ([Prerequisites: Storage](prerequisites.md#4-storage)).
    - `storage.longhornSingle.enabled: true` with Longhorn.
    - Where the prerequisites run, if not at the defaults: `openbao.server`
      and `openbao.caBundle` (how External Secrets reaches OpenBao),
      `externalSecrets.namespace` and `.serviceAccount`,
      `postgres.operatorNamespace` (see
      [Cluster prerequisites](#cluster-prerequisites)).
    - The modules to run: in the block *Pick the modules to run*, set
      `enabled: true` for each one you want. All eight are off by default;
      Den is always deployed. Each module waits for Den until you pair it
      ([Den and the modules](apps.md#deploy)).
3. Check that nothing is missing:

    === "Linux / macOS"

        ```sh
        grep -n change-me cluster.yaml
        ```

    === "Windows (PowerShell)"

        ```powershell
        Select-String -Path cluster.yaml -SimpleMatch 'change-me'
        ```

    No output means every required value is set. Otherwise each line names
    the place still to fill in, for example `cluster.yaml:12:domain: change-me`.
    Then let the chart check the whole file:

    === "Linux / macOS"

        ```sh
        helm template root charts/root -f cluster.yaml > /dev/null && echo OK
        ```

    === "Windows (PowerShell)"

        ```powershell
        helm template root charts/root -f cluster.yaml | Out-Null; if ($LASTEXITCODE -eq 0) { "OK" }
        ```

    ```text
    OK
    ```

    A missing value prints which one, for example:

    ```text
    Error: execution error at (root/templates/validate.yaml:22:4):
    cluster.yaml is not complete. Set these values (they are still "change-me" or empty):
      - s3.endpoint
    ```

    and a misspelt key is rejected by the schema:

    ```text
    Error: values don't meet the specifications of the schema(s) in the following chart(s):
    root:
    - at '/postgres': additional properties 'instance' not allowed
    ```

4. Commit and push. Argo CD reads `cluster.yaml` from Git, not from your
   computer:

    === "Linux / macOS"

        ```sh
        git add cluster.yaml && git commit -m "Configure cluster" && git push
        ```

    === "Windows (PowerShell)"

        ```powershell
        git add cluster.yaml; if ($LASTEXITCODE -eq 0) { git commit -m "Configure cluster" }; if ($LASTEXITCODE -eq 0) { git push }
        ```

    Each command runs only if the one before it succeeded. The last lines
    should name your branch, for example `main -> main`.

## 3. Connect Argo CD

Argo CD is a prerequisite: the template does not install, upgrade or
expose it. From here on, the commands talk to your cluster.

!!! tip "Several kubeconfigs? Select the cluster first"
    If you keep one kubeconfig file per cluster, point `kubectl` and `helm`
    at the right one. This applies to the current terminal only, until you
    close it; set it again in every new terminal.

    === "Linux / macOS"

        ```sh
        export KUBECONFIG=~/.kube/my-cluster.yaml
        ```

    === "Windows (PowerShell)"

        ```powershell
        $env:KUBECONFIG = "$HOME\.kube\my-cluster.yaml"
        ```

    Check that it is the cluster you mean:

    ```sh
    kubectl config current-context
    kubectl get nodes
    ```

    The node names must be those of the cluster you install on.

Check that Argo CD has the health check for Application objects
([Prerequisites: Argo CD](prerequisites.md#9-argo-cd)); without it every
sync wave starts at once:

=== "Linux / macOS"

    ```sh
    kubectl -n argocd get cm argocd-cm -o yaml | grep -c health.argoproj.io_Application
    ```

=== "Windows (PowerShell)"

    ```powershell
    (kubectl -n argocd get cm argocd-cm -o yaml | Select-String -SimpleMatch 'health.argoproj.io_Application').Count
    ```

```text
1
```

**Private copy?** Give Argo CD a read-only credential for it, for example a
fine-grained GitHub token with *Contents: read* on that one repository.
The commands below ask for the token instead of having you type it into
the command, so it does not end up in your shell history (bash's
`~/.bash_history`, PowerShell's `ConsoleHost_history.txt`) or on screen.

**Replace before running** (the highlighted lines):

| Value in the command | Replace with |
| --- | --- |
| `https://github.com/your-org/con-services-gitops.git` | The HTTPS URL of **your** copy, exactly as in `git.repoURL` in `cluster.yaml` |
| the token (asked for when you run the commands) | The read-only token you created for your copy; paste it at the prompt, nothing is shown |

The user name `git` can stay: GitHub ignores it when a token is used.

=== "Linux / macOS"

    ```sh hl_lines="4 6"
    read -rsp "Read-only Git token: " GIT_TOKEN; echo
    kubectl -n argocd create secret generic repo-gitops \
      --from-literal=type=git \
      --from-literal=url=https://github.com/your-org/con-services-gitops.git \
      --from-literal=username=git \
      --from-file=password=<(printf '%s' "$GIT_TOKEN")
    unset GIT_TOKEN
    ```

=== "Windows (PowerShell)"

    ```powershell hl_lines="5 7"
    $secure = Read-Host "Read-only Git token" -AsSecureString
    $token = (New-Object System.Management.Automation.PSCredential("git", $secure)).GetNetworkCredential().Password
    kubectl -n argocd create secret generic repo-gitops `
      --from-literal=type=git `
      --from-literal=url=https://github.com/your-org/con-services-gitops.git `
      --from-literal=username=git `
      --from-literal=password=$token
    Remove-Variable token, secure
    ```

    PowerShell's history records `$token`, not its value. The value is
    handed to `kubectl` for the moment it runs, where only administrators
    of your computer could see it in the process list.

```text
secret/repo-gitops created
```

Then mark the Secret as a repository credential, so Argo CD uses it:

```sh
kubectl -n argocd label secret repo-gitops argocd.argoproj.io/secret-type=repository
```

```text
secret/repo-gitops labeled
```

That token is a real secret: keep it in your password manager, see
[Secrets](../operations/secrets.md).

## 4. Let OpenBao trust the template (OpenBao administrator, once)

The template reads every secret from the cluster's OpenBao, and by default
sets up its own part of OpenBao through a Job that you review before it
runs (`openbao.setup.enabled: true`). For that, whoever administers OpenBao
gives the Job a narrow role, once per cluster, with an admin token. Run
it from the root of your copy:

=== "Linux / macOS"

    ```sh
    bash bootstrap/scripts/openbao-configure.sh
    ```

=== "Windows (PowerShell)"

    ```powershell
    .\bootstrap\scripts\openbao-configure.ps1
    ```

    Or the bash version through Git Bash (not plain `bash`, which may
    start WSL; see
    [The bootstrap scripts on Windows](prerequisites.md#the-bootstrap-scripts-on-windows)):

    ```powershell
    & "C:\Program Files\Git\bin\bash.exe" bootstrap/scripts/openbao-configure.sh
    ```

It writes two policies and the role `conservices-setup`; nothing else.
The token is asked for and never stored in the cluster. The commands it
runs, what the Job may and may not do, and the way without the Job are in
[Secrets with OpenBao](secrets-openbao.md#2-the-administrators-one-time-step).

The random secrets (database passwords, tokens) are created by External
Secrets later; you only enter your provider credentials (S3 keys, SMTP,
DNS token) once the KV engine exists, in step 7.

## 5. Apply the root Application

Run the script from the root of your copy:

=== "Linux / macOS"

    ```sh
    bash bootstrap/install-root.sh
    ```

=== "Windows (PowerShell)"

    ```powershell
    .\bootstrap\install-root.ps1
    ```

```text
==> Checking /home/you/con-services-gitops/cluster.yaml
==> Checking the cluster prerequisites
==> Prerequisites found
==> Argo CD will read https://github.com/your-org/con-services-gitops.git
application.argoproj.io/conservices-stack created
==> Root Application "conservices-stack" applied.

Next steps:

  1. Follow the sync waves:
       kubectl get applications -n argocd -w
  2. Sync "openbao-setup" by hand. Argo CD never syncs it automatically and
     the later waves wait for it: review its diff in Argo CD, then press Sync
     (or: argocd app sync openbao-setup). The OpenBao administrator must have
     run bootstrap/scripts/openbao-configure.sh once before.
  3. Enter your provider credentials (S3, SMTP, Cloudflare) in OpenBao:
       bash bootstrap/scripts/openbao-seed.sh
  ...
```

What the script does, in order:

1. Renders only the root Application from your `cluster.yaml` (the same
   checks as in step 2). Its name is `rootApplication.name`, default
   `conservices-stack`.
2. Checks that the [prerequisites](prerequisites.md) are installed: the
   CRDs of cert-manager, trust-manager, External Secrets, CloudNativePG and
   the Barman Cloud plugin, External Secrets' service account and OpenBao's
   CA from `cluster.yaml`.
3. Checks that `argocd-cm` has the health check for Application objects.
   Without it the script prints a warning in yellow with `!!!` in front of
   each line and waits 10 seconds (press ++ctrl+c++ to stop and add the
   check first, see [step 3](#3-connect-argo-cd)).
4. Applies the root Application and prints the next steps.

Options: `--dry-run` (PowerShell: `-DryRun`) prints the root Application
without checking or applying anything; `--skip-preflight`
(`-SkipPreflight`) skips steps 3 and 4. Coloured output is turned off
when the output is not a terminal, or with `NO_COLOR=1` (bash).

## 6. Watch the sync waves

```sh
kubectl get applications -n argocd -w
```

| Wave | Applications | Done when |
| --- | --- | --- |
| -8 | `longhorn-storage` (only with `storage.longhornSingle.enabled`) | StorageClass `longhorn-single` |
| -7 | `pki` | ClusterIssuer `conservices-internal-ca` ready |
| -5 | `openbao-setup` (only with `openbao.setup.enabled`, manual sync) | you pressed Sync and the Job finished (step 7) |
| -4 | `cluster-secret-store` | ClusterSecretStore `openbao` valid, random secrets created |
| -3 | `letsencrypt` | ClusterIssuers `letsencrypt-staging` and `letsencrypt-prod` ready |
| -2 | `gateway` | certificate `wildcard-tls` issued, Gateways `public` and `internal` programmed |
| 0 | `platform-namespaces` | namespaces `conservices-data`, `conservices-identity` |
| 2 | `keycloak-operator` | Keycloak operator running (with its own network policies) |
| 3 | `postgres` | PostgreSQL cluster `conservices-pg` healthy, 3 instances (1 with `profile: small`) ([Data](data.md)) |
| 4 | `keycloak` | Keycloak ready, realms imported ([Identity](identity.md)) |
| 5 | `den` and one per enabled module | applied together; nothing waits for their health ([Den and the modules](apps.md)) |

**Why Den and the modules share the last wave.** Argo CD waits for every
Application of a wave to be `Healthy` before it applies the next wave, and
fails the root sync if one turns `Degraded` there. It does not wait for the
health of the **last** wave: once that wave is applied, the root sync is
done. Den and the modules are in that last wave, so a `Degraded` Den or
module (for example an image tag that does not exist) never stops the next
push from being applied: fix `cluster.yaml`, push, and the fix arrives.
The modules still start after Den in practice: each one waits for Den at
runtime (`den.mode: required`) until you pair it.

The infrastructure waves (-8 to 4) keep their order, because each one
needs the one before (Keycloak needs its operator and PostgreSQL). A
`Degraded` infrastructure Application therefore still holds back the
waves after it; see
[An infrastructure Application is Degraded and later waves never start](#an-infrastructure-application-is-degraded-and-later-waves-never-start)
in Troubleshooting.

## 7. Do the steps only a person can do

Argo CD waits at these points and continues by itself once they are done:

1. **Wave -5, OpenBao setup:** sync `openbao-setup` by hand, as described
   [below](#sync-openbao-setup-by-hand). Then enter your provider
   credentials (S3 keys, SMTP, DNS token) in OpenBao
   ([which ones](secrets-openbao.md#every-secret-keys-and-values)).
2. **Wave -2, certificates and DNS:** create the DNS records and the port
   forward, or a Cloudflare Tunnel
   ([DNS and certificates](dns-and-certificates.md)).
3. **Wave 3, buckets:** the buckets must exist before PostgreSQL's first
   backup and before the apps start ([Data](data.md)).

**What a missing credential does.** An Application whose OpenBao entry is
missing, or whose provider rejects the credential, becomes `Degraded`
(or stays `Progressing`) until you fix it. What that blocks depends on its
wave:

- **Infrastructure waves block everything after them.** Argo CD starts a
  wave only when every earlier wave is `Healthy`. A `Degraded`
  `letsencrypt` (for example a wrong DNS token) or `keycloak-operator`
  therefore stops the Gateways, PostgreSQL, Keycloak, Den and every
  module from being installed until it is fixed. Look at the **lowest**
  wave that is not `Healthy` first.
- **Den and the modules do not block each other.** They share the last
  wave, so a module that is `Degraded` (for example because its S3 key is
  missing) does not stop Den or the other modules.

### Sync openbao-setup by hand

`openbao-setup` is the only Application **without automated sync**, on
purpose: its Job changes your OpenBao (it enables the KV engine and writes
the role External Secrets logs in with), so a person reviews what it will
do and starts it.

**What you see while it waits:** `openbao-setup` is `OutOfSync` (health
`Missing`), and nothing from wave -4 on is installed: no
`cluster-secret-store`, no `letsencrypt`, no Gateways. This is expected,
not an error:

```sh
kubectl get applications -n argocd
```

```text
NAME               SYNC STATUS   HEALTH STATUS
openbao-setup      OutOfSync     Missing
pki                Synced        Healthy
...
```

(plus the root Application, and `longhorn-storage` if you enabled it).

**In the Argo CD web UI:**

1. Open Argo CD wherever your cluster exposes it. If it is not exposed,
   forward it to your computer and open `https://localhost:8080`:
   `kubectl -n argocd port-forward svc/argocd-server 8080:443`.
2. On the **Applications** page, click the tile **openbao-setup**.
3. Click **Diff** (called **App Diff** in some versions) and read what
   will be created: a ServiceAccount, a ConfigMap with the setup script, a
   Job and a NetworkPolicy, all named `conservices-openbao-setup` (the
   ServiceAccount after `openbao.setup.serviceAccount`). What the script
   does is explained in
   [Secrets with OpenBao](secrets-openbao.md#3-review-and-sync-openbao-setup).
4. Close the diff, click **Sync** at the top, leave the options as they
   are, and click **Synchronize** at the top of the panel that opens.
5. The tile turns `Synced`, and `Healthy` once the Job has finished
   (usually within a minute).

**Without the UI**, start the same sync with `kubectl`. It sets the
Application's `operation` field, which is what the UI does too
([Argo CD: Sync Applications with kubectl](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-kubectl/)).
Review first what will be applied: the script the Job runs is
`charts/openbao-setup/files/setup.sh` in your copy, and the objects Argo CD
will create are listed under `status.resources` of:

```sh
kubectl -n argocd get application openbao-setup -o yaml
```

Then start the sync:

=== "Linux / macOS"

    ```sh
    kubectl -n argocd patch application openbao-setup --type merge -p \
      '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"syncStrategy":{"hook":{}},"syncOptions":["ServerSideApply=true"]}}}'
    ```

=== "Windows (PowerShell)"

    Windows PowerShell 5.1 removes the double quotes from JSON passed to
    programs, so write the patch to a file and pass the file:

    ```powershell
    @'
    operation:
      initiatedBy:
        username: admin
      sync:
        syncStrategy:
          hook: {}
        syncOptions:
          - ServerSideApply=true
    '@ | Set-Content -Encoding ascii sync-openbao-setup.yaml
    kubectl -n argocd patch application openbao-setup --type merge --patch-file sync-openbao-setup.yaml
    Remove-Item sync-openbao-setup.yaml
    ```

```text
application.argoproj.io/openbao-setup patched
```

`username` is only recorded in the Application's history as who started
the sync. Follow the result:

```sh
kubectl -n argocd get application openbao-setup
kubectl -n external-secrets logs job/conservices-openbao-setup
```

```text
NAME            SYNC STATUS   HEALTH STATUS
openbao-setup   Synced        Healthy
```

The Job runs in External Secrets' namespace (`external-secrets` by
default, see `openbao.caBundle.namespace`). Within a few minutes
`cluster-secret-store` and the following waves start by themselves.

## 8. What "done" looks like

```sh
kubectl get applications -n argocd
```

```text
NAME                   SYNC STATUS   HEALTH STATUS
cluster-secret-store   Synced        Healthy
conservices-stack      Synced        Healthy
den                    Synced        Healthy
desk                   Synced        Healthy
finance                Synced        Healthy
gateway                Synced        Healthy
hr                     Synced        Healthy
keycloak               Synced        Healthy
keycloak-operator      Synced        Healthy
learn                  Synced        Healthy
letsencrypt            Synced        Healthy
openbao-setup          Synced        Healthy
pki                    Synced        Healthy
platform-namespaces    Synced        Healthy
postgres               Synced        Healthy
rally                  Synced        Healthy
stash                  Synced        Healthy
tasks                  Synced        Healthy
wiki                   Synced        Healthy
```

`conservices-stack` is the root Application (your `rootApplication.name`).
Other Applications of your cluster, if any, are listed too.

Then open `https://den.<domain>` (or your `den.host`) and sign in
([Den and the modules](apps.md)).

The same states are visible in Argo CD's UI, wherever your cluster exposes
it; the template does not publish it.

## Changing settings later

Edit `cluster.yaml`, run `helm template root charts/root -f cluster.yaml > /dev/null`
to check it, commit and push. The root Application picks the change up
within three minutes (or press **Refresh** on `conservices-stack` in the
UI). If a sync is retrying when you push, the next attempt already uses
your new commit (`retry.refresh`).

Settings worth knowing about after the first install:

- **Host names** (`den.host`, `modules.<name>.host`,
  `modules.rally.submit.host`, `keycloak.host`, `keycloak.adminHost`):
  each app lives on `<host>.<domain>`. A host is one lowercase DNS label
  (letters, digits, dashes; no dots, because the wildcard certificate
  `*.<domain>` covers exactly one level), and no two apps may share one;
  the chart stops with a message otherwise. Changing a host after the
  first install also needs the matching DNS record and a change in
  Keycloak, because the realms are imported only once
  ([Identity: Changing a host name](identity.md#changing-a-host-name)).
- **Profile** (`profile: small`): for 1 or 2 nodes, not highly available
  ([Sizing: Small profile](sizing.md#small-profile)).

Pass-through values: every component has a `values` key whose content is
merged last into that component's chart values, for settings the template
does not expose. Example, Den's backend with more memory:

```yaml
den:
  values:
    backend:
      resources:
        limits: { cpu: "1", memory: 512Mi }
```

## Upgrading

Den and every module have their own version, and you upgrade them one at
a time. The version you write in `cluster.yaml` (`X.Y.Z-BUILD`) sets both
the image tag of every image of that app and the chart it is installed
with: `modules.hr.version: "1.12.1-1"` means the images `hr-*:1.12.1-1`
and the chart at the tag `hr/v1.12.1` of `con-services`. Changing one
app's version changes only that app's Application; no other pod restarts.
The rules behind the numbers are on
[Versions and upgrades](../operations/versioning.md).

### Upgrade one app (Den MINOR or PATCH, or any module)

1. **Read that app's changelog** from your version to the new one
   (`CHANGELOG.md` in its repository, linked from the
   [Changelog](../changelog.md) page). Do what its **BREAKING:** entries
   say. For a module, read its *Needs Den* line: if it names a newer Den
   than you run, upgrade Den first, the same way.
2. **Make a backup:** Den → **Backups** → **Back up now**.
3. **Set the new version** in `cluster.yaml`, Den with `den.version`, a
   module with `modules.<name>.version`:

    ```yaml
    modules:
      hr:
        enabled: true
        version: "1.12.1-1"     # was "1.12.0-1"
    ```

4. **Check, commit and push:**

    ```sh
    helm template root charts/root -f cluster.yaml > /dev/null && echo OK
    git commit -am "Upgrade HR to 1.12.1" && git push
    ```

    ```text
    OK
    ```

5. **Watch** the app's Application become `Synced` and `Healthy` again
   (`kubectl get applications -n argocd hr -w`), then sign in to the app.

A new `BUILD` of the same version (`1.12.1-1` → `1.12.1-2`) is a rebuild
with security updates only; it uses the same chart and is always safe.

### Upgrade to a new Den MAJOR

A new Den MAJOR (for example `1.5.0` → `2.6.0`) removes something modules
rely on, so Den and every enabled module move to the new MAJOR in **one
push**. The root chart refuses a `cluster.yaml` in which an enabled
module's MAJOR differs from Den's, so a half-done upgrade never reaches
the cluster.

1. Check that every enabled module has a release for the new MAJOR
   ([compatibility table](../operations/versioning.md#compatibility-table)).
   If one has none yet, wait, or set it to `enabled: false` for now.
2. Read Den's changelog and the new MAJOR's release of every enabled
   module, and do their **BREAKING:** steps in the order given.
3. Make a backup (Den → **Backups** → **Back up now**) and plan a short
   maintenance window: Argo CD applies Den and the modules in the same
   sync wave (5), but their pods restart at different speeds, and a module
   still running its old MAJOR can fail calls to Den for a few minutes.
4. Set every version at once, check, commit and push:

    ```yaml
    den:
      version: "2.6.0-1"        # was "1.5.0-1"
    modules:
      hr:
        enabled: true
        version: "2.14.0-1"     # was "1.13.0-1"
      stash:
        enabled: true
        version: "2.3.2-1"      # was "1.3.2-1"
    ```

    ```sh
    helm template root charts/root -f cluster.yaml > /dev/null && echo OK
    git commit -am "Upgrade to Den 2" && git push
    ```

5. Watch `kubectl get applications -n argocd -w` until Den and every module
   are `Synced` and `Healthy`, and check on Den's **Modules** page that every
   module is still paired.

To roll back, set the old versions again in one commit, after restoring
the databases whose migrations ran
([Rolling back](../operations/versioning.md#rolling-back)).

### The rest

- **The shared pieces** (this template's PostgreSQL, Keycloak, gateways):
  read the [suite changelog](https://github.com/AGlElectronics/con-services/blob/main/CHANGELOG.md)
  and the template's `CHANGELOG.md`. Releases that need action start with
  **BREAKING:**.
- **The prerequisites** (Argo CD, cert-manager, trust-manager, External
  Secrets, OpenBao, CloudNativePG) are upgraded by whoever runs them, not by the
  template. Before a minor upgrade, check that the template release you run
  lists the new version on [Prerequisites](prerequisites.md#at-a-glance).
- **The template itself:** merge the new template release into your copy
  (`git remote add template https://github.com/AGlElectronics/con-services-gitops.git`,
  `git fetch template`, `git merge template/main`). Conflicts can only
  happen in `cluster.yaml`; keep your values.

## cluster.yaml reference

Every key, its default (from `charts/root/values.yaml`) and what it does.
**Required** keys must be set; all others are optional. Each resource
block has the form `{ requests: { cpu, memory }, limits: { cpu, memory } }`;
[Sizing and resources](sizing.md) lists all of them.

### Required

| Key | Default | What it does |
| --- | --- | --- |
| `domain` | `change-me` | Base domain. Every app lives on `<host>.<domain>`; the host labels are set per app ([Host names](#host-names)), by default `den`, `stash`, `hr`, `events` (Rally), `submit`, `finance`, `learn`, `wiki`, `desk`, `tasks`, `auth` and `auth-admin` |
| `git.repoURL` | `change-me` | HTTPS URL of your copy; every Application reads it |
| `acme.email` | `change-me` | Let's Encrypt account e-mail |
| `s3.endpoint` | `change-me` | HTTPS URL of the S3 service, without bucket |
| `s3.region` | `change-me` | S3 region |
| `s3.bucketPrefix` | `change-me` | Prefix of every bucket name |
| `s3.fqdns` | `[change-me]` | Host names of the endpoint, allowed in the egress network policies |
| `den.backupAgeRecipients` | `change-me` | age public key(s), comma-separated, Den encrypts its backups to |

### Git, certificates, S3

| Key | Default | What it does |
| --- | --- | --- |
| `git.targetRevision` | `main` | Branch or tag of your copy that Argo CD follows |
| `acme.issuer` | `letsencrypt-staging` | Issuer of the wildcard certificate; set `letsencrypt-prod` once staging works |
| `acme.dns01.provider` | `cloudflare` | `cloudflare` (token in OpenBao `conservices/infra/cloudflare`) or `custom` |
| `acme.dns01.solvers` | `[]` | With `custom`: cert-manager ACME solvers ([format](https://cert-manager.io/docs/configuration/acme/dns01/)) |
| `s3.pathStyle` | `true` | `true`: `https://<endpoint>/<bucket>`; `false`: `https://<bucket>.<endpoint>` |
| `s3.backup.endpoint`, `s3.backup.region` | empty (same as `s3.*`) | Separate S3 service for PostgreSQL and Den backups (recommended: another region) |
| `s3.backup.pathStyle` | empty (same as `s3.pathStyle`) | Addressing style of the backup service |
| `s3.backup.fqdns` | `[]` | Host names of the backup endpoint; required when it differs |

### Root Application and profile

| Key | Default | What it does |
| --- | --- | --- |
| `rootApplication.name` | `conservices-stack` | Name of the root Application `install-root` creates. Must not be the name of an Application the template renders (`den`, `keycloak`, ...). Choose it before you run `install-root`: the template has no procedure for renaming a running root Application |
| `profile` | `standard` | `standard`: highly available, needs 3 or more nodes. `small`: for 1 or 2 nodes, **not** highly available: PostgreSQL and Keycloak with 1 instance, no PodDisruptionBudgets, nothing that refuses to share a node. Keys you set yourself (`postgres.instances`, `keycloak.instances`, `den.values.ha.*`, `modules.<name>.values.ha.*`) still win ([Sizing: Small profile](sizing.md#small-profile)) |

### Images, charts, modules

Every app has its own version `MAJOR.MINOR.PATCH-BUILD`, which is both the
tag of all its images and, without `-BUILD`, the Git tag of its chart:
`modules.hr.version: "1.12.1-1"` means the images `hr-*:1.12.1-1` and the
chart at the tag `hr/v1.12.1` of `charts.repoURL`. A module's `MAJOR`
must equal Den's `MAJOR` (`den.version`); otherwise the chart stops, for
example with `hr 2.3.0 needs Den 2.x, but den.version is 1.4.0`.
The rules behind the numbers: [Versions and upgrades](../operations/versioning.md).

| Key | Default | What it does |
| --- | --- | --- |
| `den.version` | `1.0.0-1` | Den's release (`MAJOR.MINOR.PATCH-BUILD`, never `latest`) |
| `den.chartRevision` | empty (`den/v<MAJOR.MINOR.PATCH>`) | Git revision of `charts.repoURL` with Den's chart. Leave empty; set it only to test a chart that is not released yet, and never to a branch in production |
| `den.values` | `{}` | Extra values for the Den chart. The root chart already sets `preregisterModules` from the enabled modules |
| `images.pullSecret.enabled` | `false` | Create the Secret `ghcr-pull` from OpenBao `conservices/infra/ghcr` in every Con Services namespace and use it (private images only) |
| `charts.repoURL` | `https://github.com/AGlElectronics/con-services.git` | Where the Den and module charts come from |
| `modules.<name>.enabled` | `false` | Install the module; `<name>` is `stash`, `hr`, `rally`, `finance`, `learn`, `wiki`, `desk` or `tasks`. Opt-in: `cluster.yaml` lists all eight under *Pick the modules to run*. An enabled module is listed on Den's Modules page as unpaired and waits for Den until you pair it ([Den and the modules](apps.md#pair-the-modules)). With none enabled, only Den runs |
| `modules.<name>.version` | `1.0.0-1` | The module's release (`MAJOR.MINOR.PATCH-BUILD`); its `MAJOR` must equal Den's |
| `modules.<name>.chartRevision` | empty (`<name>/v<MAJOR.MINOR.PATCH>`) | Git revision of `charts.repoURL` with the module's chart, like `den.chartRevision` |
| `modules.<name>.accessConfig` | empty | The module's access configuration (TOML text); empty uses the template's default file. Stash, Rally, Learn, Wiki, Desk, Tasks |
| `modules.<name>.values` | `{}` | Extra values for the module's chart. `den.mode` is always `required` and cannot be overridden here; the root chart stops if you try |
| `modules.rally.submit.enabled` | `false` | Rally's public submission site on `<modules.rally.submit.host>.<domain>` |
| `smtp.from` | empty (`no-reply@<domain>`) | Sender address of Learn's mail |

### Host names

Each app lives on `<host>.<domain>`. A host is one lowercase DNS label
(letters, digits and dashes, at most 63 characters, no dots: the wildcard
certificate `*.<domain>` covers exactly one level), and every app needs
its own. With `adminRoutes.longhorn` or `adminRoutes.hubble` on,
`longhorn` and `hubble` are taken too. Changing a host on a running
installation: [Identity: Changing a host name](identity.md#changing-a-host-name).

| Key | Default | What it does |
| --- | --- | --- |
| `den.host` | `den` | Den |
| `modules.stash.host` | `stash` | Stash |
| `modules.hr.host` | `hr` | HR |
| `modules.rally.host` | `events` | Rally |
| `modules.rally.submit.host` | `submit` | Rally's public submission site (with `modules.rally.submit.enabled`) |
| `modules.finance.host`, `.learn.host`, `.wiki.host`, `.desk.host`, `.tasks.host` | `finance`, `learn`, `wiki`, `desk`, `tasks` | The other modules |
| `keycloak.host` | `auth` | Sign-in (the OIDC issuer `https://<host>.<domain>/realms/conservices`) |
| `keycloak.adminHost` | `auth-admin` | Keycloak's admin console, on the internal Gateway only |

Example, Den on `portal.example.org` and sign-in on `login.example.org`
(add `host` to the entries that are already in your `cluster.yaml`; a
second `den:` block would replace the first):

```yaml
den:
  backupAgeRecipients: age1...
  version: "1.0.0-1"
  host: portal
keycloak:
  host: login
  adminHost: login-admin
```

### Network

| Key | Default | What it does |
| --- | --- | --- |
| `gateway.className` | `cilium` | GatewayClass of both Gateways |
| `gateway.public.loadBalancerIP`, `gateway.internal.loadBalancerIP` | empty | Fixed IP (Cilium LB IPAM annotation `lbipam.cilium.io/ips`); empty: any. Recommended: set both, otherwise Cilium may give the two Gateways each other's address |
| `gateway.public.annotations`, `gateway.internal.annotations` | `{}` | Extra annotations for the Gateway's Service (other load balancers) |
| `adminRoutes.longhorn` | `false` | Longhorn UI on `longhorn.<domain>` (internal; it has no login) |
| `adminRoutes.hubble` | `false` | Hubble UI on `hubble.<domain>` (internal) |

### Storage

| Key | Default | What it does |
| --- | --- | --- |
| `storage.className` | empty (cluster default) | StorageClass for the PostgreSQL volumes |
| `storage.longhornSingle.enabled` | `false` | Create StorageClass `longhorn-single` (1 Longhorn copy) and use it for PostgreSQL |
| `postgres.storage.className` | empty | StorageClass for PostgreSQL only, overrides the two keys above |
| `postgres.storage.size`, `postgres.storage.walSize` | `20Gi`, `10Gi` | PostgreSQL data and WAL volume sizes |

### Cluster prerequisites

Where the services the template uses but does not install
([Prerequisites](prerequisites.md)) run. The defaults match their upstream
charts installed with default names.

| Key | Default | What it does |
| --- | --- | --- |
| `openbao.server` | `https://openbao-active.openbao.svc:8200` | OpenBao's API as seen from External Secrets. Use an address that reaches only the unsealed leader (with the upstream chart: the Service `openbao-active`); the plain `openbao` Service also sends requests to sealed pods |
| `openbao.kvPath` | `conservices` | Mount path of Con Services' own KV version 2 engine (entries below `modules/` and `infra/`); the setup Job creates it |
| `openbao.caBundle.kind`, `.name`, `.key`, `.namespace` | `ConfigMap`, `openbao-ca`, `ca.crt`, empty (`externalSecrets.namespace`) | The CA certificate that signed OpenBao's TLS certificate. Empty `name`: none (OpenBao has a publicly trusted certificate). The setup Job runs in this namespace |
| `openbao.auth.mountPath`, `openbao.auth.role` | `kubernetes`, `external-secrets` | Kubernetes auth method (the administrator's) and the role External Secrets logs in with (written by the setup Job) |
| `openbao.namespace` | `openbao` | Namespace of the OpenBao pods; the setup Job's NetworkPolicy allows only that namespace. Empty: no NetworkPolicy (OpenBao outside the cluster) |
| `openbao.setup.enabled` | `true` | The Application `openbao-setup` (wave -5, manual sync): a Job that enables the KV engine and writes External Secrets' role, after you review it and press Sync. `false`: the OpenBao administrator does both ([Without the setup Job](secrets-openbao.md#without-the-setup-job)) |
| `openbao.setup.role`, `openbao.setup.serviceAccount` | `conservices-setup`, `conservices-openbao-setup` | OpenBao role the Job logs in with, and the Job's service account; the administrator's step binds one to the other |
| `openbao.setup.image` | `quay.io/openbao/openbao:2.7.2` | Image of the setup Job (it needs the `bao` CLI and a shell) |
| `externalSecrets.namespace`, `externalSecrets.serviceAccount` | `external-secrets`, `external-secrets` | Namespace and service account of External Secrets Operator |
| `postgres.operatorNamespace` | `cnpg-system` | Namespace of the CloudNativePG operator and the Barman Cloud plugin; the database's network policy lets it in |
### Components

| Key | Default | What it does |
| --- | --- | --- |
| `postgres.instances` | empty (`3`; `1` with `profile: small`) | PostgreSQL instances (1 primary, the rest standbys; synchronous when more than 1) |
| `postgres.resources` | 250m/1Gi to 2/1Gi | Each PostgreSQL instance |
| `postgres.backup.schedule` | `0 15 2 * * *` | Base backup time (six fields, seconds first): 02:15 every day |
| `postgres.backup.retention` | `30d` | How long backups are kept |
| `postgres.backup.sidecarResources` | 50m/128Mi to 500m/512Mi | Barman Cloud sidecar in every PostgreSQL pod (WAL archiving) |
| `keycloakOperator.resources` | 100m/256Mi to 500m/512Mi | Keycloak operator |
| `keycloak.instances` | empty (`2`; `1` with `profile: small`) | Keycloak pods |
| `keycloak.resources` | 250m/1Gi to 2/2Gi | Each Keycloak pod |
| `keycloak.smtp.enabled` | `true` | Realms send mail through OpenBao `conservices/infra/keycloak/smtp` |

## Troubleshooting

**`install-root.sh` (or `install-root.ps1`) prints `cluster.yaml is not complete`**
:   The listed keys are still `change-me` or empty. Set them, push, and run
    the script again.

**The chart stops with `<module> X.Y.Z needs Den N.x, but den.version is ...`**
:   A module's `MAJOR` must equal Den's. Pick the module release made for
    your Den `MAJOR`, or upgrade Den and every module together
    ([Upgrading](#upgrading)).

**The chart stops with `at '/den/host': ... does not match pattern` or `... both use the host ...`**
:   A host label contains a dot or capital letters, or two apps share one.
    Use one label per app, for example `den.host: portal`, not
    `portal.example.org` ([Host names](#host-names)).

**`keycloak-operator` is `Degraded`; its pod crash-loops with `timeout getting a connection to 10.43.0.1:443`**
:   The operator cannot reach the Kubernetes API: `conservices-identity`
    denies all traffic by default. Template releases before this fix kept
    the operator's permission (`CiliumNetworkPolicy keycloak-operator-apiserver`)
    in the `keycloak` Application, which waits for the operator: a
    deadlock. Merge the current template release; the policy now comes with
    `keycloak-operator` itself. Check:
    `kubectl -n conservices-identity get ciliumnetworkpolicy keycloak-operator-apiserver`.
    Right after the merge the operator may restart once while the policy
    moves from one Application to the other.

**A module or Den stays `ImagePullBackOff` after you changed its version**
:   The tag does not exist (`manifest unknown`); see
    [Versions and upgrades: Troubleshooting](../operations/versioning.md#troubleshooting).
    Set a version that exists and push: Den and the modules are in the last
    sync wave, so the fix is applied even while they are `Degraded`.

**The root Application shows `ComparisonError: repository not found` or `authentication required`**
:   Wrong `git.repoURL`, or a private copy without credentials (step 3).
    Check with `kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=repository`.

**The root Application is `Unknown` with `values don't meet the specifications of the schema`**
:   The pushed `cluster.yaml` has a misspelt key. Run
    `helm template root charts/root -f cluster.yaml > /dev/null` locally;
    it shows the same message with the key's path.

**Every Application starts at once instead of wave by wave**
:   The Application health check is missing from `argocd-cm`; check
    `kubectl -n argocd get cm argocd-cm -o yaml | grep health.argoproj.io_Application`
    and add the block from
    [Prerequisites: Argo CD](prerequisites.md#9-argo-cd).

**`install-root.sh` stops with `missing: ...`**
:   A prerequisite is not installed, or not where `cluster.yaml` says.
    See [Prerequisites](prerequisites.md#troubleshooting).

**Nothing installs after `pki`; `openbao-setup` is `OutOfSync`**
:   Argo CD waits for you to review and sync `openbao-setup`; see
    [Secrets with OpenBao](secrets-openbao.md#3-review-and-sync-openbao-setup).

**`openbao-setup` is `Degraded`**
:   The Job failed. `kubectl -n external-secrets logs job/conservices-openbao-setup`
    says why, usually that the administrator's step (step 4) was not done.
    See [Secrets with OpenBao](secrets-openbao.md#troubleshooting).

**`cluster-secret-store` stays `Degraded`**
:   External Secrets cannot log in to OpenBao, or a random secret could not
    be created. `kubectl get clustersecretstore openbao` and
    `kubectl get pushsecret -n external-secrets` show why; the usual causes
    are that `openbao-setup` did not run, OpenBao is sealed, or
    `openbao.server` / `openbao.caBundle` do not match your OpenBao. See
    [Secrets with OpenBao](secrets-openbao.md#troubleshooting).

**`letsencrypt` or `gateway` stays `Progressing` or `Degraded`**
:   Usually the DNS token: `kubectl -n cert-manager get externalsecret cloudflare-api-token`
    must show `SecretSynced`, and `kubectl get certificate -A` shows the
    wildcard certificate's progress. See
    [DNS and certificates](dns-and-certificates.md#troubleshooting).

**The Redis HA pods stay `Pending`**
:   They need three schedulable nodes (one pod per node); see
    [Prerequisites](prerequisites.md#1-kubernetes-and-nodes).

**A sync fails with `the server could not find the requested resource` for a CRD kind**
:   The CRD comes from an earlier wave that is not Healthy yet. Fix that
    Application first; the automatic retry picks the rest up.

**Nothing new installs for a long time, and an early Application such as `letsencrypt` or `keycloak-operator` is `Degraded`**
:   An infrastructure wave that is not `Healthy` blocks every later wave
    ([step 7](#7-do-the-steps-only-a-person-can-do)). Find the lowest
    wave that is not `Healthy`, open it with
    `kubectl -n argocd describe application <name>` (or in the UI), and fix
    its cause; usually a missing or wrong credential in OpenBao. The later
    waves continue by themselves within a few minutes.

**`kubectl patch application openbao-setup` fails in PowerShell with `unable to parse` or `invalid character`**
:   Windows PowerShell 5.1 stripped the double quotes from the JSON. Use
    the `--patch-file` variant from
    [Sync openbao-setup by hand](#sync-openbao-setup-by-hand).

**`cd con-services-gitops` fails after cloning: `Cannot find path` or `No such file or directory`**
:   `git clone` without a folder name uses the repository's name, and your
    copy has another one. Clone again with the folder name at the end
    ([step 1](#1-copy-the-template)), or `cd` into the folder `git clone`
    created and use that folder wherever the guide says
    `con-services-gitops`.

**You pushed a fix to `cluster.yaml`, but the root Application keeps `Syncing` or retrying an old commit**
:   An infrastructure Application of an earlier wave is not `Healthy`, and
    the root sync waits for it. See the next section.

### An infrastructure Application is Degraded and later waves never start

**What you see.** In `kubectl get applications -n argocd`, an
infrastructure Application (waves -8 to 4: `pki`, `cluster-secret-store`,
`letsencrypt`, `gateway`, `keycloak-operator`, `postgres`, `keycloak`) is
`Degraded` or stays `Progressing`, and the root Application
`conservices-stack` shows one of:

```text
waiting for healthy state of argoproj.io/Application/keycloak
one or more synchronization tasks completed unsuccessfully
```

**Why.** Argo CD applies the waves in order and waits for each to be
`Healthy`. A `Degraded` Application fails the root sync (it is then
retried up to 10 times, each retry with your newest commit); one that
stays `Progressing` keeps the sync running without end. While a sync is
running, a new commit is not applied.

**First, fix the cause** in the lowest wave that is not `Healthy`:
`kubectl -n argocd describe application <name>` and the troubleshooting
entries above usually name it (a credential missing in OpenBao, a DNS
token, a bucket). Then:

- If the fix is **in OpenBao, DNS or the cluster** (not in Git), nothing
  more is needed: the Application turns `Healthy` and the waves continue
  within a few minutes.
- If the fix is **a file of that Application in your copy** (under
  `charts/` or `components/`), push it: every child Application reads Git
  by itself and syncs the fix without waiting for the root.
- If the fix is **in `cluster.yaml`**, the values reach the child only
  through the root Application, whose sync is stuck. End it and apply the
  one child by hand, as below.

**In the Argo CD web UI:**

1. Open the Application `conservices-stack`.
2. If the top bar shows the sync as running (**Syncing**), click
   **Terminate** (in the panel that opens when you click the sync status)
   and confirm.
3. Click **Sync**. In the panel, under the list of resources, untick
   everything except the Application you fixed (for example `keycloak`),
   and click **Synchronize**. This applies only that child with the new
   values (a selective sync); the child then syncs itself.
4. When the child is `Healthy`, click **Sync** on `conservices-stack`
   again with every resource ticked, so the later waves follow.

**Without the UI** (replace `keycloak` with your Application):

=== "Linux / macOS"

    ```sh
    # 1. End the running sync (same as Terminate).
    kubectl -n argocd patch application conservices-stack --type merge \
      -p '{"status":{"operationState":{"phase":"Terminating"}}}'
    # 2. Apply only the fixed child.
    kubectl -n argocd patch application conservices-stack --type merge \
      -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"resources":[{"group":"argoproj.io","kind":"Application","name":"keycloak"}]}}}'
    # 3. Once it is Healthy: sync everything again.
    kubectl -n argocd patch application conservices-stack --type merge \
      -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'
    ```

=== "Windows (PowerShell)"

    Windows PowerShell 5.1 removes the double quotes from JSON passed to
    programs, so the patches go through files:

    ```powershell
    # 1. End the running sync (same as Terminate).
    @'
    status:
      operationState:
        phase: Terminating
    '@ | Set-Content -Encoding ascii terminate.yaml
    kubectl -n argocd patch application conservices-stack --type merge --patch-file terminate.yaml

    # 2. Apply only the fixed child.
    @'
    operation:
      initiatedBy:
        username: admin
      sync:
        resources:
          - group: argoproj.io
            kind: Application
            name: keycloak
    '@ | Set-Content -Encoding ascii sync-one.yaml
    kubectl -n argocd patch application conservices-stack --type merge --patch-file sync-one.yaml

    # 3. Once it is Healthy: sync everything again.
    @'
    operation:
      initiatedBy:
        username: admin
      sync: {}
    '@ | Set-Content -Encoding ascii sync-all.yaml
    kubectl -n argocd patch application conservices-stack --type merge --patch-file sync-all.yaml
    Remove-Item terminate.yaml, sync-one.yaml, sync-all.yaml
    ```

Each command prints `application.argoproj.io/conservices-stack patched`.
Follow the result with `kubectl get applications -n argocd -w`. With the
`argocd` CLI the same steps are `argocd app terminate-op conservices-stack`,
`argocd app sync conservices-stack --resource argoproj.io:Application:keycloak`
and `argocd app sync conservices-stack`.

**So it never hangs without end:** whoever runs Argo CD can set
`controller.sync.timeout.seconds` in `argocd-cmd-params-cm` (for example
`"1800"`); a sync that has not finished after that time fails and is
retried with the newest commit. Den and the modules never need this
recovery: they are in the last wave, which Argo CD does not wait for.

Next: [DNS and certificates](dns-and-certificates.md).
