# Changelog

What changed in each release of Con Services. Den and every module have
their own version, starting at `1.0.0`
([Versions and upgrades](operations/versioning.md)). Before you upgrade an
app, read the entries between your current version and the new one in that
app's changelog; entries that need action start with **BREAKING:** and say
what to do ([Upgrading](operations/versioning.md#upgrading)).

Con Services has one changelog per repository:

| Repository | What its changelog covers | Changelog |
| --- | --- | --- |
| `con-services` (this site) | The shared pieces, released as `vX.Y.Z`: Kustomize manifests, the Docker stack, Keycloak realm, proxy, CI workflows, scripts and these docs. Each app's Helm chart in `deploy/charts/<app>` is released with the app (tag `<app>/vX.Y.Z`) and described in the app's changelog. | [below](#the-suite-con-services) |
| `con-services-gitops` | The Argo CD template: `cluster.yaml` settings, sync waves, bootstrap scripts, cluster prerequisites | [CHANGELOG.md](https://github.com/AGlElectronics/con-services-gitops/blob/main/CHANGELOG.md) |
| `den` | Den | [CHANGELOG.md](https://github.com/AGlElectronics/den/blob/main/CHANGELOG.md) |
| `hr` | HR | [CHANGELOG.md](https://github.com/AGlElectronics/hr/blob/main/CHANGELOG.md) |
| `Rally` | Rally (Events) | [CHANGELOG.md](https://github.com/AGlElectronics/Rally/blob/main/CHANGELOG.md) |
| `stash` | Stash | [CHANGELOG.md](https://github.com/AGlElectronics/stash/blob/main/CHANGELOG.md) |
| `finance` | Finance | [CHANGELOG.md](https://github.com/AGlElectronics/finance/blob/main/CHANGELOG.md) |
| `learn` | Learn | [CHANGELOG.md](https://github.com/AGlElectronics/learn/blob/main/CHANGELOG.md) |
| `wiki` | Wiki | [CHANGELOG.md](https://github.com/AGlElectronics/wiki/blob/main/CHANGELOG.md) |
| `desk` | Desk | [CHANGELOG.md](https://github.com/AGlElectronics/desk/blob/main/CHANGELOG.md) |
| `tasks` | Tasks | [CHANGELOG.md](https://github.com/AGlElectronics/tasks/blob/main/CHANGELOG.md) |

Installing with the Argo CD template? Read both the suite's changelog below
and the template's: a new release of an app changes that app's
`den.version` or `modules.<name>.version` in `cluster.yaml`, a new template
release changes the template itself. Each app's own changelog is in the
table above.

How entries are written: [Changelogs](contributing/changelog.md).

## The suite (`con-services`)

This section is the file `CHANGELOG.md` at the root of the repository,
shown here as it is on `main`.

<!-- root-changelog -->
