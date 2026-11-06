# Documentation standards

Documentation is part of every change, not a follow-up. Con Services is
intended to be open source; the public site is how operators and integrators
learn the suite.

## Where documentation lives

- The public site is built from this repository: `mkdocs.yml` plus `docs/`,
  published to GitHub Pages by `.github/workflows/docs.yml`.
- Each module (den, hr, Rally, stash, finance, wiki, desk, learn, tasks) is
  its own repository under `github.com/AGlElectronics/<module>`. Its
  `README.md` stays a short entry point that links to that module's section
  of the site.
- Decisions with lasting consequences get an ADR in the module's
  `docs/adr/`.

## When you change code

In the same change:

1. **Update the docs page** that describes the behaviour (setup,
   configuration, authentication, operations, or the module guide). If no
   page covers it, add one and link it from `mkdocs.yml` `nav`.
2. **Document every API change.** For each new or changed endpoint: method
   and path, who may call it (authentication and required role or
   permission), request body, response body, error codes, and at least one
   copy-pasteable `curl` example with a realistic response.
3. **Document every new environment variable** in the module's configuration
   reference table (name, default, required or not, what it does) and in
   `.env.example`.
4. **Add a changelog entry** to the module's `CHANGELOG.md` under
   `## [Unreleased]`, following
   [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) with the
   sections Added, Changed, Deprecated, Removed, Fixed, Security. Write
   entries for operators and users, not commit messages. Breaking changes
   start with **BREAKING:** and say what to do.
5. Changes to shared infrastructure (root `docker-compose.yml`, `infra/`,
   Keycloak realm, Caddy, `deploy/kubernetes/`, `deploy/charts/`) go in the
   root `CHANGELOG.md`.
6. **Keep the deployment files in sync.** A new or changed service, setting,
   port, probe, secret or cross-module call must be reflected in the
   Kustomize manifests, the Helm chart if the module has one, Compose, and
   the docs. A new connection between pods needs NetworkPolicy allow rules
   on both sides and a row in
   [Network policies](../operations/network-policies.md).
7. **Introducing a secret?** Add it to the inventory on
   [Secrets](../operations/secrets.md), to the example overlay with an
   obvious **dev-only** value, and to the External Secrets example. Point
   production readers at a secret manager; plain Secrets and `.env` files
   are for local trials only.

## Versioning

- Releases are `MAJOR.MINOR.PATCH` (Semantic Versioning), one changelog
  section each.
- Images are
  `ghcr.io/aglelectronics/<module>-<component>:MAJOR.MINOR.PATCH-BUILD`.
  Never publish or reference `latest`; pin exact tags.
- A change that needs action on upgrade bumps `MAJOR` and gets a
  **BREAKING:** entry.

## How to write it

- Assume the reader is new: say what something is before how to use it.
- Every setup or how-to page has numbered steps, a working example, and a
  Troubleshooting section.
- Show examples for everything. Use plain words and full sentences.
- Never put real secrets in docs. Use placeholders such as `change-me`,
  label development defaults as development-only, and link to Secrets
  whenever a page mentions a secret.
- Keep docs true: if behaviour and docs disagree, fixing the docs is part of
  the fix.

## Before the repositories look "open source ready"

Making the suite public is more than flipping visibility. Walk this checklist
(and the same ideas in each module repo) so the first impression is clean:

1. **License.** Add an explicit `LICENSE` (and `NOTICE` if needed) to this
   repo and every module repo. Do not publish without one.
2. **Secrets.** Confirm nothing in git is a real production credential.
   Development defaults in Compose and example overlays (`admin` /
   `adminadmin`, `conservicesdev`, `*-dev-password`, `change-me`) are fine
   only when clearly labelled as local-development values.
3. **Local-only clutter.** Keep editor folders (`.cursor/`, `.vscode/`,
   `.idea/`), log files, database dumps (`backups/`), security scratch
   notes, and personal agent reference trees out of git.
4. **README.** Root and module READMEs should say what the project is, how
   to find the docs site, and how to run a development stack — not a dump of
   unfinished notes.
5. **Issues and security.** Add a short security-contact path (for example
   `SECURITY.md`) before inviting external reports.
6. **Presentable history.** Do not force-push shared module history casually;
   do scrub accidental secrets and editor config from history *before* the
   first wide announcement if they ever landed in a commit.
