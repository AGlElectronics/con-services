# Argo CD and cluster.yaml

This is the main installation guide. You copy the template, fill in its
one settings file, connect it to your Argo CD, prepare OpenBao and apply one object;
Argo CD then installs every component in the right order. With a cluster
that meets the [Prerequisites](prerequisites.md) (including Argo CD,
cert-manager, External Secrets Operator, OpenBao and CloudNativePG, which
the template uses but does not install), plan about one hour.

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

## How the template is organised

```text
cluster.yaml              <- the only file you edit
charts/root/              <- renders every Application from cluster.yaml
  values.yaml             <- defaults for every setting (do not edit; override in cluster.yaml)
  values.schema.json      <- rejects unknown or misspelt keys
charts/<component>/       <- small charts for cluster-specific objects (gateway, postgres, keycloak, secret-store, ...)
components/               <- fixed Kustomize folders (internal CA, namespaces, ...)
bootstrap/                <- install-root.sh, OpenBao configure and seed scripts, reference Argo CD values
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
    - Fixed Gateway IPs from your Cilium LB IPAM pool
      (`gateway.public.loadBalancerIP`, `gateway.internal.loadBalancerIP`), see
      [DNS and certificates](dns-and-certificates.md#1-choose-the-gateway-ips).
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

## 3. Connect Argo CD

Argo CD is a prerequisite: the template does not install, upgrade or
expose it. Check that it has the health check for Application objects
([Prerequisites: Argo CD](prerequisites.md#9-argo-cd)); without it every
sync wave starts at once:

```sh
kubectl -n argocd get cm argocd-cm -o yaml | grep -c argoproj.io_Application
```

```text
1
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

## 4. Prepare and fill OpenBao

The template reads every secret from the cluster's OpenBao. Do this once
per cluster, with a token from whoever runs OpenBao:

```sh
BAO_TOKEN=change-me bash bootstrap/scripts/openbao-configure.sh
BAO_TOKEN=change-me bash bootstrap/scripts/openbao-seed.sh
```

The first script creates the KV engine, the Kubernetes login and the
read-only policy for External Secrets; the second generates the random
secrets and asks for your S3 keys, SMTP server and DNS token. Both are
explained, with their output, in
[Secrets with OpenBao](secrets-openbao.md).

## 5. Apply the root Application

```sh
bash bootstrap/install-root.sh
```

```text
==> Checking /home/you/con-services-gitops/cluster.yaml
==> Checking the cluster prerequisites
==> Prerequisites found
==> Argo CD will read https://github.com/your-org/con-services-gitops.git
application.argoproj.io/root created

Root Application applied. Follow the sync waves with:

  kubectl get applications -n argocd -w
```

The script renders only the root Application from your `cluster.yaml`
(the same checks as in step 2), checks that the
[prerequisites](prerequisites.md) are installed (the CRDs of cert-manager,
trust-manager, External Secrets, CloudNativePG and the Barman Cloud plugin,
External Secrets' service account and OpenBao's CA from `cluster.yaml`),
and applies it. `--dry-run` prints it without checking or applying;
`--skip-preflight` skips the prerequisite check.

## 6. Watch the sync waves

```sh
kubectl get applications -n argocd -w
```

| Wave | Applications | Done when |
| --- | --- | --- |
| -8 | `longhorn-storage` (only with `storage.longhornSingle.enabled`) | StorageClass `longhorn-single` |
| -7 | `pki` | ClusterIssuer `conservices-internal-ca` ready |
| -4 | `cluster-secret-store` | ClusterSecretStore `openbao` valid (needs step 4) |
| -3 | `letsencrypt` | ClusterIssuers `letsencrypt-staging` and `letsencrypt-prod` ready |
| -2 | `gateway` | certificate `wildcard-tls` issued, Gateways `public` and `internal` programmed |
| 0 | `platform-namespaces` | namespaces `conservices-data`, `conservices-identity` |
| 2 | `keycloak-operator` | Keycloak operator running |
| 3 | `postgres` | PostgreSQL cluster `conservices-pg` healthy, 3 instances ([Data](data.md)) |
| 4 | `keycloak` | Keycloak ready, realms imported ([Identity](identity.md)) |
| 5 | `den` | Den running ([Den and the modules](apps.md)) |
| 10 | one per enabled module | the module running |

## 7. Do the steps only a person can do

Argo CD waits at these points and continues by itself once they are done:

1. **Wave -4, secrets:** `cluster-secret-store` stays `Degraded` until
   OpenBao is prepared (step 4). An entry you skipped in `openbao-seed.sh`
   keeps the Application that reads it `Degraded`; run the script again.
2. **Wave -2, certificates and DNS:** create the DNS records and the port
   forward ([DNS and certificates](dns-and-certificates.md)).
3. **Wave 3, buckets:** the buckets must exist before PostgreSQL's first
   backup and before the apps start ([Data](data.md)).

## 8. What "done" looks like

```sh
kubectl get applications -n argocd
```

```text
NAME                   SYNC STATUS   HEALTH STATUS
cluster-secret-store   Synced        Healthy
den                    Synced        Healthy
desk                   Synced        Healthy
finance                Synced        Healthy
gateway                Synced        Healthy
hr                     Synced        Healthy
keycloak               Synced        Healthy
keycloak-operator      Synced        Healthy
learn                  Synced        Healthy
letsencrypt            Synced        Healthy
pki                    Synced        Healthy
platform-namespaces    Synced        Healthy
postgres               Synced        Healthy
rally                  Synced        Healthy
root                   Synced        Healthy
stash                  Synced        Healthy
tasks                  Synced        Healthy
wiki                   Synced        Healthy
```

Then open `https://den.<domain>` and sign in ([Den and the modules](apps.md)).

The same states are visible in Argo CD's UI, wherever your cluster exposes
it; the template does not publish it.

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
| `domain` | `change-me` | Base domain. Apps on `<app>.<domain>` (Rally on `events.`, its submission site on `submit.`), Keycloak on `auth.` and `auth-admin.` |
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
| `acme.dns01.provider` | `cloudflare` | `cloudflare` (token in OpenBao `kv/infra/cloudflare`) or `custom` |
| `acme.dns01.solvers` | `[]` | With `custom`: cert-manager ACME solvers ([format](https://cert-manager.io/docs/configuration/acme/dns01/)) |
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
| `openbao.kvPath` | `kv` | Mount path of the KV version 2 engine Con Services uses; `openbao-configure.sh` creates it |
| `openbao.caBundle.kind`, `.name`, `.key`, `.namespace` | `ConfigMap`, `openbao-ca`, `ca.crt`, empty (`externalSecrets.namespace`) | The CA certificate that signed OpenBao's TLS certificate. Empty `name`: none (OpenBao has a publicly trusted certificate) |
| `openbao.auth.mountPath`, `openbao.auth.role` | `kubernetes`, `external-secrets` | Kubernetes auth method and role External Secrets logs in with; `openbao-configure.sh` creates both |
| `externalSecrets.namespace`, `externalSecrets.serviceAccount` | `external-secrets`, `external-secrets` | Namespace and service account of External Secrets Operator |
| `postgres.operatorNamespace` | `cnpg-system` | Namespace of the CloudNativePG operator and the Barman Cloud plugin; the database's network policy lets it in |
### Components

| Key | Default | What it does |
| --- | --- | --- |
| `postgres.instances` | `3` | PostgreSQL instances (1 primary, the rest standbys; synchronous when more than 1) |
| `postgres.resources` | 250m/1Gi to 2/1Gi | Each PostgreSQL instance |
| `postgres.backup.schedule` | `0 15 2 * * *` | Base backup time (six fields, seconds first): 02:15 every day |
| `postgres.backup.retention` | `30d` | How long backups are kept |
| `postgres.backup.sidecarResources` | 50m/128Mi to 500m/512Mi | Barman Cloud sidecar in every PostgreSQL pod (WAL archiving) |
| `keycloakOperator.resources` | 100m/256Mi to 500m/512Mi | Keycloak operator |
| `keycloak.instances` | `2` | Keycloak pods |
| `keycloak.resources` | 250m/1Gi to 2/2Gi | Each Keycloak pod |
| `keycloak.smtp.enabled` | `true` | Realms send mail through OpenBao `kv/conservices/keycloak/smtp` |

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
:   The Application health check is missing from `argocd-cm`; check
    `kubectl -n argocd get cm argocd-cm -o yaml | grep argoproj.io_Application`
    and add the block from
    [Prerequisites: Argo CD](prerequisites.md#9-argo-cd).

**`install-root.sh` stops with `missing: ...`**
:   A prerequisite is not installed, or not where `cluster.yaml` says.
    See [Prerequisites](prerequisites.md#troubleshooting).

**`cluster-secret-store` stays `Degraded`**
:   External Secrets cannot log in to OpenBao. `kubectl get clustersecretstore openbao`
    shows why; the usual causes are that `openbao-configure.sh` was not run,
    OpenBao is sealed, or `openbao.server` / `openbao.caBundle` do not match
    your OpenBao. See [Secrets with OpenBao](secrets-openbao.md#troubleshooting).

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

Next: [DNS and certificates](dns-and-certificates.md).
