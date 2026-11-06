# Changelogs

Every Con Services repository has its own `CHANGELOG.md` at its root: the
suite (`con-services`) and each module (`den`, `hr`, `Rally`, …). A module's
changelog describes that module; the suite's describes the shared pieces
(Kubernetes manifests and Helm charts, compose file, Keycloak realm, proxy,
scripts and these docs).

The changelogs follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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

A release is a version `MAJOR.MINOR.PATCH` following
[Semantic Versioning](https://semver.org), and gets its own section in the
changelog. The release's images are tagged `MAJOR.MINOR.PATCH-BUILD`, for
example `1.4.2-1`; `BUILD` counts rebuilds of the same version (for example
for a base-image security update) and starts at `1` again for every new
version. Rebuilds do not get a changelog section, because Con Services'
own code did not change. All images of one module share the tag, and
`latest` is never published. See
[Versions and upgrades](../operations/versioning.md).

Entries that require action on upgrade start with **BREAKING:** and say
what to do, for example a renamed setting or a new network policy. Such a
change also bumps `MAJOR`:

```markdown
## [2.0.0] - 2027-02-01

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

1. Rename `## [Unreleased]` to `## [<version>] - <date>`.
2. Add a new, empty `## [Unreleased]` above it.
3. Build and publish the images with the tag `<version>-1`, all images of
   the module with the same tag.
4. Update the pinned tags in `deploy/kubernetes/overlays/*`, the Helm
   chart's `values.yaml` and `appVersion`, and the docs that show the tag.

## Troubleshooting

**Which changelog does my change go in?**
: Code in a module repository: that module's. Root `docker-compose.yml`,
  `infra/`, the Keycloak realm, Caddy, `deploy/kubernetes/`,
  `deploy/charts/` and these docs: the root `CHANGELOG.md` in
  `con-services`.

**A rebuild with only a base-image update**
: No changelog section; increase `BUILD` (`1.4.2-1` → `1.4.2-2`).

**I forgot an entry and the release is out**
: Add it to the released section with a note `(added after release)`;
  do not move it to `Unreleased`.
