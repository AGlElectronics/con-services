# CI and releases

**Goal:** know what runs on your pull request, how to cut a release that
publishes signed images to GHCR, and how to fix a red pipeline.

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

The checks, as separate jobs:

| Job | What it does | Fails when |
| --- | --- | --- |
| **Go** | `gofmt -l`, `sqlc generate` (if `backend/sqlc.yaml` exists), `go mod verify`, `go vet`, [golangci-lint](https://golangci-lint.run) (the module's `.golangci.yml` if it has one), `go test -race ./...`, [govulncheck](https://go.dev/doc/security/vuln/) | A file is not gofmt-formatted, lint or vet finds a problem, a test fails, or code calls a function with a known vulnerability |
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

A release is a Git tag `vMAJOR.MINOR.PATCH` on the module's repository. The
version follows [Semantic Versioning](https://semver.org); see
[Versions and upgrades](../operations/versioning.md) for what each part
means.

1. Move the entries under `## [Unreleased]` in `CHANGELOG.md` to a new
   section `## [1.0.0] - 2026-11-07` and merge that to `main`
   ([Changelogs](changelog.md)).
2. Tag the merge commit on `main` and push the tag:

    ```sh
    git checkout main && git pull
    git tag v1.0.0
    git push origin v1.0.0
    ```

3. Open the repository's **Actions** tab. The **CI** run for `v1.0.0` runs
   all checks, then the jobs **Release tag**, **Publish …** and
   **Tag and sign …**. The run summary lists every image with its digest.
4. Check the result in GHCR. For Den:

    ```sh
    crane ls ghcr.io/aglelectronics/den-backend
    ```

    ```text
    1.0.0-1
    ```

    Every image of the module now has the tag `1.0.0-1`
    (`den-backend`, `den-frontend`, `den-operator`), for `linux/amd64`
    (plus `linux/arm64` if the module sets `arm64: true`), signed, with a
    provenance attestation and two SBOMs.

5. **First release of a module only:** new GHCR packages are private.
   Open the package on GitHub (**Packages** on the organisation page →
   the package → **Package settings**) and set **Change visibility** to
   **Public**, once per image.

Tags must be exactly `vX.Y.Z`. A tag like `v1.0.0-rc.1` starts the
workflow but stops in the **Plan** job, because published tags have no
pre-release part.

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

## Related pages

- [Versions and upgrades](../operations/versioning.md): what tags mean and how to pin them.
- [Changelogs](changelog.md): what goes into a release section.
