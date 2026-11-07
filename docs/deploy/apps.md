# Den and the modules

This guide deploys **Den** (the portal and admin console) and the modules
(Stash, HR, Rally, Finance, Learn, Wiki, Desk, Tasks), signs in the first
admin and **pairs** the modules with Den.

**You need:** [Data](data.md) and [Identity](identity.md) done:
`conservices-pg` healthy, the buckets created and their keys in OpenBao,
Keycloak serving `https://auth.<domain>`.

**You are done when:** every Application in `kubectl get applications -n argocd`
is `Synced` and `Healthy`, you can sign in to `https://den.<domain>` as an
admin, and Den admin → Modules shows every module you selected as
**paired**.

Modules are **opt-in**: `cluster.yaml` lists all eight with
`enabled: false`, and only Den is installed until you enable some. Every
module you enable waits for Den (`den.mode: required`) and shows
*Waiting for Den* until you pair it; see
[Required or standalone](../concepts/pairing.md#required-or-standalone).

Secrets on this page (database URLs, S3 keys, service tokens, the GitHub
token) live in OpenBao; see [Secrets](../operations/secrets.md).

## What is deployed

The root chart (`charts/root`) renders one Argo CD Application for Den and
one for every module with `enabled: true` under `modules` in
`cluster.yaml`. Each has **two sources**:

| Source | What |
| --- | --- |
| The Helm chart `deploy/charts/<module>` of [`con-services`](https://github.com/AGlElectronics/con-services), at the tag `charts.targetRevision` | Deployments, Services, HTTPRoute, NetworkPolicies, PodDisruptionBudgets, certificates. Its values are computed by the root chart from `cluster.yaml` (addresses, buckets, image tags, network policy settings), then `modules.<module>.values` (or `den.values`) is merged on top. |
| `charts/module-extras` of your GitOps repository | The ExternalSecrets (`<module>-secrets`, and `ghcr-pull` when `images.pullSecret.enabled`) and the module's access configuration |

| Application | Namespace | Sync wave | Rendered by |
| --- | --- | --- | --- |
| `den` | `conservices-den` | 5 | `charts/root/templates/platform.yaml` |
| `stash`, `hr`, `rally`, `finance`, `learn`, `wiki`, `desk`, `tasks` | `conservices-<module>` | 10 | `charts/root/templates/modules.yaml` |

Argo CD creates the namespaces with the labels the platform needs:
`app.kubernetes.io/part-of: conservices` (trust-manager copies the internal
CA there), `conservices.io/tier: module` (PostgreSQL and Keycloak admit
module namespaces), and Pod Security `restricted`.

Every Application pins the chart to the same tag of `con-services`
(`charts.targetRevision`) and every image to an exact tag (`images.tag`,
for example `1.0.0-1`). Nothing uses `latest`.

!!! note "Chart tag `v1.1.0`"
    The template points at the tag `v1.1.0` of `con-services`, the first
    release whose charts know `den.mode` and `preregisterModules`. Until
    that tag exists Argo CD shows
    `unable to resolve 'v1.1.0' to a commit SHA`.

The root chart also sets two values that connect the modules to Den:

| Application | Value | Set to |
| --- | --- | --- |
| every module | `den.mode` | `required`, always. `cluster.yaml` has no option to change it, and the root chart stops if `modules.<module>.values.den.mode` tries. |
| `den` | `preregisterModules` | One entry per enabled module: `slug` (Rally: `events`), `display_name` (`Stash`, `HR`, `Rally`, `Finance`, `Learn`, `Wiki`, `Desk`, `Tasks`) and `base_url` `https://<host>.<domain>`. Den lists them on its Modules page as unpaired ([details](../modules/den/configuration.md#modules-registered-at-start-up)). |

### Where each module's secrets come from

The ExternalSecrets in `charts/module-extras/templates/<module>.yaml`
assemble each Secret from OpenBao with a template. For example Stash's
`stash-secrets`:

```yaml
DATABASE_URL: "postgres://stash:{{ .dbPassword }}@conservices-pg-rw.conservices-data.svc.cluster.local:5432/stash?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt"
S3_ACCESS_KEY_ID: "{{ .s3AccessKey }}"
S3_SECRET_ACCESS_KEY: "{{ .s3SecretKey }}"
```

| Module | OpenBao entries it reads |
| --- | --- |
| Den | `postgres/roles/den`, `den/s3`, `keycloak/clients` (`den-keycloak`), `den/operator-token`; operator: `postgres/superuser`, `den/backup-s3`, `den/files-s3` |
| Stash, Rally, Wiki, Tasks, Learn | `postgres/roles/<role>`, `<module>/s3`; Wiki, Tasks and Learn also `service-tokens/<module>` |
| HR | `postgres/roles/hr`, `keycloak/clients` (`hr-provisioner`), and `service-tokens/learn`, `service-tokens/wiki`, `service-tokens/tasks` for the ones enabled |
| Learn | also `keycloak/clients` (`learn-provisioner`) |
| Finance | `postgres/roles/finance` |
| Desk | `postgres/roles/desk`, `desk/secret-key` |
| all, with `images.pullSecret.enabled: true` | `infra/ghcr` (pull secret) |

All paths are below `kv/conservices/` except `kv/infra/ghcr`. Rally's
database role is `events`. The seed script creates exactly the entries of
the modules you enabled.

**Service tokens** let HR call other modules: HR sends `LEARN_SERVICE_TOKEN`
to Learn, and its `OFFBOARD_HOOKS` (Wiki) and `DEPARTMENT_HOOKS` (Tasks)
carry the Wiki and Tasks tokens. Both sides read the same OpenBao entry, so
they always match.

## Private images: the `ghcr-pull` secret

Skip this section if your images are public. If they are private packages,
every namespace needs a **pull secret**: credentials Kubernetes sends to the
registry when it downloads an image. With `images.pullSecret.enabled: true`
in `cluster.yaml`, an ExternalSecret in every Con Services namespace builds
a Secret `ghcr-pull` of type `kubernetes.io/dockerconfigjson` from
`kv/infra/ghcr`, and every chart gets:

```yaml
imagePullSecrets:
  - name: ghcr-pull
```

1. **Turn it on** in `cluster.yaml`:

    ```yaml
    images:
      pullSecret:
        enabled: true
    ```

2. **Create a GitHub token.** On GitHub: **Settings → Developer settings →
   Personal access tokens → Tokens (classic) → Generate new token
   (classic)**. Note: `conservices image pull`; expiration: your rotation
   interval (for example 1 year); scope: **only `read:packages`**. GitHub
   Container Registry does not accept fine-grained tokens for private
   packages, hence the classic token. Use an account (ideally a dedicated
   machine user) that can read the packages.
3. **Store it in OpenBao.** The seed script asks for the username and the
   token without echoing the token:

    ```sh
    BAO_TOKEN=<token> bash bootstrap/scripts/openbao-seed.sh
    ```

    ```text
    ==> kv/infra/ghcr: GitHub user + PAT with only read:packages, for the ghcr-pull Secrets
      GitHub username (empty = skip): conservices-bot
      Personal access token (read:packages):
    ==> kv/infra/ghcr written
    ```

4. **Check it** once the Applications exist:

    ```sh
    kubectl get secret ghcr-pull -n conservices-stash -o jsonpath='{.type}'; echo
    ```

    You should see `kubernetes.io/dockerconfigjson`.

To rotate the token, create a new one, store it with
`bao kv patch kv/infra/ghcr token=-` (paste it, then Ctrl-D), wait for the
ExternalSecrets to refresh (up to an hour), then revoke the old token on
GitHub.

## Deploy

1. **Select the modules.** In `cluster.yaml`, the block under
   *Pick the modules to run* lists all eight. Set `enabled: true` for the
   ones you want, for example Stash, HR and Rally:

    ```yaml
    # Pick the modules to run (Den is always deployed). Each module waits for Den
    # until you pair it from the Den dashboard.
    modules:
      stash:   { enabled: true }
      hr:      { enabled: true }
      rally:   { enabled: true }
      finance: { enabled: false }
      learn:   { enabled: false }
      wiki:    { enabled: false }
      desk:    { enabled: false }
      tasks:   { enabled: false }
    ```

    Den is always installed. With every module at `false`, the cluster runs
    Den alone; that is a valid setup. Check which Applications the root
    chart will create:

    ```sh
    helm template root charts/root -f cluster.yaml --show-only templates/modules.yaml | grep "^  name:"
    ```

    ```text
      name: stash
      name: hr
      name: rally
    ```

2. **Check the values Den and the modules need:**

    - `s3.*` ([Data](data.md#buckets-and-keys));
    - `den.backupAgeRecipients`: your age **public** key
      ([how to create one](../operations/databases-and-backups.md#the-encryption-key));
      Den's backups fail until it is set.

    Then render once; the root chart stops with a list of every value that
    is still missing:

    ```sh
    helm template root charts/root -f cluster.yaml > /dev/null && echo OK
    ```

    ```text
    OK
    ```

3. **Check that every secret exists:**

    ```sh
    BAO_TOKEN=<token> bash bootstrap/scripts/openbao-seed.sh --no-prompt
    ```

    No `Still missing` list should appear.

4. **Commit and push (sync).** Argo CD deploys Den first (wave 5) and the
   selected modules once Den is healthy (wave 10). Watch:

    ```sh
    kubectl get applications -n argocd
    ```

    ```text
    NAME       SYNC STATUS   HEALTH STATUS
    den        Synced        Healthy
    hr         Synced        Healthy
    rally      Synced        Healthy
    stash      Synced        Healthy
    ...
    ```

    Only the modules you enabled have an Application.

5. **Open Den:** `https://den.<domain>` must show the sign-in page of
   Keycloak with the Con Services theme.
6. **Open a module**, for example `https://stash.<domain>`. Before it is
   paired it shows *Waiting for Den* (or, for the module's admins,
   *Connect this module to Den*). Its API says the same:

    ```sh
    curl -s https://stash.<domain>/api/den/state
    ```

    ```json
    {"mode":"required","paired":false}
    ```

    Continue with [First admin](#first-admin) and
    [Pair the modules](#pair-the-modules).

### Change a module's settings

Every setting of a module chart (see `deploy/charts/<module>/values.yaml`
in `con-services`) can be overridden with `modules.<module>.values`, which
is merged last. For example, three Stash web front ends and more memory for
its backend:

```yaml
modules:
  stash:
    enabled: true
    imageTag: ""
    accessConfig: ""
    values:
      frontend:
        replicas: 3
      backend:
        resources:
          requests: { cpu: 100m, memory: 256Mi }
          limits: { cpu: "1", memory: 1Gi }
```

The chart refuses settings that are unsafe; for example Stash's backend
must stay at one replica because it migrates its database at start-up.

The web apps use the published images, which name no domain. The root
chart writes each one's sign-in settings (`frontend.config`, served to the
browser as `/config.json`) from `domain`: issuer
`https://auth.<domain>/realms/conservices` and client `<module>-spa`
(`events-spa` for Rally). Rally's submission site gets `submit.config` with
the attendee realm `https://auth.<domain>/realms/attendees` and client
`rally-submit`. Check what a browser gets with
`curl -s https://den.<domain>/config.json`. Override single keys through
`modules.<module>.values.frontend.config` (see
[Web app settings](../modules/den/configuration.md#web-app-settings-configjson)).

To replace a module's access configuration, put the TOML in
`modules.<module>.accessConfig`; empty uses
`charts/module-extras/files/access-config/<module>.toml`.

## First admin

The production realm has no users. Create the first Den admin in
Keycloak:

1. In the admin console (`https://auth-admin.<domain>`), switch to the
   realm **conservices**.
2. **Users → Add user**: username, e-mail, first and last name;
   **Email verified** on. **Join groups → den-admin**. Create.
3. **Credentials → Set password**, temporary on (the person chooses their
   own at first sign-in).
4. Sign in to `https://den.<domain>` with that user. You should see Den's
   admin menu.

From here on, staff accounts are created through HR, which provisions
them in Keycloak (`hr-provisioner`).

## Pair the modules

**Pairing** connects a module to Den with a one-time URL, so the module
follows Den's branding and settings; see [Pairing](../concepts/pairing.md).
Until a module is paired it is locked: its web app shows *Waiting for Den*
and its API answers `503 den_pairing_required`. For each module:

1. **Find it in Den.** Den admin → **Modules** already lists every module
   you enabled in `cluster.yaml`, with its name (for example *Stash*), its
   address (`https://stash.<domain>`) and the status **unpaired**. The
   root chart registered them through `preregisterModules`; you do not
   need **New module**. (Den's operator runs with
   `MANAGED_DATABASES=false`; the databases already exist, see
   [Data](data.md#roles-and-databases).)
2. **Pair**: click **Pair** on the module's row. Den shows a pairing URL,
   valid 15 minutes and usable once.
3. **Paste it in the module.** Open the module (`https://stash.<domain>`)
   and sign in as one of its admins. The page *Connect this module to Den*
   has a field for the URL; paste it and confirm. (Later, the same field
   is under the module's **Den connection** settings.)

    The module redeems it inside the cluster through
    `DEN_INTERNAL_URL` (`https://den-backend.conservices-den.svc.cluster.local:8080`,
    set by the charts), so the token never leaves the cluster.

4. **The module unlocks.** The waiting page disappears and the module
   works normally; within a minute it shows Den's logo. Den admin →
   Modules shows it as **paired**, and the module's state confirms it:

    ```sh
    curl -s https://stash.<domain>/api/den/state
    ```

    ```json
    {"mode":"required","paired":true}
    ```

## Upgrade

A release of Con Services bumps the chart tag and the image tags together.

1. Read the release's changelog. Entries starting with **BREAKING:** say
   what to do before upgrading.
2. Take a backup: Den admin → Backups → **Back up now**, and a PostgreSQL
   base backup ([Check the backups](data.md#check-the-backups)).
3. In `cluster.yaml`, set the new chart tag and image tag, for example:

    ```yaml
    charts:
      targetRevision: v1.2.0
    images:
      tag: "1.2.0-1"
    ```

    All images of a module share one tag. To hold one module back, set its
    `imageTag` (and pin its chart with care: all modules use the same chart
    tag).
4. Commit and push. Argo CD rolls out Den first, then the modules. The
   database migrations run as an initContainer (Stash: at start-up) before
   the new version serves traffic.
5. Check: `kubectl get applications -n argocd` all `Healthy`, and each
   module's version in Den admin → Modules.

To roll back, revert the commit. Migrations that already ran are not
undone; the changelog says when a release cannot be rolled back.

## Add a new module

The modules are a fixed list in the root chart. To add a new module `shop`
from a chart `deploy/charts/shop` in `con-services`:

1. **Root chart:** add `shop` to `root.moduleNames` and a line to
   `root.moduleMeta` in `charts/root/templates/_helpers.tpl` (host prefix,
   database role, Den slug and display name for `preregisterModules`,
   whether it uses S3, has a migrate image, reads an access config), and add `shop` under `modules` in `charts/root/values.yaml`,
   `charts/root/values.schema.json` and your `cluster.yaml`. This gives it
   an Application, a database and role
   ([details](data.md#add-a-database-for-a-new-module)), and, if it uses S3,
   the bucket `<prefix>-conservices-shop` in Den's backups.
2. **Secrets:** copy `charts/module-extras/templates/stash.yaml` to
   `shop.yaml` and adapt names and keys. If it stores files, create the
   bucket with its own key, store the key at `kv/conservices/shop/s3`, and
   give the `den-files` key read access to the bucket.
3. **Keycloak client** `shop-spa`: see
   [Add a module client](identity.md#add-a-module-client).
4. Check the render, commit, push, and [pair](#pair-the-modules) it:

    ```sh
    helm template root charts/root -f cluster.yaml --show-only templates/modules.yaml | grep "name: shop"
    ```

    ```text
      name: shop
    ```

## Remove a module

1. Set `modules.<module>.enabled: false` in `cluster.yaml`, commit and
   push. Argo CD deletes the module's Application with its Deployments,
   Services and Secrets, and drops the module from Den's
   `preregisterModules`. The namespace stays; delete it with
   `kubectl delete namespace conservices-<module>` when it is empty.
2. Once Den has restarted with the new list (Argo CD rolls it out with the
   same push), in Den admin → Modules → **Remove**, choose **Remove only,
   keep its data**. (Den does not drop databases in this setup.) In the
   other order, Den would list the module again, unpaired, at its next
   start.
3. The database and the bucket are **kept**: CloudNativePG stops managing
   the role but does not drop it, and the `Database` object uses
   `databaseReclaimPolicy: retain`.
   When you are sure the data is no longer needed (and after a final
   backup), drop the database by hand:
   `kubectl cnpg psql conservices-pg -n conservices-data -- -c 'DROP DATABASE <db>'`.
   Delete the bucket at the provider and the OpenBao entries.

## Troubleshooting

**`helm template` stops with `cluster.yaml is not complete`**
: The message lists every key that is still `change-me` or empty. Fix
  them; `grep -n change-me cluster.yaml` finds them.

**Pods stay in `ImagePullBackOff` with `401 Unauthorized` or `403 Forbidden`**
: The images are private and the pull secret is missing or the token
  cannot read the packages. Check that `images.pullSecret.enabled` is
  `true`, `kubectl get externalsecret ghcr-pull -n <namespace>` (must be
  `SecretSynced`), that `kv/infra/ghcr` holds the right username and a
  token with `read:packages`, and that the token's account has access to
  the packages on GitHub. An expired token gives `denied`.

**`ImagePullBackOff` with `manifest unknown`**
: The image tag does not exist. Compare `images.tag` (or the module's
  `imageTag`) with the package's tags on GitHub.

**Pods stay in `CreateContainerConfigError`: `secret "stash-secrets" not found`**
: The ExternalSecret could not be built. Run
  `kubectl describe externalsecret -n conservices-stash stash-secrets`; the
  event names the missing OpenBao entry. Run the seed script for it.

**Argo CD: `unable to resolve 'v1.1.0' to a commit SHA`**
: The chart tag does not exist in `con-services` yet. See the note at the
  top of this page.

**A module stays on *Waiting for Den* after pairing**
: Check what the module itself reports:
  `curl -s https://<module-host>.<domain>/api/den/state`. With
  `"paired":false` the pairing did not go through: the Den connection page
  shows the error (see the next entries); pair again. With `"paired":true`
  the web app still shows the old state: reload the page (Ctrl+F5). Every
  module in this template runs with `den.mode: required` on purpose; it
  cannot be switched to standalone from `cluster.yaml`.

**A module is not listed on Den's Modules page**
: Den registers the modules from `preregisterModules` when it starts.
  Check that the module is `enabled: true` in `cluster.yaml` and that the
  push reached the cluster (`kubectl get application <module> -n argocd`),
  then look at what Den received:
  `kubectl get configmap den-config -n conservices-den -o jsonpath='{.data.DEN_PREREGISTER_MODULES}'`.
  If the module is in that list but not on the page, Den has not restarted
  since: `kubectl rollout restart deploy/den-backend -n conservices-den`.
  If you removed the module in Den on purpose, it comes back at the next
  start as long as it is enabled; disable it first (see
  [Remove a module](#remove-a-module)). As a last resort, add it by hand
  with **New module** (slug, name and address from the table under
  [What is deployed](#what-is-deployed)).

**Pasting the URL fails with `pairing token expired` or `already consumed`**
: Pairing URLs are valid for 15 minutes and work once. Click **Pair** in
  Den again and paste the new URL straight away.

**The modules stay `OutOfSync`/waiting while Den is `Progressing`**
: Working as designed: the modules (wave 10) start only after Den (wave 5)
  is healthy. Fix Den first.

**A backend crashes with `x509: certificate signed by unknown authority`**
: For an internal address (database, Den, Keycloak) the ConfigMap
  `conservices-internal-ca` is missing in the namespace: check the label
  `app.kubernetes.io/part-of: conservices` on the namespace. For the S3
  provider, someone set `SSL_CERT_FILE`; remove it
  ([why](../operations/internal-tls.md#public-certificates-stay-trusted)).

**Pairing fails with `invalid pairing token`, `already consumed` or `expired`**
: Make a new pairing URL in Den and paste it within 15 minutes; see
  [Pairing](../concepts/pairing.md).

**Pairing fails with a timeout**
: The module cannot reach `den-backend` on 8080. Check that the module
  namespace has `conservices.io/tier: module` (Den admits those) with
  `kubectl get ns conservices-<module> --show-labels`.

**File uploads or downloads fail in the browser with a CORS error**
: The bucket has no CORS rule for the module's address; see step 6 of the
  [Hetzner walk-through](data.md#worked-example-hetzner-object-storage).

**HR shows no roles from Stash or Rally, and its log shows timeouts to their backends**
: The root chart allows HR's egress to the enabled modules
  (`networkPolicy.moduleEgressNamespaces`), and Stash and Rally admit
  `conservices-hr` by default (`networkPolicy.allowFromNamespaces`). If you
  overrode either in `modules.<module>.values`, put the namespaces back.

## Related pages

- [Pairing](../concepts/pairing.md)
- [Secrets](../operations/secrets.md)
- [Databases, backups and restore](../operations/databases-and-backups.md)
- [High availability](high-availability.md)
- [Versioning](../operations/versioning.md)
