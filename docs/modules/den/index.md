# Den

**Den** is the portal and admin console of Con Services. Its goal is to
make a set of separate modules feel like **one product**: one place to
start, one brand, one set of organisation-wide settings, and one admin
console that knows which modules exist and keeps their data backed up.
Everyone in the organisation lands on Den after signing in; administrators
use it to register and **pair** modules, set the brand and settings that
every paired module follows, and run backups. Den is installed first and
every other module is configured relative to it, but it holds no accounts
or business data of its own: people live in Keycloak, and each module owns
its own data. Integrators and scripts use the same
[HTTP API](api.md) as Den's web app.

Source: [AGlElectronics/den](https://github.com/AGlElectronics/den)

## What Den does

- **Portal home** for everyone in the organisation: the services they can
  open, plus to-dos collected from those services.
- **Module registry**: which modules the organisation runs and where they
  live.
- **Pairing**: connects modules to Den with one-time pairing URLs, so they
  follow Den's brand and settings. See [Pairing](../../concepts/pairing.md).
- **Branding**: colours, fonts, wording, logo, favicon and a sign-in
  background, with a live preview. Paired modules and the Keycloak sign-in
  page pick it up automatically.
- **Organisation settings**: a JSON document of organisation-wide settings,
  such as the organisation's name and email domain, read by paired modules.
- **Keycloak sign-in page**: the `conservices` login theme fetches the brand
  from Den, so the sign-in page matches; optionally Den also keeps the
  realm's display name equal to the organisation name.
- **Module settings**: retention, e-mail, Finance seller details, Stash Lost
  & Found, the Rally submission site and identity links, handed to paired
  modules.
- **Audit log**: every change made in Den, with who made it.
- **Roles from groups**: `den-admin`, `den-member` and `den-ops` (backups
  and database deletion).
- **User preferences**: each person's light or dark theme, shared by every
  app.
- **Databases and backups** through Den's operator: creates a database for a
  new module, deletes it when the module is removed (after a backup), and
  makes a nightly encrypted backup of the whole suite.

Den does **not** hold accounts or passwords. Sign-in happens at the
identity provider (Keycloak); Den only checks the tokens. See
[Authentication](../../concepts/authentication.md).

## How Den is built

| Part | Technology | Runs as |
| --- | --- | --- |
| Backend | Go 1.27, chi router, pgx, go-oidc, zerolog | Deployment `den-backend` (binary `/den-server`) |
| Migrations | Goose, SQL files embedded in the binary | initContainer `migrate` in `den-backend` (binary `/den-migrate`) |
| Operator | Go, `pg_dump`/`pg_dumpall`, age encryption | Deployment `den-operator` |
| Frontend | React 19, Rsbuild, TanStack Router and Query, Tailwind | Deployment `den-frontend` (nginx) |
| Database | PostgreSQL 16, database `den` | shared server |
| File storage | S3-compatible bucket (`den-data` on Kubernetes, `den-data-dev` in Compose) | shared server |

All three Deployments live in the namespace `conservices-den`.

## Images

Den is published as three images, all with the same tag for a release (see
[Versions and upgrades](../../operations/versioning.md)):

| Image | Built from | Contains |
| --- | --- | --- |
| `ghcr.io/aglelectronics/den-backend:<tag>` | `infra/Dockerfile.backend` | `/den-server` and `/den-migrate`. The migrate step uses the same image with `command: ["/den-migrate"]`. |
| `ghcr.io/aglelectronics/den-frontend:<tag>` | `infra/Dockerfile.frontend` | The web app served by nginx (non-root as UID 101, port 8080). |
| `ghcr.io/aglelectronics/den-operator:<tag>` | `infra/Dockerfile.operator` | The operator on Alpine with only the PostgreSQL 16 client tools (`pg_dump`, `pg_dumpall`, `psql`, `pg_restore`), so its backup tools match the server, plus `age` for restores. Runs as `postgres` (UID 70). |

!!! note "The operator image has a shell"
    Unlike the backend image, the operator image is not shell-less: the
    PostgreSQL client tools need Alpine's libraries, and Alpine ships a
    shell. This is an accepted exception (see the
    [image policy](../../contributing/ci.md#image-policy)). It is also what
    lets you restore a backup from inside the pod
    (`kubectl exec -it -n conservices-den deploy/den-operator -- sh`).

!!! note "The web app's sign-in address is a setting, not part of the image"
    The published `den-frontend` image names no domain. When it starts in
    the browser, the web app loads its sign-in settings (issuer, client id)
    from `/config.json`, which the Helm chart, the Kustomize manifests or
    Docker Compose mount into the container. See
    [Web app settings](configuration.md#web-app-settings-configjson).

## In this section

- [Admin guide](admin-guide.md): every page of the admin console, from an
  administrator's point of view.
- [Configuration](configuration.md): every environment variable Den reads.
- [API reference](api.md): every HTTP endpoint, with examples.

New to Den? Try it with [Run Den on Kubernetes](../../getting-started/den-quickstart.md),
a local trial cluster. For production, Den is installed with the other
modules by the Argo CD path: [Den and the modules](../../deploy/apps.md).

Design decisions are recorded in Den's
[ADRs](https://github.com/AGlElectronics/den/tree/main/docs/adr) and its
[domain model](https://github.com/AGlElectronics/den/blob/main/docs/domain-model.md).
