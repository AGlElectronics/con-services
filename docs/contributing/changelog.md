# Changelogs

Every Con Services repository has its own `CHANGELOG.md` at its root: the
suite (`con-services`) and each app (`den`, `hr`, `Rally`, …). Each app
(Den and every module) has its own version
([Versions and upgrades](../operations/versioning.md)), and its changelog
has one section per release of that app. It describes everything that
release changes, including its Helm chart in `deploy/charts/<app>`, which
is released with the app. The suite's changelog describes only the shared
pieces (Kustomize manifests, compose file, Keycloak realm, proxy, CI
workflows, scripts and these docs); its releases are the `con-services`
tags `vX.Y.Z`
([The main repository's own tags](../operations/versioning.md#the-main-repositorys-own-tags)).
Every changelog starts at `1.0.0`.

The changelogs follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
The [Changelog](../changelog.md) page of this site shows the suite's
changelog and links to every other one. It is built from the root
`CHANGELOG.md`, so write links to docs pages there as `docs/<page>.md`
(they work on GitHub, and the site turns them into links between pages).

## The format

```markdown
# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Backups page shows the size of every database.

### Fixed

- Pairing URLs no longer expire early when the server clock is ahead.

## [1.0.0] - 2026-12-01

### Added

- First release.
```

- The newest changes are at the top.
- Changes that are not released yet go under **`## [Unreleased]`**.
- Each release gets a heading with its version and date (`YYYY-MM-DD`).
- In a module's changelog, every release section starts with a
  **Needs Den** line: the oldest Den version it works with and its Den
  MAJOR, for example `Needs Den: 1.5.0 or later (Den MAJOR 1).` Operators
  read it to know whether they must upgrade Den first
  ([Does this update need Den too?](../operations/versioning.md#does-this-update-need-den-too)).
  Den's own changelog has no such line.
- Changes are grouped under these headings, in this order, and only the
  ones that are needed:

| Heading | For |
| --- | --- |
| `### Added` | New features. |
| `### Changed` | Changes to existing behaviour. |
| `### Deprecated` | Features that will be removed later. |
| `### Removed` | Features removed now. |
| `### Fixed` | Bug fixes. |
| `### Security` | Fixes for vulnerabilities. |

## Writing entries

- Write for the people who **run or use** the software, not for developers:
  what changed for them, not which files changed.
- One line per change, starting with what changed.
- Mention anything that needs action, such as a new required setting or a
  manual step, and link to the docs page that explains it.
- Reference an issue when there is one, for example `(#42)`.

## Versions and image tags

A release is a version `MAJOR.MINOR.PATCH` of one app and gets its own
section in that app's changelog. The numbers follow the Den-led rules on
[Versions and upgrades](../operations/versioning.md#the-rules):

- **Den:** MAJOR only when something modules use is removed or changed
  incompatibly; MINOR when something is added; PATCH for fixes. A Den
  MINOR or PATCH never removes or deprecates a feature.
- **Modules:** MAJOR always equals the Den MAJOR the module is built for;
  MINOR for features (even big ones); PATCH for fixes. When Den releases a
  new MAJOR, the module's next release takes that MAJOR and keeps counting
  MINOR and PATCH (`1.12.1` → `2.12.1`).

The release's images are tagged `MAJOR.MINOR.PATCH-BUILD`, for
example `1.4.2-1`; `BUILD` counts rebuilds of the same version (for example
for a base-image security update) and starts at `1` again for every new
version. Rebuilds do not get a changelog section, because Con Services'
own code did not change. All images of one app share the tag, and
`latest` is never published.

Entries that require action on upgrade start with **BREAKING:** and say
what to do, for example a renamed setting or a new network policy. In
Den, an entry that breaks modules comes with a new Den MAJOR:

```markdown
## [2.0.0] - 2027-02-01

### Removed

- **BREAKING:** The pairing endpoint `POST /api/pair/legacy` is gone; modules
  use `POST /api/pairing`. Upgrade every module to its 2.x release in the
  same change ([Den MAJOR upgrades](https://aglelectronics.github.io/con-services/operations/versioning/#den-major-upgrades)).
```

A module cannot raise its MAJOR, so a module release that needs action
from operators is a MINOR whose entries say so:

```markdown
## [1.4.0] - 2027-02-01

Needs Den: 1.0.0 or later (Den MAJOR 1).

### Changed

- **BREAKING:** `S3_BUCKET_NAME` is now `S3_BUCKET`. Rename it in your
  overlay or Helm values before upgrading
  ([configuration](https://aglelectronics.github.io/con-services/modules/stash/configuration/)).
- **BREAKING:** Stash now calls Learn's API. Add the egress rule in
  `conservices-stash` and the ingress rule in `conservices-learn`
  ([network policies](https://aglelectronics.github.io/con-services/operations/network-policies/#calls-between-modules)).
```

Operators read these entries during an upgrade (see
[Upgrading](../operations/versioning.md#upgrading)), so each one must be
doable without reading the code.

## When to update it

Add the entry in the same commit or merge request as the change. When you
release:

1. Rename `## [Unreleased]` to `## [<version>] - <date>` in the app's
   changelog and, for a module, add the *Needs Den* line.
2. Add a new, empty `## [Unreleased]` above it.
3. Build and publish the images with the tag `<version>-1` (tag
   `v<version>` in the app's repository), all images of the app with the
   same tag.
4. In `con-services`, set the chart's `version` and `appVersion` to
   `<version>`, its image tags in `values.yaml` to `<version>-1`, the
   pinned tags in `deploy/kubernetes/overlays/*` if the app has any, and
   the compatibility table; then tag `<app>/v<version>`. The steps with
   commands are in [CI and releases](ci.md#cut-a-release).

Only the app that changed is released. The suite's `CHANGELOG.md` gets an
entry only when a shared piece changed; to release it, rename its
`## [Unreleased]` the same way and tag `vX.Y.Z` on that commit in
`con-services`.

## Troubleshooting

**Which changelog does my change go in?**
: Code in an app's repository, and that app's chart in
  `deploy/charts/<app>`: the app's (the chart is released with it). Root
  `docker-compose.yml`, `infra/`, the Keycloak realm, Caddy,
  `deploy/kubernetes/`, the CI workflows and these docs: the root
  `CHANGELOG.md` in `con-services`. The Argo CD template (`cluster.yaml`,
  its charts and bootstrap scripts): `CHANGELOG.md` in
  `con-services-gitops`.

**I changed only a chart; do I need a new app version?**
: Yes. The chart is versioned with its app, so a chart change is a PATCH
  (fix) or MINOR (new setting) of the app, with a section in the app's
  changelog and images of that version (tag the app's repository on the
  unchanged code). The pull request check fails if a chart changed without
  a version bump.

**A link in the root `CHANGELOG.md` is broken on the site, and `mkdocs build --strict` fails**
: Write links to docs pages as `docs/<page>.md` (relative to the
  repository root), not `../docs/...` or `<page>.md`. The site rewrites
  only links that start with `docs/`.

**A rebuild with only a base-image update**
: No changelog section; increase `BUILD` (`1.4.2-1` → `1.4.2-2`).

**I forgot an entry and the release is out**
: Add it to the released section with a note `(added after release)`;
  do not move it to `Unreleased`.
