# Argo CD and cluster.yaml

This is the main installation guide. You copy the template, fill in its
one settings file, install Argo CD and apply one object; Argo CD then
installs every component in the right order. With a cluster that meets the
[Prerequisites](prerequisites.md), plan about one hour.

## Terms used on this page

**Argo CD**
:   A program in the cluster that reads a Git repository and makes the
    cluster equal to it ([documentation](https://argo-cd.readthedocs.io/)).

**Application**
:   An Argo CD object that says "render this chart and apply it to that
    namespace". Each component (cert-manager, OpenBao, Den, ...) is one
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

## How the template is organised

```text
cluster.yaml              <- the only file you edit
charts/root/              <- renders every Application from cluster.yaml
  values.yaml             <- defaults for every setting (do not edit; override in cluster.yaml)
  values.schema.json      <- rejects unknown or misspelt keys
charts/<component>/       <- small charts for cluster-specific objects (gateway, postgres, keycloak, ...)
values/<component>.yaml   <- fixed settings for the upstream charts (cert-manager, OpenBao, ...)
components/               <- fixed Kustomize folders (internal CA, namespaces, ...)
bootstrap/                <- install-root.sh, Argo CD values, OpenBao scripts, example-k3s/
examples/cluster.example-filled.yaml   <- a complete example with example.org
```

Den and the module charts are not copied into the template: Argo CD reads
them from the main repository
[`AGlElectronics/con-services`](https://github.com/AGlElectronics/con-services)
(`deploy/charts/<app>`), at the release in `charts.targetRevision`.

## 1. Copy the template

1. On GitHub, open
   [`AGlElectronics/con-services-gitops`](https://github.com/AGlElectronics/con-services-gitops)
   and choose **Use this template → Create a new repository**. Make it
   **private**: it will describe your installation.
2. Clone your copy:

    ```sh
    git clone https://github.com/your-org/con-services-gitops.git
    cd con-services-gitops
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

2. Set the optional values you need. The end of `cluster.yaml` shows the
   common ones commented out; the [full reference](#clusteryaml-reference)
   is below. Typical choices:
    - Gateway IPs handed out by Cilium (`loadBalancer.ciliumL2`), see
      [DNS and certificates](dns-and-certificates.md#1-choose-the-gateway-ips).
    - `oidcHairpin.mode: coredns-custom` on k3s or AKS, see
      [DNS and certificates](dns-and-certificates.md#inside-the-cluster-reaching-keycloak).
    - `storage.longhornSingle.enabled: true` with Longhorn.
    - The modules to run: in the block *Pick the modules to run*, set
      `enabled: true` for each one you want. All eight are off by default;
      Den is always deployed. Each module waits for Den until you pair it
      ([Den and the modules](apps.md#deploy)).
3. Check that nothing is missing:

    ```sh
    grep -n change-me cluster.yaml
    ```

    No output means every required value is set. Then let the chart check
    the whole file:

    ```sh
    helm template root charts/root -f cluster.yaml > /dev/null && echo OK
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

    ```sh
    git add cluster.yaml && git commit -m "Configure cluster" && git push
    ```

## 3. Install Argo CD

The template's Argo CD values install Argo CD v3.6.1 highly available: 2
replicas of the API server, the repo-server and the ApplicationSet
controller with PodDisruptionBudgets, Redis with Sentinel (3 Redis and 3
HAProxy pods on 3 nodes), resource requests and limits on every container,
and the health check for Application objects that makes sync waves wait
for each other.

```sh
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd --version 10.14.0 -n argocd --create-namespace \
  -f bootstrap/argocd/values.yaml
kubectl -n argocd rollout status deploy/argocd-server
```

```text
deployment "argocd-server" successfully rolled out
```

**Private copy?** Give Argo CD a read-only credential for it, for example a
fine-grained GitHub token with *Contents: read* on that one repository:

```sh
kubectl -n argocd create secret generic repo-gitops \
  --from-literal=type=git \
  --from-literal=url=https://github.com/your-org/con-services-gitops.git \
  --from-literal=username=git \
  --from-literal=password=change-me
kubectl -n argocd label secret repo-gitops argocd.argoproj.io/secret-type=repository
```

That token is a real secret: keep it in your password manager, see
[Secrets](../operations/secrets.md).

## 4. Apply the root Application

```sh
bash bootstrap/install-root.sh
```

```text
==> Checking /home/you/con-services-gitops/cluster.yaml
==> Argo CD will read https://github.com/your-org/con-services-gitops.git
application.argoproj.io/root created

Root Application applied. Follow the sync waves with:

  kubectl get applications -n argocd -w
```

The script renders only the root Application from your `cluster.yaml`
(the same checks as in step 2) and applies it. `--dry-run` prints it
without applying.

## 5. Watch the sync waves

```sh
kubectl get applications -n argocd -w
```

| Wave | Applications | Done when |
| --- | --- | --- |
| -10 | `cilium-lb` (only with `loadBalancer.ciliumL2.enabled`) | IP pool and L2 policy exist |
| -9 | `cert-manager` | 2 replicas each of controller, webhook, cainjector |
| -8 | `trust-manager`, `longhorn-storage` (only with `storage.longhornSingle.enabled`) | trust-manager running; StorageClass `longhorn-single` |
| -7 | `pki` | ClusterIssuer `conservices-internal-ca` ready |
| -6 | `external-secrets` | External Secrets Operator running |
| -5 | `openbao` | **waits for you**: initialise and unseal OpenBao (step 6) |
| -4 | `cluster-secret-store`, `oidc-hairpin` (only with `oidcHairpin.mode: coredns-custom`) | ClusterSecretStore `openbao` valid |
| -3 | `letsencrypt` | ClusterIssuers `letsencrypt-staging` and `letsencrypt-prod` ready |
| -2 | `gateway` | certificate `wildcard-tls` issued, Gateways `public` and `internal` programmed |
| -1 | `argocd` (only with `argocd.selfManage`) | Argo CD manages itself; UI at `https://argocd.<domain>` |
| 0 | `platform-namespaces` | namespaces `cnpg-system`, `conservices-data`, `conservices-identity` |
| 1 | `cnpg-operator` | CloudNativePG operator running |
| 2 | `cnpg-barman-cloud`, `keycloak-operator` | both operators running |
| 3 | `postgres` | PostgreSQL cluster `conservices-pg` healthy, 3 instances ([Data](data.md)) |
| 4 | `keycloak` | Keycloak ready, realms imported ([Identity](identity.md)) |
| 5 | `den` | Den running ([Den and the modules](apps.md)) |
| 10 | one per enabled module | the module running |
| 20, 21 | `arc-controller`, `arc-runners` (only with `arc.enabled`) | [Self-hosted CI runners](self-hosted-runners.md) |

## 6. Do the steps only a person can do

Argo CD waits at these points and continues by itself once they are done:

1. **Wave -5, OpenBao:** the `openbao` Application stays `Progressing`
   because a new OpenBao is uninitialised and sealed. Follow
   [Secrets with OpenBao](secrets-openbao.md): `openbao-init.sh`, then
   `openbao-seed.sh`, which asks for your S3 keys, SMTP server and DNS
   token and generates every other secret.
2. **Wave -2, certificates and DNS:** create the DNS records and the port
   forward ([DNS and certificates](dns-and-certificates.md)).
3. **Wave 3, buckets:** the buckets must exist before PostgreSQL's first
   backup and before the apps start ([Data](data.md)).

## 7. What "done" looks like

```sh
kubectl get applications -n argocd
```

```text
NAME                   SYNC STATUS   HEALTH STATUS
argocd                 Synced        Healthy
cert-manager           Synced        Healthy
cluster-secret-store   Synced        Healthy
cnpg-barman-cloud      Synced        Healthy
cnpg-operator          Synced        Healthy
den                    Synced        Healthy
desk                   Synced        Healthy
external-secrets       Synced        Healthy
finance                Synced        Healthy
gateway                Synced        Healthy
hr                     Synced        Healthy
keycloak               Synced        Healthy
keycloak-operator      Synced        Healthy
learn                  Synced        Healthy
letsencrypt            Synced        Healthy
openbao                Synced        Healthy
pki                    Synced        Healthy
platform-namespaces    Synced        Healthy
postgres               Synced        Healthy
rally                  Synced        Healthy
root                   Synced        Healthy
stash                  Synced        Healthy
tasks                  Synced        Healthy
trust-manager          Synced        Healthy
wiki                   Synced        Healthy
```

Then open `https://den.<domain>` and sign in ([Den and the modules](apps.md)).
Argo CD itself is at `https://argocd.<domain>` on the **internal** Gateway
([Internal hostnames](dns-and-certificates.md#internal-hostnames)).

## Log in to Argo CD

Before the internal Gateway exists, use a port-forward:

```sh
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8443:443
```

Open <https://localhost:8443> (self-signed certificate at this point), user
`admin`, the password printed by the first command. Change it (**User Info
→ Update Password**) and delete the initial secret:

```sh
kubectl -n argocd delete secret argocd-initial-admin-secret
```

## Changing settings later

Edit `cluster.yaml`, run `helm template root charts/root -f cluster.yaml > /dev/null`
to check it, commit and push. The root Application picks the change up
within three minutes (or press **Refresh** on `root` in the UI).

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

- **Con Services:** set `images.tag` and `charts.targetRevision` to the new
  release and read the [changelog](https://github.com/AGlElectronics/con-services/blob/main/CHANGELOG.md)
  first. Releases that need action start with **BREAKING:**.
- **Argo CD:** with `argocd.selfManage: true`, change the chart version in
  `charts/root/templates/infrastructure.yaml` (from a new template
  release), push, and Argo CD upgrades itself. Read the
  [upgrade notes](https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/overview/)
  first.
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
| `domain` | `change-me` | Base domain. Apps on `<app>.<domain>` (Rally on `events.`, its submission site on `submit.`), Keycloak on `auth.` and `auth-admin.`, Argo CD on `argocd.`, OpenBao on `bao.` |
| `git.repoURL` | `change-me` | HTTPS URL of your copy; every Application reads it |
| `acme.email` | `change-me` | Let's Encrypt account e-mail |
| `s3.endpoint` | `change-me` | HTTPS URL of the S3 service, without bucket |
| `s3.region` | `change-me` | S3 region |
| `s3.bucketPrefix` | `change-me` | Prefix of every bucket name |
| `s3.fqdns` | `[change-me]` | Host names of the endpoint, allowed in the egress network policies |
| `den.backupAgeRecipients` | `change-me` | age public key(s), comma-separated, Den encrypts its backups to |
| `loadBalancer.ciliumL2.blocks`, `gateway.public.loadBalancerIP`, `gateway.internal.loadBalancerIP` | empty | Required only with `loadBalancer.ciliumL2.enabled: true` |

### Git, certificates, S3

| Key | Default | What it does |
| --- | --- | --- |
| `git.targetRevision` | `main` | Branch or tag of your copy that Argo CD follows |
| `acme.issuer` | `letsencrypt-staging` | Issuer of the wildcard certificate; set `letsencrypt-prod` once staging works |
| `acme.dns01.provider` | `cloudflare` | `cloudflare` (token in OpenBao `kv/infra/cloudflare`) or `custom` |
| `acme.dns01.solvers` | `[]` | With `custom`: cert-manager ACME solvers ([format](https://cert-manager.io/docs/configuration/acme/dns01/)) |
| `acme.recursiveNameservers` | `1.1.1.1:53,8.8.8.8:53` | Resolvers cert-manager uses to check DNS-01 records |
| `s3.pathStyle` | `true` | `true`: `https://<endpoint>/<bucket>`; `false`: `https://<bucket>.<endpoint>` |
| `s3.backup.endpoint`, `s3.backup.region` | empty (same as `s3.*`) | Separate S3 service for PostgreSQL and Den backups (recommended: another region) |
| `s3.backup.pathStyle` | empty (same as `s3.pathStyle`) | Addressing style of the backup service |
| `s3.backup.fqdns` | `[]` | Host names of the backup endpoint; required when it differs |

### Images, charts, modules

| Key | Default | What it does |
| --- | --- | --- |
| `images.tag` | `1.0.0-1` | Tag of every Con Services image (`MAJOR.MINOR.PATCH-BUILD`); never `latest` |
| `images.pullSecret.enabled` | `false` | Create the Secret `ghcr-pull` from OpenBao `kv/infra/ghcr` in every Con Services namespace and use it (private images only) |
| `charts.repoURL` | `https://github.com/AGlElectronics/con-services.git` | Where the Den and module charts come from |
| `charts.targetRevision` | `v1.1.0` | Release of those charts (a tag of `con-services`, never a branch) |
| `den.imageTag` | empty (`images.tag`) | Den's image tag |
| `den.values` | `{}` | Extra values for the Den chart. The root chart already sets `preregisterModules` from the enabled modules |
| `modules.<name>.enabled` | `false` | Install the module; `<name>` is `stash`, `hr`, `rally`, `finance`, `learn`, `wiki`, `desk` or `tasks`. Opt-in: `cluster.yaml` lists all eight under *Pick the modules to run*. An enabled module is listed on Den's Modules page as unpaired and waits for Den until you pair it ([Den and the modules](apps.md#pair-the-modules)). With none enabled, only Den runs |
| `modules.<name>.imageTag` | empty (`images.tag`) | The module's image tag |
| `modules.<name>.accessConfig` | empty | The module's access configuration (TOML text); empty uses the template's default file. Stash, Rally, Learn, Wiki, Desk, Tasks |
| `modules.<name>.values` | `{}` | Extra values for the module's chart. `den.mode` is always `required` and cannot be overridden here; the root chart stops if you try |
| `modules.rally.submit.enabled` | `false` | Rally's public submission site on `submit.<domain>` |
| `smtp.from` | empty (`no-reply@<domain>`) | Sender address of Learn's mail |

### Network

| Key | Default | What it does |
| --- | --- | --- |
| `gateway.className` | `cilium` | GatewayClass of both Gateways |
| `gateway.public.loadBalancerIP`, `gateway.internal.loadBalancerIP` | empty | Fixed IP (Cilium LB IPAM annotation `lbipam.cilium.io/ips`); empty: any |
| `gateway.public.annotations`, `gateway.internal.annotations` | `{}` | Extra annotations for the Gateway's Service (other load balancers) |
| `loadBalancer.ciliumL2.enabled` | `false` | Create a Cilium LB IPAM pool and L2 announcement policy |
| `loadBalancer.ciliumL2.blocks` | `[]` | CIDRs (`192.0.2.240/29`) or ranges (`{start: 192.0.2.240, stop: 192.0.2.247}`) |
| `loadBalancer.ciliumL2.interfaces` | `[]` | Node interfaces to announce on (regular expressions); empty: all |
| `oidcHairpin.mode` | `none` | `coredns-custom`: write `kube-system/coredns-custom` so pods reach `auth.<domain>` in-cluster (k3s, AKS) |
| `adminRoutes.openbao` | `true` | OpenBao UI on `bao.<domain>` (internal Gateway) |
| `adminRoutes.longhorn` | `false` | Longhorn UI on `longhorn.<domain>` (internal; it has no login) |
| `adminRoutes.hubble` | `false` | Hubble UI on `hubble.<domain>` (internal) |

### Storage

| Key | Default | What it does |
| --- | --- | --- |
| `storage.className` | empty (cluster default) | StorageClass for the PostgreSQL and OpenBao volumes |
| `storage.longhornSingle.enabled` | `false` | Create StorageClass `longhorn-single` (1 Longhorn copy) and use it for PostgreSQL and OpenBao |
| `openbao.storage.className`, `postgres.storage.className` | empty | Per-component StorageClass, overrides the two keys above |
| `openbao.storage.dataSize`, `openbao.storage.auditSize` | `10Gi`, `5Gi` | OpenBao volume sizes |
| `postgres.storage.size`, `postgres.storage.walSize` | `20Gi`, `10Gi` | PostgreSQL data and WAL volume sizes |

### Components

| Key | Default | What it does |
| --- | --- | --- |
| `certManager.replicas` | `2` | Replicas of controller, webhook and cainjector |
| `certManager.resources.{controller,webhook,cainjector,startupapicheck}` | see [Sizing](sizing.md) | Resources |
| `trustManager.replicas`, `trustManager.resources.{controller,defaultPackage}` | `2` | trust-manager |
| `externalSecrets.replicas`, `externalSecrets.resources.{controller,webhook,certController}` | `2` | External Secrets Operator |
| `openbao.replicas` | `3` | Raft voters (1, 3 or 5) |
| `openbao.resources` | 100m/256Mi to 1/512Mi | OpenBao server |
| `cnpg.operator.replicas`, `cnpg.operator.resources` | `2` | CloudNativePG operator |
| `cnpg.barmanCloud.replicas`, `cnpg.barmanCloud.resources` | `1` | Barman Cloud plugin |
| `cnpg.barmanCloud.sidecarResources` | 50m/128Mi to 500m/512Mi | Backup sidecar in every PostgreSQL pod |
| `postgres.instances` | `3` | PostgreSQL instances (1 primary, the rest standbys; synchronous when more than 1) |
| `postgres.resources` | 250m/1Gi to 2/1Gi | Each PostgreSQL instance |
| `postgres.backup.schedule` | `0 15 2 * * *` | Base backup time (six fields, seconds first): 02:15 every day |
| `postgres.backup.retention` | `30d` | How long backups are kept |
| `keycloakOperator.resources` | 100m/256Mi to 500m/512Mi | Keycloak operator |
| `keycloak.instances` | `2` | Keycloak pods |
| `keycloak.resources` | 250m/1Gi to 2/2Gi | Each Keycloak pod |
| `keycloak.smtp.enabled` | `true` | Realms send mail through OpenBao `kv/conservices/keycloak/smtp` |
| `argocd.selfManage` | `true` | Argo CD manages its own installation with `bootstrap/argocd/values.yaml` |
| `<component>.values` | `{}` | Extra values for that upstream chart (`certManager`, `trustManager`, `externalSecrets`, `openbao`, `cnpg.operator`, `cnpg.barmanCloud`, `argocd`) |

### Self-hosted CI runners

| Key | Default | What it does |
| --- | --- | --- |
| `arc.enabled` | `false` | Install Actions Runner Controller and a runner scale set |
| `arc.githubConfigUrl` | `https://github.com/your-org` | Organisation or repository the runners register with (must be changed when enabled) |
| `arc.runnerScaleSetName` | `arc-conservices` | Name used in `runs-on:` |
| `arc.minRunners`, `arc.maxRunners` | `0`, `3` | Idle and maximum runners |
| `arc.runnerImage` | `ghcr.io/aglelectronics/ci-runner:2.338.2-1` | Runner image |
| `arc.buildkitImage` | `moby/buildkit:v0.34.2-rootless` | Image build sidecar |
| `arc.testDatabaseImage` | `postgres:16.15-alpine` | Test database sidecar |
| `arc.resources.{controller,listener,runner,buildkit,testDatabase}` | see [Sizing](sizing.md#self-hosted-runners) | Resources |

## Troubleshooting

**`install-root.sh` prints `cluster.yaml is not complete`**
:   The listed keys are still `change-me` or empty. Set them, push, and run
    the script again.

**The root Application shows `ComparisonError: repository not found` or `authentication required`**
:   Wrong `git.repoURL`, or a private copy without credentials (step 3).
    Check with `kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=repository`.

**The root Application is `Unknown` with `values don't meet the specifications of the schema`**
:   The pushed `cluster.yaml` has a misspelt key. Run
    `helm template root charts/root -f cluster.yaml > /dev/null` locally;
    it shows the same message with the key's path.

**Every Application starts at once instead of wave by wave**
:   The Application health check is missing from `argocd-cm`. It comes from
    `bootstrap/argocd/values.yaml`; check
    `kubectl -n argocd get cm argocd-cm -o yaml | grep argoproj.io_Application`.
    If Argo CD was installed without that file, run `helm upgrade` with it.

**`openbao` stays `Progressing` forever**
:   OpenBao is sealed. Run `openbao-init.sh` (first time) or
    `openbao-unseal.sh` (after restarts); see
    [Secrets with OpenBao](secrets-openbao.md).

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

**`argocd.<domain>` returns `upstream connect error` or `503`**
:   The Gateway cannot verify argocd-server's certificate. Check that the
    namespace has the internal CA bundle (`kubectl -n argocd get cm conservices-internal-ca`)
    and that the Certificate is ready (`kubectl -n argocd get certificate`).
    Never "fix" this with `wellKnownCACertificates`: with Cilium it
    silently sends plaintext.

Next: [DNS and certificates](dns-and-certificates.md).
