# CI and releases

**Goal:** know what runs on your pull request, how to cut a release of one
app (signed images on GHCR plus its chart release tag), and how to fix a
red pipeline.

Every module repository (`den`, `hr`, `Rally`, `stash`, `finance`, `wiki`,
`desk`, `learn`, `tasks`) runs the same pipeline on
[GitHub Actions](https://docs.github.com/actions). The pipeline lives once,
in this repository, as a *reusable workflow*
(`.github/workflows/module-ci.yml`); each module has a short
`.github/workflows/ci.yml` that calls it with the module's images.

## What runs when

| Event | What runs | Publishes images |
| --- | --- | --- |
| Pull request | All checks below | No |
| Push to `main` | All checks below | No |
| Tag `vX.Y.Z` pushed | All checks, then publish | Yes, `X.Y.Z-BUILD` |
| **Run workflow** (manual, with a version) | All checks on tag `vX.Y.Z`, then publish | Yes, the next `BUILD` of `X.Y.Z` |

The app's chart is released separately, by a tag `<app>/vX.Y.Z` in this
repository ([The chart release workflow](#the-chart-release-workflow)).

The checks, as separate jobs:

| Job | What it does | Fails when |
| --- | --- | --- |
| **Go** | `gofmt -l`, `sqlc generate` (if `backend/sqlc.yaml` exists), `go mod verify`, `go vet`, [golangci-lint](https://golangci-lint.run) (the module's `.golangci.yml` if it has one), `go test -race ./...`, [govulncheck](https://go.dev/doc/security/vuln/) | A file is not gofmt-formatted, lint or vet finds a problem, a test fails, or code calls a function with a known vulnerability |
| **Shared code drift** | Compares the module's generated copies of `con-services` `shared/go` packages with their source (`scripts/sync-shared.sh --check`); passes at once when the module has none. Inputs `shared-check` (`error`, `warn`, `off`), `shared-ref`, `shared-repository`. See [Shared code](../concepts/shared-code.md#the-drift-check). | A generated copy differs from `shared/go` (with `shared-check: error`) |
| **Frontend** | `npm ci`, then `lint`, `typecheck`, `test` and `build`, each only if `package.json` has that script | Any of those scripts fails |
| **Trivy (repository)** | [Trivy](https://trivy.dev) scans dependencies (`go.sum`, `package-lock.json`), committed secrets and the Dockerfiles | A HIGH or CRITICAL finding that has a fix |
| **Image *name*** (one per image) | Builds the image for `linux/amd64`, checks the image policy (below), scans it with Trivy and writes an SBOM | The policy is broken, or a HIGH or CRITICAL vulnerability with a fix is found |

Modules whose Go tests need a database (Den, HR, Rally, Wiki, Learn, Tasks)
get a throw-away PostgreSQL 16: the `postgres` sidecar of the self-hosted
runner pod (`test-database-mode: sidecar`, the default) or a service
container on GitHub-hosted runners (`test-database-mode: service`). The
pipeline sets the module's test variable (for example
`DEN_TEST_DATABASE_URL`) and runs the test packages one at a time, because
those tests reset the schema.

## Where it runs

By default every job runs on the project's self-hosted runners with the
label `arc-conservices`, a runner scale set of
[Actions Runner Controller](https://docs.github.com/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller/about-actions-runner-controller).
These runners are project infrastructure, not part of a Con Services
installation. A runner pod for this pipeline has no Docker daemon and
three containers sharing `127.0.0.1`:

| Container | Image | Provides |
| --- | --- | --- |
| runner | `ghcr.io/aglelectronics/ci-runner` (from `infra/ci-runner/`; adds the C compiler `go test -race` needs) | the job, as a non-root user |
| BuildKit sidecar | `moby/buildkit:<version>-rootless` | image builds at `tcp://127.0.0.1:1234` (`buildkit-endpoint`) |
| PostgreSQL sidecar | `postgres:16.15-alpine` | a throw-away test database at `127.0.0.1:5432`, user `ci`, database `ci_test` (`test-database-mode: sidecar`) |

To run a module on GitHub-hosted runners instead, set in its `ci.yml`:

```yaml
    with:
      runner: ubuntu-24.04
      buildkit-endpoint: ""
      test-database-mode: service
```

Inputs of `module-ci.yml`:

| Input | Default | What it does |
| --- | --- | --- |
| `module` | required | Image prefix (`den`, `rally`, …) |
| `images` | required | JSON list of images: `name`, `dockerfile`, `context`, `build-args` (`{version}` is replaced by the tag), `shell-less`, `allow-root` |
| `runner` | `arc-conservices` | Runner label for every job |
| `push` | `false` | Publish, sign and attest (tags and manual runs) |
| `version` | empty | Rebuild this `X.Y.Z` (manual runs) |
| `den-major` | empty | The Den MAJOR this module is built for, for example `"1"`. A release whose MAJOR differs is refused ([Versions](../operations/versioning.md#modules-follow-dens-major)). Empty skips the check; Den leaves it empty |
| `arm64` | `false` | Also publish `linux/arm64`, built with QEMU emulation |
| `buildkit-endpoint` | `tcp://127.0.0.1:1234` | BuildKit to build with; empty starts a local builder (needs Docker) |
| `buildkit-driver-opts` | empty | TLS options for a remote BuildKit |
| `test-database-env` | empty | Variable the Go tests read for a database URL |
| `test-database-mode` | `sidecar` | `sidecar` or `service` |
| `go-dir`, `frontend-dir` | `backend`, `frontend` | Empty skips that job |
| `registry`, `image-namespace` | `ghcr.io`, `aglelectronics` | Where images go |
| `upload-sarif` | `true` | Upload Trivy results to code scanning |
| `sqlc-version`, `golangci-lint-version`, `govulncheck-version`, `trivy-version`, `node-version` | pinned | Tool versions |

Trivy results are also uploaded to the repository's **Security → Code
scanning** page. On a private repository without code scanning the upload
is skipped with a warning; it never fails the run.

## Image policy

Every image is checked before it can be published. The check reads the
built image directly (no Docker daemon needed):

- **Non-root:** the image's `User` must be set and must not be `root` or
  `0`.
- **Shell-less** (backends and migrators): the final filesystem must not
  contain `/bin/sh`, `/bin/bash`, `/bin/ash`, `/bin/dash`, `/bin/busybox`
  or their `/usr/bin/` equivalents. Without a shell, an attacker who gets
  code execution cannot simply start one, and there is less software to
  patch.

| Image | Base | Shell-less | Non-root | Why the exception |
| --- | --- | --- | --- | --- |
| `*-backend`, `*-migrate` | `gcr.io/distroless/static-debian12:nonroot` | Yes | Yes (`nonroot`, UID 65532) | none |
| `*-frontend`, `rally-submit` | `nginxinc/nginx-unprivileged:1.30.6-alpine` (plus `apk upgrade`) | No | Yes (`nginx`, UID 101) | Shell only: nginx images ship one, and the image's entrypoint scripts need it. nginx listens on port 8080, because a non-root process cannot bind ports below 1024. |
| `den-operator` | `alpine:3.24.4` with `postgresql16-client` and `age` | No | Yes (`postgres`, UID 70) | Shell only: the PostgreSQL client tools (`pg_dump`, `pg_dumpall`, `psql`, `pg_restore`) need Alpine's libraries, and Alpine ships a shell. The operator runs `pg_dump`/`pg_dumpall` for backups; `psql`, `pg_restore` and `age` are there for restores from inside the pod. |

The exceptions are declared per image in the module's `ci.yml` (no
`"shell-less": true`). No image is allowed to run as root
(`"allow-root"` is `false` or absent everywhere). Adding an exception needs
a reason in this table.

The frontend and operator Dockerfiles run `apk upgrade --no-cache` (the
operator gets current packages from `apk add`), so a rebuild picks up
Alpine security fixes published after the base image was built. When the
image scan fails on an Alpine package, rebuild first; bump the pinned base
tag when a newer one is out.

## Frontend images and sign-in settings

The frontend images name no domain. A web app reads its sign-in settings
(OIDC issuer and client, the API address and a few module keys) from
`/config.json` when it starts in the browser; each installation mounts that
file (Helm `frontend.config`, a ConfigMap in the Kustomize manifests, a
file with Docker Compose). So every installation runs the published images
and CI passes no sign-in settings when it builds them:

| Image | Build arguments |
| --- | --- |
| `<module>-frontend` | `<MODULE>_VERSION=<tag>` |
| `rally-submit` | `RALLY_APP=submit`, `RALLY_VERSION=<tag>` |

Each image ships a placeholder `/etc/conservices/config.json` with empty
`oidcAuthority` and `oidcClientId`; started without its own file, the web
app shows "Not configured yet". The keys are listed on each module's
configuration page (for Den:
[Web app settings](../modules/den/configuration.md#web-app-settings-configjson)).

Do not add `VITE_*` build arguments to CI: they would tie a published
image to one installation again. They remain for the local dev server
(`npm run dev`) only, which has no `/config.json`.

## Cut a release

Every app (Den and each module) is released on its own, with its own
version; an app that did not change gets no release. Pick the version with
the Den-led rules on
[Versions and upgrades](../operations/versioning.md#the-rules): for a
module, MINOR for a feature and PATCH for a fix, with MAJOR always equal to
the Den MAJOR it is built for; for Den, MAJOR only when something modules
use is removed or changed incompatibly.

A release has two tags, made in this order:

| Tag | Repository | Produces |
| --- | --- | --- |
| `vX.Y.Z` | the app's repository (`hr`, `den`, …) | the images `X.Y.Z-1` |
| `<app>/vX.Y.Z` | `con-services` | the chart release Argo CD and Helm read |

The example releases HR `1.12.1`.

1. In the app's repository, move the entries under `## [Unreleased]` in
   `CHANGELOG.md` to a new section `## [1.12.1] - 2027-03-02` with its
   *Needs Den* line, and merge that to `main` ([Changelogs](changelog.md)).
2. Tag the merge commit on `main` and push the tag:

    ```sh
    git checkout main && git pull
    git tag v1.12.1
    git push origin v1.12.1
    ```

3. Open the repository's **Actions** tab. The **CI** run for `v1.12.1` runs
   all checks, then the jobs **Release tag**, **Publish …** and
   **Tag and sign …**. The run summary lists every image with its digest.
4. Check the result in GHCR:

    ```sh
    crane ls ghcr.io/aglelectronics/hr-backend
    ```

    ```text
    1.12.0-1
    1.12.1-1
    ```

    Every image of the app now has the tag `1.12.1-1`
    (`hr-backend`, `hr-frontend`, `hr-migrate`), for `linux/amd64`
    (plus `linux/arm64` if the app sets `arm64: true`), signed, with a
    provenance attestation and two SBOMs.

5. **First release of an app only:** new GHCR packages are private.
   Open the package on GitHub (**Packages** on the organisation page →
   the package → **Package settings**) and set **Change visibility** to
   **Public**, once per image.
6. In `con-services`, open a pull request that sets the app's chart to the
   new version, `deploy/charts/hr/Chart.yaml`:

    ```yaml
    version: 1.12.1
    appVersion: "1.12.1"
    annotations:
      conservices.io/den-major: "1"
    ```

    and every image tag set in its `values.yaml` to `1.12.1-1` (HR and Rally
    ship empty tags; leave them empty). The compatibility table on
    [Versions and upgrades](../operations/versioning.md#compatibility-table)
    updates itself once the chart tag is pushed (step 7).
    The **Chart versions** check fails if the chart changed without a higher
    version, or if the annotation does not match the MAJOR.
7. After the merge, tag the merge commit on `main` and push:

    ```sh
    git checkout main && git pull
    git tag hr/v1.12.1
    git push origin hr/v1.12.1
    ```

    The **Chart release** workflow checks the tag
    ([below](#the-chart-release-workflow)); its summary shows the line to
    put in `cluster.yaml`:

    ```yaml
    modules:
      hr:
        version: "1.12.1-1"
    ```

Tags must be exactly `vX.Y.Z` and `<app>/vX.Y.Z`. A tag like
`v1.0.0-rc.1` starts the workflow but stops in the **Plan** job, because
published tags have no pre-release part.

**A chart-only change** (a new chart setting, a network policy fix) is
released as a new PATCH or MINOR of the app as well, because the chart is
versioned with its app: tag the app's repository too, so that images of
the new version exist (`git tag v1.12.2` on the unchanged code), then
release the chart as above.

**Den MAJOR:** release Den first (both tags), counting on from its MINOR
(`1.5.0` → `2.6.0`, never `2.0.0`). Then release **every** module with
MAJOR 2, also the ones that need no change: set `den-major: "2"` in its
`ci.yml` and the chart annotation `conservices.io/den-major: "2"`. A
module that needed no change keeps its MINOR and PATCH (Stash `1.3.2` →
`2.3.2`); a module that was adapted also raises its MINOR (HR `1.13.0` →
`2.14.0`). The chart
release workflow refuses a module tag `hr/v2.…` while no `den/v2.…` tag
exists.

### The first release (1.0.0)

Every app starts at `1.0.0`: the charts in `deploy/charts/` say
`version: 1.0.0`, `appVersion: "1.0.0"` and
`conservices.io/den-major: "1"`, and their image defaults and the GitOps
template use the tag `1.0.0-1`.

Run once, by a maintainer, in this order (nothing here runs automatically):

1. Point the shared workflow tag `ci-v1` at the `module-ci.yml` on `main`
   in `con-services` (it has the `den-major` input), then set
   `den-major: "1"` in each module's `.github/workflows/ci.yml` (not
   Den's):

    ```sh
    git checkout main && git pull
    git tag -f ci-v1 && git push -f origin ci-v1
    ```

2. In each app repository, rename `## [Unreleased]` in `CHANGELOG.md` to
   `## [1.0.0] - <date>` and add an empty `## [Unreleased]` above it,
   merge that to `main`, then tag and push `v1.0.0`; Den first:

    ```sh
    for app in den hr Rally stash finance wiki desk learn tasks; do
      git -C "$app" checkout main && git -C "$app" pull
      git -C "$app" tag v1.0.0
      git -C "$app" push origin v1.0.0
    done
    ```

3. Wait until every **CI** run is green and every image has `1.0.0-1`:

    ```sh
    for img in den-backend den-frontend den-operator hr-backend hr-frontend hr-migrate \
               rally-backend rally-frontend rally-migrate rally-submit stash-backend stash-frontend \
               finance-backend finance-frontend finance-migrate learn-backend learn-frontend learn-migrate \
               wiki-backend wiki-frontend wiki-migrate desk-backend desk-frontend desk-migrate \
               tasks-backend tasks-frontend tasks-migrate; do
      printf '%s ' "$img"; crane ls "ghcr.io/aglelectronics/$img" | grep -x '1.0.0-1' || echo MISSING
    done
    ```

4. In `con-services`, with the `1.0.0` charts and the root `CHANGELOG.md`
   section `## [1.0.0] - <date>` merged, tag that commit on `main` (Den
   first, so the module tags find a Den of MAJOR 1) and push. The same
   commit gets `v1.0.0`, the tag of the shared pieces
   ([The main repository's own tags](../operations/versioning.md#the-main-repositorys-own-tags)):

    ```sh
    git checkout main && git pull
    commit="$(git rev-parse HEAD)"
    git tag den/v1.0.0 "$commit"
    git push origin den/v1.0.0
    for app in hr rally stash finance wiki desk learn tasks; do
      git tag "$app/v1.0.0" "$commit"
    done
    git push origin hr/v1.0.0 rally/v1.0.0 stash/v1.0.0 finance/v1.0.0 \
      wiki/v1.0.0 desk/v1.0.0 learn/v1.0.0 tasks/v1.0.0
    git tag v1.0.0 "$commit"
    git push origin v1.0.0
    ```

5. Check that nine **Chart release** runs are green on the **Actions** tab.

### How BUILD is chosen

The image tag is `X.Y.Z-BUILD`. The **Release tag** job lists the existing
tags of every image of the module and takes the highest `X.Y.Z-N` plus 1,
so the first build of a version is `-1`. It then checks that this tag
exists for none of the images. Tags are never overwritten: if a tag exists,
the run fails, and the merge step checks again just before creating it.

### Rebuild a version (new BUILD)

Rebuild to pick up base-image security fixes without changing the code.
Release builds never use the build cache and always pull the base images.

1. Open **Actions → CI → Run workflow**.
2. Enter the version, for example `1.0.0` (the tag `v1.0.0` must exist),
   and press **Run workflow**.

The run checks out `v1.0.0`, runs all checks and publishes `1.0.0-2` (or
the next free number). Rebuilds get no changelog entry.

Two releases of the same repository never run at the same time: the
callers share one concurrency group for tags and manual runs. A third one
started while one runs and one waits replaces the waiting one.

## Verify a signature

Images are signed with [cosign](https://docs.sigstore.dev/) *keyless*
signing: there is no key to leak. The signature is bound to the GitHub
Actions workflow that built the image, recorded in the public Sigstore
transparency log. The identity is the shared workflow in this repository;
the module repository is checked with a second flag.

```sh
cosign verify ghcr.io/aglelectronics/den-backend:1.0.0-1 \
  --certificate-identity-regexp '^https://github\.com/AGlElectronics/con-services/\.github/workflows/module-ci\.yml@refs/tags/ci-v[0-9]+$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-github-workflow-repository AGlElectronics/den
```

```text
Verification for ghcr.io/aglelectronics/den-backend:1.0.0-1 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
```

Use the module's repository in the last flag (`AGlElectronics/Rally` for
`rally-*` images). To enforce this in the cluster, use a policy engine such
as [Kyverno](https://kyverno.io/docs/writing-policies/verify-images/) or
the Sigstore [policy-controller](https://docs.sigstore.dev/policy-controller/overview/)
with the same identity.

## Read the SBOM

An SBOM (software bill of materials) lists every package in an image.
Each published image has two:

- a **CycloneDX** SBOM made by Trivy, attached as a signed cosign
  attestation:

    ```sh
    cosign verify-attestation ghcr.io/aglelectronics/den-backend:1.0.0-1 \
      --type cyclonedx \
      --certificate-identity-regexp '^https://github\.com/AGlElectronics/con-services/\.github/workflows/module-ci\.yml@refs/tags/ci-v[0-9]+$' \
      --certificate-oidc-issuer https://token.actions.githubusercontent.com \
      | jq -r '.payload | @base64d | fromjson | .predicate.components[] | "\(.name) \(.version)"' | head
    ```

- an **SPDX** SBOM and a SLSA provenance attestation made by BuildKit,
  stored next to the image:

    ```sh
    docker buildx imagetools inspect ghcr.io/aglelectronics/den-backend:1.0.0-1 \
      --format '{{ json (index .SBOM "linux/amd64").SPDX.packages }}' | jq -r '.[].name' | head
    ```

The CycloneDX file is also kept for 90 days as a workflow artifact
(`sbom-<module>-<image>-<tag>`) on the release run.

## When Trivy fails

The log of the failing step shows a table with the package, the
vulnerability ID, the installed and the fixed version.

1. **Base image packages** (Alpine or Debian packages such as `zlib`):
   move to a newer base image tag in `infra/Dockerfile.*` (for example a
   newer `nginx:1.x-alpine` or `golang:1.x-alpine`). Dependabot proposes
   these weekly.
2. **Go standard library** (`stdlib`): raise the `go` line in
   `backend/go.mod` and the `golang:` image in the Dockerfiles to a fixed
   Go release.
3. **Go or npm dependencies:** update them (`go get example.com/mod@v1.2.3
   && go mod tidy`, or `npm update <package>`), or merge the Dependabot pull
   request.
4. **Only if no fix is possible yet**, accept the finding for a limited
   time in `.trivyignore.yaml` at the repository root, with a reason and an
   expiry date. After the date the finding fails the build again.

    ```yaml
    vulnerabilities:
      - id: CVE-2026-12345
        statement: >-
          Only reachable through the SSH client, which this module does not
          use. Waiting for golang.org/x/crypto 0.50. Owner: @alice.
        expired_at: 2027-01-31
    misconfigurations:
      - id: DS-0002
        paths: ["infra/Dockerfile.frontend"]
        statement: nginx runs as UID 101 on Kubernetes; see the image policy.
        expired_at: 2027-03-31
    ```

Only findings that have a fix fail the build (`--ignore-unfixed`); the
others still appear on the code scanning page.

## Pinned versions

- **Actions** are pinned to full commit SHAs with the version as a
  comment. Dependabot updates them weekly in this repository.
- **The shared workflow** is referenced by the modules as
  `AGlElectronics/con-services/.github/workflows/module-ci.yml@ci-v1`.
  `ci-v1` is a Git tag in this repository: a change to `module-ci.yml`
  reaches the modules only when the tag is moved or a module switches to a
  new tag, so a pipeline change is always a deliberate, reviewed step.
  Create the tag once before the first module run:

    ```sh
    git tag ci-v1 && git push origin ci-v1
    ```

    For a compatible change, move it (`git tag -f ci-v1 && git push -f
    origin ci-v1`); for an incompatible change (new required input), create
    `ci-v2` and update each module's `ci.yml`. The signature identity
    accepts any `ci-vN` tag.

- **Tools** run by the pipeline (golangci-lint, govulncheck, Trivy, sqlc,
  crane) have pinned versions as inputs of `module-ci.yml`.
- **Dependencies** of each module (Go modules, npm packages, base images,
  actions) are updated by Dependabot weekly (`.github/dependabot.yml`).

## Repository settings

One-time settings for the pipeline to work:

| Where | Setting | Why |
| --- | --- | --- |
| `con-services` → Settings → Actions → General → **Access** | *Accessible from repositories in the AGlElectronics organization* (only needed while `con-services` is private) | Modules may call `module-ci.yml` |
| Each module → Settings → Actions → General → **Workflow permissions** | Read repository contents (default) | The workflow asks for the extra permissions it needs |
| Each GHCR package → Package settings | Visibility **Public**; **Manage Actions access**: the module's repository with *Write* | Anyone can pull; only that repository can push |

## Run out of Actions minutes?

The modules run on self-hosted runners by default, which use no Actions
minutes. On GitHub-hosted runners, public repositories have no minute
limit; private repositories have a monthly quota. See
[Where it runs](#where-it-runs).

## The deploy validation workflow

This repository has its own workflow, `.github/workflows/deploy-validate.yml`,
on every change to `deploy/`, `docs/`, `mkdocs.yml` or the workflows:

- **Chart versions** (`scripts/check-chart-versions.py`): every chart in
  `deploy/charts/` has `version` = `appVersion` = `MAJOR.MINOR.PATCH`, the
  annotation `conservices.io/den-major` equal to its MAJOR, and image tags
  in `values.yaml` of the form `<version>-BUILD`. On a pull request, every
  chart whose files changed must also have a higher `version` than on the
  target branch; charts that did not change are not touched, and neither
  are charts of apps without a release tag `<app>/v*` yet (before its
  first release a chart may change while staying at its first version;
  the check reads the tags, so the job checks out with `fetch-depth: 0`). A module
  chart whose MAJOR differs from the Den chart's gives a warning only
  (expected during a Den MAJOR transition);
- `helm lint --strict` and `helm template` for every chart in
  `deploy/charts/` (HR and Rally with placeholder image tags; Rally also
  with the submission site enabled);
- `kubectl kustomize` for `deploy/kubernetes/base`, every module and every
  overlay (the example overlays get empty stand-ins for their gitignored
  `local/` files);
- `scripts/check-den-mode.py` on everything rendered: every module backend
  (from the charts with default values and from every Kustomize tree,
  including the production overlay) must get `DEN_MODE=required`, the
  Kubernetes reference setup
  ([Required or standalone](../concepts/pairing.md#required-or-standalone));
- [kubeconform](https://github.com/yannh/kubeconform) in strict mode on
  everything rendered, with the
  [CRDs catalog](https://github.com/datreeio/CRDs-catalog) for
  cert-manager, trust-manager, External Secrets, Gateway API and Cilium
  resources;
- `trivy config` on `deploy/` (fails on HIGH and CRITICAL);
- `mkdocs build --strict`;
- [actionlint](https://github.com/rhysd/actionlint) on all workflows.

To run the same checks locally:

```sh
helm lint --strict deploy/charts/stash
helm template stash deploy/charts/stash | kubeconform -strict -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
kubectl kustomize deploy/kubernetes/base > /dev/null
mkdocs build --strict
```

The Den mode check reads a folder of rendered manifests (needs PyYAML):

```sh
mkdir -p rendered
helm template stash deploy/charts/stash > rendered/helm-stash.yaml
kubectl kustomize deploy/kubernetes/modules/stash > rendered/kustomize-modules-stash.yaml
python3 scripts/check-den-mode.py rendered
```

```text
den-mode: 2 module backend(s), all DEN_MODE=required
```

A backend rendered with `standalone` (or without `DEN_MODE`) fails with a
line such as
`helm-stash.yaml: Deployment stash-backend has DEN_MODE='standalone', want 'required'`.
Keep the defaults at `required`; only values files and overlays for a
module without Den set `standalone`.

The chart version check, locally (needs PyYAML; `--base` compares with a
branch the way the pull request check does):

```sh
python3 scripts/check-chart-versions.py --base origin/main
```

```text
hr: 1.12.0 -> 1.12.1
wiki: not released yet (no tag wiki/v*), version bump not required
den: 1.0.0
hr: 1.12.1
...
chart-versions: 9 chart(s) OK
```

A chart changed without a version bump fails with
`deploy/charts/hr: files changed but version 1.12.0 is not higher than 1.12.0 on origin/main; bump version and appVersion in its Chart.yaml (PATCH for a fix, MINOR for a feature)`.

## The chart release workflow

`.github/workflows/chart-release.yml` runs when a chart release tag
`<app>/vX.Y.Z` (for example `hr/v1.12.1`) is pushed to this repository.
It publishes nothing: Argo CD and Helm read the chart from Git at the tag.
It only refuses a tag that would point installations at something broken:

| Check | Fails when |
| --- | --- |
| Tag format | The tag is not `<app>/vMAJOR.MINOR.PATCH`, or there is no `deploy/charts/<app>` |
| On `main` | The tagged commit is not on `main` |
| `Chart.yaml` | `version` or `appVersion` differ from the tag, or `conservices.io/den-major` differs from the MAJOR |
| Den first | A module tag whose MAJOR has no released Den yet (no tag `den/v<MAJOR>.*`) |
| Images | An image of the chart has no published tag `X.Y.Z-N` (a registry that refuses to answer, such as a private package, gives a warning instead) |
| Chart | `helm lint --strict`, `helm template`, the Den mode check and kubeconform on that one chart |

The run summary lists the images found and the `cluster.yaml` line for the
release. To check a tag before pushing it:

```sh
python3 scripts/check-chart-versions.py --tag hr/v1.12.1 --list-images
```

```text
ghcr.io/aglelectronics/hr-backend 1.12.1
ghcr.io/aglelectronics/hr-frontend 1.12.1
ghcr.io/aglelectronics/hr-migrate 1.12.1
```

## Smoke tests

A **smoke test** starts the real, published images and calls their APIs
end to end: sign in through Keycloak, read every module's role catalog,
let HR provision a role into Keycloak, create a Learn course, work
through a Tasks board. It catches what unit tests cannot: a wrong
setting in a chart, a missing permission in the realm, a module that no
longer answers HR.

The scripts are `scripts/smoke-*.ps1` (PowerShell). They run in two places:

| Where | Scripts | Addresses |
| --- | --- | --- |
| Your Docker Compose dev stack | all of them | the defaults (`http://localhost:8090` and so on) |
| The nightly **Smoke** workflow (kind cluster) | `smoke-access-catalog.ps1`, `smoke-learn.ps1`, `smoke-tasks.ps1` | `SMOKE_*` variables, set by the workflow |

`smoke-hr-keycloak.ps1` (reads Mailpit), `smoke-wiki.ps1` (restarts a
Compose container) and `smoke-den-pairing.ps1` (pairs a module through
Den's web app) need the Compose stack and run only there.

### The nightly Smoke workflow

`.github/workflows/smoke.yml` runs every night at 02:17 UTC and by hand
(**Actions → Smoke → Run workflow**, with an optional module image tag,
default `1.0.0-1`). It publishes nothing. On a GitHub-hosted
`ubuntu-24.04` runner (kind needs Docker, which the `arc-conservices`
runners do not have) it:

1. installs pinned kind, kubectl and Helm (checksums checked);
2. clones `stash`, `Rally`, `learn`, `desk`, `tasks` and `wiki` at the
   release tag `vX.Y.Z` of the image tag, for their
   `infra/access-config.toml`;
3. runs `scripts/ci/smoke-cluster.sh up`: the
   [Den quickstart](../getting-started/den-quickstart.md) cluster (kind,
   Cilium, cert-manager, trust-manager, `overlays/example` with Den's
   pinned images), with a throw-away certificate authority made by
   `openssl` instead of mkcert. Then, for every module: a namespace with
   the platform's labels, a database role, a Secret with the dev values
   of the Compose stack, and `helm upgrade --install` of
   `deploy/charts/<module>` with the image tag;
4. forwards the backends to the same localhost ports as the Compose
   stack, but over HTTPS (`scripts/ci/smoke-cluster.sh port-forward`);
5. runs the three smoke scripts with `SMOKE_INSECURE=1`;
6. on failure, prints pods, events and backend logs
   (`scripts/ci/smoke-cluster.sh diagnose`).

What differs from a real installation, on purpose:

- the modules run with `den.mode=standalone` (pairing is not part of the
  run) and one web app replica;
- the charts' own NetworkPolicies are off (`networkPolicy.enabled=false`):
  their defaults select the GitOps platform (CloudNativePG, Garage), not
  the trial's `postgres` and `s3`. The trial platform's policies still
  apply on its side. The charts' policies are checked statically by the
  [deploy validation workflow](#the-deploy-validation-workflow);
- every secret is a public dev value.

### Run a smoke script against something else

Each script reads its addresses from `SMOKE_*` variables
(`scripts/smoke-lib.ps1`) and falls back to the Compose dev ports:

| Variable | Default | Points at |
| --- | --- | --- |
| `SMOKE_KEYCLOAK` | `http://localhost:8085` | Keycloak (token endpoint, admin API) |
| `SMOKE_DEN_API` | `http://localhost:8090` | Den backend |
| `SMOKE_HR_API` | `http://localhost:8110` | HR backend |
| `SMOKE_STASH_API` | `http://localhost:8088` | Stash backend |
| `SMOKE_EVENTS_API` | `http://localhost:8100` | Rally backend |
| `SMOKE_LEARN_API` | `http://localhost:8120` | Learn backend |
| `SMOKE_FINANCE_API` | `http://localhost:8130` | Finance backend |
| `SMOKE_WIKI_API` | `http://localhost:8140` | Wiki backend |
| `SMOKE_DESK_API` | `http://localhost:8150` | Desk backend |
| `SMOKE_TASKS_API` | `http://localhost:8160` | Tasks backend |
| `SMOKE_TASKS_WEB` | `http://localhost:3009` | Tasks web app (`smoke-tasks.ps1`) |
| `SMOKE_INSECURE` | unset | `1` accepts self-signed certificates (PowerShell 7 only) |

`smoke-access-catalog.ps1` reads all nine catalogs (Den, HR, Rally as
`events`, Stash, Learn, Finance, Desk, Tasks, Wiki). A module that is not
running fails the run; leave it out with `-Skip`:

```powershell
./scripts/smoke-access-catalog.ps1 -Skip desk,tasks
```

The output looks like this (the role counts depend on the versions):

```text
den     12 roles (3 assignable)
hr      4 roles (2 assignable)
events  9 roles (7 assignable)
stash   11 roles (9 assignable)
...
desk    skipped
tasks   skipped
HR sees: stash status=ok
...
Provision stash:conops_lead → group stash-conops-lead: succeeded (temp pw issued)
Den admin API as member: 403 OK
Den dashboard as member includes brand: True primary=#4f46e5
```

To reproduce the nightly run on a Linux machine with Docker (it creates a
kind cluster named `conservices`; delete it afterwards with
`kind delete cluster --name conservices`):

```sh
for repo in stash Rally learn desk tasks wiki; do
  git clone --depth 1 --branch v1.0.0 "https://github.com/AGlElectronics/$repo.git" "modules/$repo"
done
bash scripts/ci/smoke-cluster.sh up
bash scripts/ci/smoke-cluster.sh port-forward
SMOKE_INSECURE=1 SMOKE_KEYCLOAK=https://127.0.0.1:8443 SMOKE_DEN_API=https://127.0.0.1:8090 \
  SMOKE_HR_API=https://127.0.0.1:8110 ... pwsh ./scripts/smoke-access-catalog.ps1
```

(the full list of variables is in the `env:` block of `smoke.yml`).

## Troubleshooting

**`error parsing called workflow ... workflow was not found`** (or *not accessible*)
: The tag `ci-v1` does not exist in `con-services`, or `con-services` is
  private and does not allow access from other repositories. Create the tag
  ([Pinned versions](#pinned-versions)) and check the **Access** setting
  ([Repository settings](#repository-settings)).

**`The nested job 'release-merge' is requesting 'packages: write, id-token: write', but is only allowed ...`**
: The module's `ci.yml` lost its `permissions:` block on the `ci` job. Copy
  it back from another module; all five permissions are needed even for
  pull requests, because GitHub checks them before deciding which jobs run.

**`gofmt` step lists files**
: Run `gofmt -w .` in `backend/` and commit.

**`Version '1.0.0-rc.1' is not MAJOR.MINOR.PATCH`**
: Release tags have no suffix. Delete the tag
  (`git push origin :refs/tags/v1.0.0-rc.1`) and tag `v1.0.0`.

**`Version 2.12.1 has MAJOR 2, but this module is built for Den MAJOR 1 (den-major)`**
: A module's MAJOR always equals its Den MAJOR. For a feature or a fix,
  delete the tag (`git push origin :refs/tags/v2.12.1`) and tag the next
  MINOR or PATCH of MAJOR 1. If the module was adapted to a new Den MAJOR,
  raise `den-major` in its `ci.yml` first.

**Chart release: `ghcr.io/aglelectronics/hr-backend has no tag 1.12.1-N` (or `... is not published`)**
: The chart was tagged before the images existed. Release the app's
  repository tag `v1.12.1` and wait for its CI, then re-run the failed
  **Chart release** run (**Re-run jobs**); the tag can stay.

**Chart release: `version 1.12.0 does not match the tag hr/v1.12.1`**
: The tagged commit has the old chart version. Delete the tag
  (`git push origin :refs/tags/hr/v1.12.1`), merge the version bump, and tag
  the merge commit.

**Chart release: `no Den 2.x.y is released (no tag den/v2.*)`**
: Release Den's new MAJOR before any module built for it.

**Deploy validate: `conservices.io/den-major is '1' but the chart's MAJOR is 2`**
: Set the annotation to the chart's MAJOR. It must always match; it
  exists so tools can read a chart's Den MAJOR without parsing versions.

**`ghcr.io/aglelectronics/<image>:1.0.0-1 already exists; tags are never overwritten`**
: Someone published this tag before (for example the tag was deleted and
  pushed again). Use **Run workflow** with the version to publish the next
  `BUILD`, or release a new version.

**`denied: permission_denied: write_package` in *Build and push by digest***
: The package exists but this repository may not write to it. On the
  package page → **Package settings → Manage Actions access**, add the
  module's repository with the *Write* role.

**`<image> runs as root (image User is '')`**
: The Dockerfile has no `USER` line. Add one (for example
  `USER nonroot:nonroot` on distroless), or, for a justified exception, set
  `"allow-root": true` for that image in `ci.yml` and add it to the
  [image policy](#image-policy) table.

**`<image> must be shell-less but contains: /bin/sh`**
: The final stage of the Dockerfile is not distroless, or something copies
  a shell in. Build the binary in the build stage and copy only the binary
  into `gcr.io/distroless/static-debian12:nonroot`.

**The image scan fails on an Alpine package (`musl`, `zlib`, `curl`, ...) of a frontend or `den-operator`**
: Alpine published a fix after the image was built. Rebuild without the
  build cache (`--no-cache --pull`) so `apk upgrade` / `apk add` fetch the
  fixed package, then scan again:

    ```sh
    trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 <image>
    ```

    If the fix is only in a newer Alpine release, bump the pinned base tag in
    the Dockerfile.

**The image scan fails on `stdlib` of a backend, migrate or operator image**
: The Go release the binary was built with has a known vulnerability. Raise
  the `go` line in `backend/go.mod` and the `golang:<version>-alpine<ver>`
  builder tag in every `infra/Dockerfile.*` of the module to the newest
  patch release from [go.dev/dl](https://go.dev/dl/), keep both on the same
  version, and rebuild. For a flagged module (for example
  `golang.org/x/net`), run `go get <module>@latest && go mod tidy` in
  `backend/`.

**`No PostgreSQL on 127.0.0.1:5432`**
: The module runs where there is no `postgres` sidecar, typically on
  GitHub-hosted runners with the default `test-database-mode: sidecar`. Set
  `test-database-mode: service` there ([Where it runs](#where-it-runs)).

**Build fails with `dial tcp 127.0.0.1:1234: connect: connection refused`**
: No BuildKit sidecar, typically on GitHub-hosted runners. Set
  `buildkit-endpoint: ""` there.

**`Upload SARIF` shows a warning *Code scanning is not enabled***
: Expected on private repositories without GitHub Advanced Security. The
  findings are still in the log; the step does not fail the run.

**The publish job is very slow with `arm64: true`**
: arm64 images are built with QEMU emulation on the amd64 runner, which is
  several times slower than a native build. Expected.

**The release fails with *The builder cannot build linux/arm64***
: On self-hosted runners, BuildKit uses the node's QEMU handlers, which are
  missing. Install them once on every node that runs runner pods:
  `sudo apt-get install -y qemu-user-static binfmt-support` (or
  `docker run --privileged --rm tonistiigi/binfmt --install arm64`).

**Smoke: `Module access configurations` fails with *Remote branch v1.0.0 not found***
: A module has no release tag for that version yet. Run the workflow by
  hand with a module image tag whose `vX.Y.Z` exists in every module
  repository.

**Smoke: `rollout status` of a module backend times out**
: Open the **Diagnose** step. `ImagePullBackOff`: the image tag is not
  published (check `ghcr.io/aglelectronics/<module>-backend`).
  `CrashLoopBackOff` with a database error: the role or the Secret's
  `DATABASE_URL` is wrong. With an OIDC error: Keycloak was not ready yet
  or the host alias `auth.conservices.test → 10.96.0.100` is missing.

**Smoke: a catalog fails with `401` or `403`**
: The module's catalog now needs HR's service token or a staff sign-in and
  the realm's `admin` user lacks the role. Check the module's
  [role catalog](../concepts/role-catalog.md) contract and the dev realm.

**Smoke script on Windows PowerShell: *SMOKE_INSECURE=1 needs PowerShell 7***
: `-SkipCertificateCheck` exists only in PowerShell 7. Install `pwsh` or
  point the script at plain HTTP addresses.

## Related pages

- [Versions and upgrades](../operations/versioning.md): the Den-led version rules, what tags mean and how to pin them.
- [Changelogs](changelog.md): what goes into a release section.
