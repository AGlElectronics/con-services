# Installing modules with Helm

**Goal:** install, configure, upgrade and roll back a Con Services module
with its Helm chart, and know when to use Helm instead of Kustomize.

**Helm** is a package manager for Kubernetes. A **chart** is a package of
templated manifests; you install it with your own settings (a **values**
file), and Helm keeps track of each installation (a **release**) so you can
upgrade or roll it back with one command.

## Helm or Kustomize?

Both install the same published images. Pick one per module and stick to it;
do not apply a module with both.

| | Kustomize (`deploy/kubernetes/`) | Helm (`deploy/charts/`) |
| --- | --- | --- |
| Platform (Keycloak, PostgreSQL, MinIO, Den) | **Yes**: `base/` plus your overlay. | **No chart.** Use Kustomize for the platform. |
| Stash | `modules/stash/` | `charts/stash` |
| HR, Rally, Finance, Learn, Wiki, Desk, Tasks | Not written yet (see `deploy/kubernetes/modules/README.md`). | `charts/<module>` |
| Upgrade / rollback history | Git history of your overlay. | `helm history`, `helm rollback`. |
| Good fit for | GitOps, one repository describing the whole installation. | Installing one module quickly, Argo CD or Flux with `HelmRelease`. |

The usual production setup is therefore: **platform with Kustomize, modules
with Helm** (or Kustomize for Stash).

!!! warning "The charts are a first version"
    Every chart is version `0.1.0` and marked *STUB: first scaffold, not yet
    tested on a cluster* in its `Chart.yaml`. They render valid manifests
    and follow the same rules as the Kustomize files, but test each one on a
    staging cluster before relying on it, and report problems as issues.

## What every chart does and does not do

Every chart in `deploy/charts/` follows the same rules:

- It **never creates Secrets.** You name an existing Secret with
  `existingSecret`; create it with an `ExternalSecret` from your secret
  manager (see [Secrets](secrets.md)).
- It **never creates the namespace.** Create `conservices-<module>` first,
  with the labels the platform's network policies need.
- It **never uses `latest`.** Image tags are `MAJOR.MINOR.PATCH-BUILD`. HR
  and Rally ship with empty tags on purpose, so the install fails until you
  set one.
- It keeps the module's backend at **one replica** with the `Recreate`
  strategy, because each backend runs its database migrations on start
  (through a `migrate` initContainer, or in-process for Stash). Desk,
  Finance, Learn, Tasks and Wiki refuse any other value.
- It creates the module's **NetworkPolicies** (default deny plus the
  allowed flows from [Network policies](network-policies.md)) unless you
  set `networkPolicy.enabled: false`.
- It runs every container under the `restricted` Pod Security rules, with
  no service account token mounted.

| Chart | `appVersion` | Secret it expects (`existingSecret`) | Migrations | Notes |
| --- | --- | --- | --- | --- |
| `stash` | `1.0.0-1` | `stash-secrets` | in the backend at start | |
| `hr` | none (`0.0.0`) | `hr-secrets` | `hr-migrate` initContainer | Set all three tags yourself. |
| `rally` | none (`0.0.0`) | `rally-secrets` | `rally-migrate` initContainer | Set tags yourself. Pairs with Den as `events`. The public submission site has no published image yet. |
| `finance` | `1.0.0-1` | `finance-secrets` | `finance-migrate` initContainer | No access config file; uses `FINANCE_ACCESS_GROUPS`. |
| `learn` | `1.0.0-1` | `learn-secrets` | `learn-migrate` initContainer | |
| `wiki` | `1.0.0-1` | `wiki-secrets` | `wiki-migrate` initContainer | Creates a 1 GiB PersistentVolumeClaim for the live-edit buffer. |
| `desk` | `1.0.0-1` | `desk-secrets` | `desk-migrate` initContainer | |
| `tasks` | `1.0.0-1` | `tasks-secrets` | `tasks-migrate` initContainer | |

Each chart's `values.yaml` lists every key with a comment; the module's
**Setup** and **Configuration** pages (under [Modules](../modules/index.md))
explain the settings.

## Install a module

This example installs Stash into a cluster where the platform and Den
already run ([How the platform starts](../getting-started/how-the-platform-starts.md)).
For any other module, replace `stash` with the module name.

1. **Install Helm 3** on your computer (<https://helm.sh/docs/intro/install/>)
   and check it:

    ```sh
    helm version --short
    ```

    ```text
    v3.16.3+gcbc5a57
    ```

2. **Register the module in Den** and let it create the database:
   Den → **Admin console → Modules → New module**, tick *Create a database
   for it*, and copy the connection URL Den shows once.

3. **Create the namespace** with the labels the network policies select on:

    ```sh
    kubectl create namespace conservices-stash
    kubectl label namespace conservices-stash \
      conservices.io/tier=module conservices.io/module=stash \
      pod-security.kubernetes.io/enforce=restricted \
      pod-security.kubernetes.io/warn=restricted
    ```

4. **Store the secrets** in your secret manager and let the External Secrets
   Operator create `stash-secrets` (procedure in
   [Secrets](secrets.md#add-a-modules-secrets)). Check it exists:

    ```sh
    kubectl get secret -n conservices-stash stash-secrets
    ```

    ```text
    NAME            TYPE     DATA   AGE
    stash-secrets   Opaque   3      12s
    ```

5. **Create the access config** ConfigMap (modules with an access config
   only; the comment in `values.yaml` gives the exact command):

    ```sh
    kubectl create configmap stash-access-config -n conservices-stash \
      --from-file=access-config.toml=stash/infra/access-config.toml
    ```

6. **Write your values file** and keep it in Git (it contains no secrets):

    ```yaml
    # values/stash.yaml
    image:
      backend:  { tag: "1.0.0-1" }
      frontend: { tag: "1.0.0-1" }
    config:
      APP_BASE_URL: https://stash.con.example.org
      OIDC_ISSUER_URL: https://auth.con.example.org/realms/conservices
      CORS_ALLOWED_ORIGINS: https://stash.con.example.org
      S3_ENDPOINT: https://fsn1.your-objectstorage.com
      S3_BUCKET: example-stash
      S3_REGION: fsn1
      S3_USE_PATH_STYLE: "false"
    ingress:
      className: nginx
      host: stash.con.example.org
      tlsSecretName: stash-tls
    networkPolicy:
      data: { enabled: false }          # managed PostgreSQL and S3, not conservices-data
      extraEgress:
        - to: [{ ipBlock: { cidr: 10.20.0.0/24 } }]   # your database subnet
          ports: [{ protocol: TCP, port: 5432 }]
        - to: [{ ipBlock: { cidr: 0.0.0.0/0 } }]      # managed S3 over HTTPS
          ports: [{ protocol: TCP, port: 443 }]
    ```

7. **Preview** what Helm would create, then install:

    ```sh
    helm template stash deploy/charts/stash -n conservices-stash -f values/stash.yaml | less
    helm install stash deploy/charts/stash -n conservices-stash -f values/stash.yaml
    ```

    ```text
    NAME: stash
    NAMESPACE: conservices-stash
    STATUS: deployed
    REVISION: 1
    NOTES:
    Stash 1.0.0-1 is installed in namespace conservices-stash.
    ...
    ```

8. **Wait for the pods** and check health, as the chart's notes say:

    ```sh
    kubectl get pods -n conservices-stash -w
    kubectl exec -n conservices-stash deploy/stash-frontend -- wget -qO- http://stash-backend:8080/api/health
    ```

    ```json
    {"status":"ok","database":"ok","version":"1.0.0-1","uptime_sec":42}
    ```

9. **Add the module's bucket to backups**: append it to `FILES_S3_BUCKETS`
   in your platform overlay's `den-operator-config` and re-apply the
   platform (see [Backups](databases-and-backups.md#backups)).
10. **Pair it** with Den: Den → **Modules → Pair**, then in the module
    **Settings → Den connection** (see
    [How the platform starts, step 4c](../getting-started/how-the-platform-starts.md#4c-pair-stash-with-den)).

## Upgrade

1. Read the module's `CHANGELOG.md` from your version to the new one
   ([Versions and upgrades](versioning.md#upgrading)).
2. Make a backup: Den → **Backups → Back up now**.
3. Change every image tag of the module in your values file to the same new
   tag.
4. Look at the difference. The [helm-diff](https://github.com/databus23/helm-diff)
   plugin shows it like `kubectl diff`:

    ```sh
    helm plugin install https://github.com/databus23/helm-diff   # once
    helm diff upgrade stash deploy/charts/stash -n conservices-stash -f values/stash.yaml
    ```

5. Upgrade and wait for it to finish:

    ```sh
    helm upgrade stash deploy/charts/stash -n conservices-stash -f values/stash.yaml --wait --timeout 10m
    ```

    ```text
    Release "stash" has been upgraded. Happy Helming!
    NAME: stash
    STATUS: deployed
    REVISION: 2
    ```

6. Check `/api/health` reports the new version and sign in once.

Always pass your values file (`-f`). `helm upgrade` without it resets every
setting to the chart defaults. Do **not** use `--reuse-values` across chart
versions: new chart keys would stay unset.

## Roll back

Helm keeps the previous revisions:

```sh
helm history stash -n conservices-stash
```

```text
REVISION  UPDATED                   STATUS      CHART        APP VERSION  DESCRIPTION
1         Fri Nov  6 10:12:03 2026  superseded  stash-0.1.0  1.0.0-1      Install complete
2         Fri Nov  6 14:40:51 2026  deployed    stash-0.1.0  1.0.0-1      Upgrade complete
```

```sh
helm rollback stash 1 -n conservices-stash --wait
```

!!! warning "Rolling back images does not roll back the database"
    Migrations only go forward. If the new version's migration ran, the old
    version may not understand the database any more. Restore the module's
    database from the backup you made before upgrading first; see
    [Rolling back](versioning.md#rolling-back).

After a rollback, put the old tag back in your values file too, or the next
`helm upgrade` brings the new one back.

## Uninstall

```sh
helm uninstall stash -n conservices-stash
```

This removes the Deployments, Services, Ingress, ConfigMaps and
NetworkPolicies. It does **not** touch the Secret, the access config
ConfigMap, the namespace, the database or the bucket. The Wiki chart's
PersistentVolumeClaim is removed with the release, so make sure Wiki shut
down cleanly first. To also remove the database, remove the module in Den
(**Modules → Remove → Delete its database too**), which backs it up first.

## GitOps with Argo CD or Flux

Point your GitOps tool at the chart folder and at the values file in your
own repository. Argo CD example with two sources (the chart from
`con-services`, the values from your repository):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: conservices-stash
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: https://github.com/AGlElectronics/con-services.git
      targetRevision: v1.0.0          # a tag of con-services, never a branch
      path: deploy/charts/stash
      helm:
        valueFiles:
          - $values/values/stash.yaml
    - repoURL: https://git.example.org/ops/conservices.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: conservices-stash
  syncPolicy:
    syncOptions: ["CreateNamespace=false"]
```

Keep `CreateNamespace=false`: the namespace needs the labels from step 3.

## Troubleshooting

**`Error: execution error at (stash/templates/deployment.yaml): image.backend.tag is required (MAJOR.MINOR.PATCH-BUILD)`**
: The tag is empty (always the case for HR and Rally). Set every tag under
  `image:` in your values file.

**`backend.replicas must be 1 for this module (got 2)`**
: The chart protects the single-replica rule. Scale the frontend instead
  (`frontend.replicas`); see [Scaling](running.md#scaling).

**`Error: INSTALLATION FAILED: namespaces "conservices-stash" not found`**
: Create the namespace first (step 3). Do not use `--create-namespace`: it
  creates the namespace without the labels and the module cannot reach Den.

**Pods stay in `CreateContainerConfigError`**
: The Secret or the access config ConfigMap is missing. `kubectl describe pod`
  says which:

    ```sh
    kubectl describe pod -n conservices-stash -l app.kubernetes.io/component=backend | grep -A2 -i error
    ```

    ```text
    Warning  Failed  12s  kubelet  Error: secret "stash-secrets" not found
    ```

**`violates PodSecurity "restricted:latest"`** when you add `extraVolumes` or a sidecar
: Everything you add must also meet the restricted rules; see
  [Pod Security](network-policies.md#pod-security).

**`helm upgrade` hangs and fails with `context deadline exceeded`**
: The new backend did not become ready. Look at the migration and backend
  logs, then roll back if needed:

    ```sh
    kubectl logs -n conservices-stash deploy/stash-backend -c migrate   # modules with a migrate image
    kubectl logs -n conservices-stash deploy/stash-backend
    ```

**`another operation (install/upgrade/rollback) is in progress`**
: A previous command was interrupted. Check `helm history`; if the last
  revision is `pending-upgrade`, roll back to the last `deployed` revision.

## Related pages

- [Running on Kubernetes](running.md): the Kustomize side and scaling rules.
- [Versions and upgrades](versioning.md): tags and the upgrade procedure.
- [Secrets](secrets.md): creating `existingSecret` with External Secrets.
- [Network policies](network-policies.md): what `networkPolicy.*` allows.
