# Versions and upgrades

**Goal:** pin every image to an exact `MAJOR.MINOR.PATCH-BUILD` tag,
upgrade one module at a time safely, and roll back when an upgrade goes
wrong.

Every Con Services module is released as container images with a version
tag. This page explains what the tags mean, how to pick and pin them, how to
upgrade and how to roll back.

## Image names

Images are published on GitHub's container registry:

```text
ghcr.io/aglelectronics/<module>-<component>:<tag>
```

| Module | Images |
| --- | --- |
| Den | `den-backend` (also contains `/den-migrate`), `den-frontend`, `den-operator` |
| Stash | `stash-backend`, `stash-frontend` |
| Other modules | `<module>-backend`, `<module>-frontend`, and where the module has a separate migration step, `<module>-migrate` (see `deploy/kubernetes/modules/README.md`) |

All images of one module share the same tag for a release: Den `1.2.0-1`
means `den-backend:1.2.0-1`, `den-frontend:1.2.0-1` and
`den-operator:1.2.0-1`, built from the same commit. Never mix tags within a
module.

## What a tag means

Tags have the form `MAJOR.MINOR.PATCH-BUILD`, for example `1.4.2-3`:

| Part | Changes when | What it means for you |
| --- | --- | --- |
| `MAJOR` (`1`) | Something incompatible changed: a setting was renamed or removed, an API changed, or the upgrade needs manual steps. | Read the changelog's **BREAKING** entries before upgrading. |
| `MINOR` (`4`) | New features, compatible with what you have. | Upgrade when convenient. |
| `PATCH` (`2`) | Bug fixes only. | Upgrade soon. |
| `BUILD` (`3`) | The same version was built again, for example for a security update of the base image, with no change to Con Services' own code. It starts at `1` for every new version and counts up with each rebuild. | Safe to take any time; always prefer the highest build of your version. |

The first three parts follow [Semantic Versioning](https://semver.org).
Each released `MAJOR.MINOR.PATCH` has its own section in the module's
`CHANGELOG.md`; rebuilds do not (see [Changelogs](../contributing/changelog.md)).

## Pin exact tags, never `latest`

There is no `latest` tag. Always write the full tag in your overlay:

```yaml
images:
  - name: ghcr.io/aglelectronics/den-backend
    newTag: 1.0.0-1
  - name: ghcr.io/aglelectronics/den-frontend
    newTag: 1.0.0-1
  - name: ghcr.io/aglelectronics/den-operator
    newTag: 1.0.0-1
```

Pinned tags mean your installation only changes when you change this file,
and you can always tell from Git which version was running when.

To see which version is running:

```sh
kubectl get deploy -n conservices-den -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image
```

```text
NAME           IMAGE
den-backend    ghcr.io/aglelectronics/den-backend:1.0.0-1
den-frontend   ghcr.io/aglelectronics/den-frontend:1.0.0-1
den-operator   ghcr.io/aglelectronics/den-operator:1.0.0-1
```

To list the published tags of an image, use the repository's *Packages*
page on GitHub, or a registry tool such as
[crane](https://github.com/google/go-containerregistry/blob/main/cmd/crane/README.md)
or [skopeo](https://github.com/containers/skopeo):

```sh
crane ls ghcr.io/aglelectronics/den-backend
```

```text
1.0.0-1
1.0.0-2
1.1.0-1
```

Take the highest `BUILD` of the version you want (`1.0.0-2` above).

For the strictest pinning, add the image **digest** as well; Kustomize
supports `digest:` next to `newTag:`, and the cluster then refuses an image
that was replaced under the same tag:

```sh
crane digest ghcr.io/aglelectronics/den-backend:1.0.0-2
```

```yaml
images:
  - name: ghcr.io/aglelectronics/den-backend
    newTag: 1.0.0-2
    digest: sha256:4c1f…        # the output of crane digest
```

Den also reports its version in `/api/health` (the backend image's
`VERSION` build argument) and on the admin console's **Settings** page (the
frontend image's `DEN_VERSION`). Both say `dev` for images built without
them.

## Upgrading

1. **Read the changelog** of the module, from your version to the new one:
   `CHANGELOG.md` in the module's repository. Look for **BREAKING** entries
   and anything under *Changed* or *Removed* that affects your settings.
2. **Make a backup.** Den admin console → **Backups** → **Back up now**, and
   wait until it shows as succeeded.
3. **Change the tags** of every image of that module in your overlay's
   `kustomization.yaml`, all to the same new tag.
4. **Look at the difference**, then apply:

    ```sh
    kubectl diff -k deploy/kubernetes/overlays/<yours>
    kubectl apply -k deploy/kubernetes/overlays/<yours>
    ```

5. **Watch the rollout.** For Den, the old backend pod stops, the new pod's
   `migrate` initContainer applies the new migrations, then the new server
   starts:

    ```sh
    kubectl rollout status -n conservices-den deploy/den-backend
    kubectl rollout status -n conservices-den deploy/den-frontend
    kubectl rollout status -n conservices-den deploy/den-operator
    ```

    ```text
    deployment "den-backend" successfully rolled out
    ```

6. **Check** that `https://<den>/api/health` reports the new version, that
   you can sign in, and that **Backups** shows no warning.

Upgrade one module at a time, Den first when several have new versions.

For modules installed with Helm, steps 3 to 5 are `helm diff upgrade` and
`helm upgrade --wait`; see [Helm: Upgrade](helm.md#upgrade). For modules
with a separate `<module>-migrate` image, change its tag together with the
backend's and frontend's: the `migrate` initContainer runs it before the new
backend starts, exactly like Den's.

### MAJOR upgrades

A new `MAJOR` version can need steps by hand, such as renaming a setting in
your overlay, adding a network policy, or a Keycloak change. They are listed
under **BREAKING** in the changelog with what to do. Do them in the order
the changelog gives, usually *before* step 4. Do not skip a `MAJOR` version:
go from 1.x to 2.x to 3.x.

### When the migration fails

If the new `migrate` initContainer fails, the new server never starts and
Kubernetes keeps retrying (`Init:CrashLoopBackOff`). Because `den-backend`
uses the `Recreate` strategy, the old version has already stopped, so Den is
down until you act. Read the log:

```sh
kubectl logs -n conservices-den deploy/den-backend -c migrate
```

Then either fix the cause (often a database connection problem) or roll
back as below.

## Rolling back

Migrations only go forward. Rolling back the **image** is safe only when
the new version did not change the database structure (no new migration ran
successfully); the changelog says when a release contains migrations.

**If no migration ran** (patch releases usually; or the migration failed
before changing anything): put the old tags back in your overlay and apply
again.

```sh
kubectl apply -k deploy/kubernetes/overlays/<yours>
```

`kubectl rollout undo` also works for a quick fix, but the next apply would
bring the new tag back, so always fix the overlay too.

**If a migration ran:** the old version may not understand the new database
structure. Restore the module's database from the backup you made in step 2
(see [Restore](databases-and-backups.md#restore)), then deploy the old tags.

To tell whether a migration ran, compare the migration list with the
release's changelog (Den):

```sh
kubectl exec -n conservices-den deploy/den-backend -- /den-migrate -status
```

A migration applied a few minutes ago, at the time of your upgrade, means
the database was changed.

Data written between the upgrade and the restore is lost with the restore.
Decide quickly, and tell people to stop using the module while you do.

## Troubleshooting

**`ErrImagePull` with `manifest unknown` right after changing a tag**
: The tag does not exist. List the real tags (`crane ls …`, above); there is
  no `latest`, and every tag has a `-BUILD` suffix.

**Den shows the old version on the Settings page after upgrading**
: The frontend Deployment still uses the old tag, or your browser cached
  the old web app. Check all three images with the `kubectl get deploy`
  command above, then reload with ++ctrl+shift+r++.

**`kubectl rollout status` waits forever with `Waiting for deployment "den-backend" rollout to finish: 0 of 1 updated replicas are available`**
: The new pod is stuck. `kubectl get pods -n conservices-den` shows whether
  it is in `Init:` (migration, see [When the migration fails](#when-the-migration-fails))
  or not ready (read its log with `kubectl logs`).

**After a rollback the module logs `relation "…" does not exist` or `column "…" does not exist`**
: The database and the image do not match: a migration ran, then you went
  back without restoring. Restore the pre-upgrade backup, or move forward
  to the new version again.

**Upgrading skipped a `MAJOR` version and the backend refuses to start**
: Go back to the backup, then upgrade one `MAJOR` at a time, doing each
  changelog's **BREAKING** steps.

## Related pages

- [Installing modules with Helm](helm.md#roll-back): `helm rollback`.
- [Databases, backups and restore](databases-and-backups.md#restore): restoring before a rollback.
- [Changelogs](../contributing/changelog.md): how releases are described.