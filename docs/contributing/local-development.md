# Local development with Docker Compose

Deployments run on Kubernetes (see [Getting started](../getting-started/index.md)).
For **working on the code**, the root repository also has a Docker Compose
stack that builds every module from your local checkouts and runs them with
a local HTTPS proxy. This page explains how to use it.

!!! warning "Development only"
    The Compose stack uses fixed, public passwords, a local S3 server,
    Mailpit and a dev realm. It is never a way to run Con Services for real.

## What it contains

Everything is defined in the root `docker-compose.yml`. Shared services
(PostgreSQL, the S3 server, Keycloak, the Caddy proxy, Mailpit, Adminer) have no
profile and are always available. Each module's services sit in a
**profile** named after the module (`den`, `events`, `learn`, `desk`,
`tasks`, `wiki`); Stash, HR and Finance currently have no profile.

| Piece | Address |
| --- | --- |
| Caddy proxy (HTTPS, `*.conservices.test`) | ports 80 and 443 |
| Keycloak | <https://auth.conservices.test>, direct <http://localhost:8085> |
| Den web app | <https://den.conservices.test>, direct <http://localhost:3001> |
| Den API | direct <http://localhost:8090> |
| PostgreSQL 16 | `localhost:5432` |
| S3 storage (SeaweedFS, service `s3`) | <https://s3.conservices.test>, direct `http://localhost:9000` (S3 API only, no web console) |
| Mailpit | <https://mail.conservices.test>, direct <http://localhost:8025> |
| Adminer | <https://db.conservices.test>, direct <http://localhost:8095> |

### How the stack protects your computer

The passwords in the stack are public, so the stack keeps itself off your
network:

- **Every published port is bound to `127.0.0.1`** (for example
  `"127.0.0.1:5432:5432"`). Only programs on your own computer can reach
  PostgreSQL, the S3 server, Keycloak or a backend; other devices on your
  Wi-Fi cannot. To open a port to your network on purpose (for example to
  test on a phone), use a `docker-compose.override.yml` that is not
  committed, and only on a network you trust.
- **Third-party images are pinned** to exact versions (`adminer:6.3.0`,
  `axllent/mailpit:v1.33.1`, `greenmail/standalone:2.1.15`,
  `caddy:2.11.9-alpine`). Raise a pin in a change of its own.
- **Healthchecks:** PostgreSQL, the S3 server, Keycloak, Mailpit, GreenMail,
  Adminer, the proxy, Den's backend and operator, and every web app report
  `healthy` in `docker compose ps`. Services that need one of them wait for
  `healthy`, not just "started". Den's web app waits for a healthy Den
  backend. The other module backends get a healthcheck once their image
  has a `healthcheck` subcommand like Den's (`/den-server healthcheck`);
  their images have no shell or curl to probe with.
- **Non-root:** the module backends (distroless `nonroot`), the web apps
  (nginx as UID 101), Keycloak, Adminer, GreenMail and Mailpit (`user:
  "1000:1000"`) run as normal users. PostgreSQL starts as root and switches
  to its own user. The proxy and the S3 server stay root because their
  volumes were created by root; the proxy keeps only the capability to
  bind ports 80 and 443.
- **HSTS:** the proxy sends `Strict-Transport-Security` for every
  `*.conservices.test` host, like production. The web apps' own
  security headers (CSP, frame protection) come from their nginx.

## The workspace

Con Services is spread over several Git repositories. You work in one
folder, the **workspace**: a checkout of the root repository `con-services`
with the other repositories cloned into subfolders of the same name.

```text
con-services/              root repository: charts, manifests, docs, Compose stack
├── den/                   AGlElectronics/den
├── hr/  Rally/  stash/    AGlElectronics/hr, Rally, stash
├── finance/  wiki/  desk/ AGlElectronics/finance, wiki, desk
├── learn/  tasks/         AGlElectronics/learn, tasks
└── con-services-gitops/   AGlElectronics/con-services-gitops (Argo CD template)
```

Each subfolder is its own repository with its own history; the root
repository ignores them (`.gitignore`), so a commit in `den/` never shows up
in `con-services`. Commit and push in the folder you changed.

`scripts/workspace.ps1` (Windows) and `scripts/workspace.sh` (macOS, Linux)
manage all of them at once:

| Command | What it does |
| --- | --- |
| `clone` | Clones every repository that is missing. Private modules need access to them; the script warns and continues when a clone fails. |
| `status` | Shows branch, number of uncommitted files and commits ahead/behind for every repository. |
| `pull` | Fast-forwards every repository without uncommitted changes; skips the others. |

```powershell
./scripts/workspace.ps1 status
```

You should see one line per repository:

```text
Repo                Branch Dirty Ahead Behind
con-services        main       0 0     0
den                 main       2 0     0
...
```

## Run Den from source

1. Install Docker Desktop and Git, then clone the root repository and the
   other repositories into it:

    === "Windows"

        ```powershell
        git clone https://github.com/AGlElectronics/con-services.git
        cd con-services
        ./scripts/workspace.ps1 clone
        ```

    === "macOS / Linux"

        ```sh
        git clone https://github.com/AGlElectronics/con-services.git
        cd con-services
        scripts/workspace.sh clone
        ```

    You should see `ok` or a clone message for each repository. To work on
    Den alone, `git clone https://github.com/AGlElectronics/den.git den`
    inside `con-services` is enough.

2. Copy the example settings file (no changes needed):

    === "Windows"

        ```powershell
        Copy-Item .env.example .env
        ```

    === "macOS / Linux"

        ```sh
        cp .env.example .env
        ```

    Every module backend in the stack starts with `DEN_MODE=standalone`,
    so it works without Den. To try the Kubernetes behaviour, where a
    module waits until it is paired, set `DEN_MODE=required` in `.env` and
    recreate the backends (`docker compose up -d`); see
    [Required or standalone](../concepts/pairing.md#required-or-standalone).

    `.env` is also where optional values go that the stack reads from your
    environment:

    | Variable | Default | What it does |
    | --- | --- | --- |
    | `COMPOSE_PROFILES` | none | Profiles started without `--profile`, for example `den,events`. |
    | `DEN_MODE` | `standalone` | `required`: module APIs wait until paired with Den. |
    | `TELEGRAM_BOT_TOKEN` | empty | Bot token for Rally announcements and Learn notifications. Empty: Rally records dry runs, Learn sends nothing to Telegram. A real token is a secret; `.env` is never committed. |

3. Build and start Den with what it depends on:

    ```sh
    docker compose --profile den up -d --build den-frontend den-operator proxy
    ```

    Naming the services keeps Compose from building modules you have not
    cloned. At the end you should see `conservices-den-backend Started`;
    `proxy-ca` and `den-migrate` show `Exited`, which is correct for
    one-off helpers.

4. Check Den is ready:

    ```sh
    curl http://localhost:8090/readyz
    ```

    ```json
    {"database":"ok","status":"ok","version":"dev"}
    ```

5. Set up the local addresses and trust the proxy certificate, once per
   computer. On Windows run
   `powershell -ExecutionPolicy Bypass -File .\scripts\setup-local-dns.ps1`
   (it asks for administrator rights), then restart the browser. On macOS
   and Linux add the hosts entries by hand and trust Caddy's certificate:

    ```sh
    echo "127.0.0.1 auth.conservices.test den.conservices.test hr.conservices.test stash.conservices.test events.conservices.test learn.conservices.test finance.conservices.test desk.conservices.test tasks.conservices.test wiki.conservices.test submit.conservices.test mail.conservices.test s3.conservices.test db.conservices.test" | sudo tee -a /etc/hosts
    docker cp conservices-proxy:/data/caddy/pki/authorities/local/root.crt ./conservices-local-root.crt
    ```

    Then add `conservices-local-root.crt` to the system's trusted
    certificates (macOS: `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ./conservices-local-root.crt`;
    Debian/Ubuntu: copy it to `/usr/local/share/ca-certificates/` and run
    `sudo update-ca-certificates`).

6. Open <https://den.conservices.test> and sign in as `admin` / `adminadmin`
   (test account, public password).

## Everyday commands

| Task | Command |
| --- | --- |
| Rebuild after code changes | `docker compose --profile den up -d --build den-frontend den-operator proxy` |
| Follow a log | `docker compose --profile den logs -f den-backend` |
| Pause (keep data) | `docker compose --profile den stop` |
| Start again | `docker compose --profile den start` |
| Remove containers, keep data | `docker compose --profile den down` |
| Start completely fresh (**deletes data**) | `docker compose --profile den down -v` |

Den's migrations run in the one-off `den-migrate` service on every `up`.
After `down -v` the proxy creates a new certificate, so trust it again.

## Object storage (S3)

Modules keep files (uploads, branding images, backups) in **S3-compatible
object storage**: a service that stores files in *buckets* and speaks the
Amazon S3 API. In production that is a managed service such as AWS S3 or
Hetzner Object Storage. For development the Compose stack runs
[SeaweedFS](https://github.com/seaweedfs/seaweedfs) (image
`chrislusf/seaweedfs:4.52`) as the service `s3`, in its single-process
`mini` mode.

- **Keys (DEV ONLY, public):** access key `conservices`, secret key
  `conservicesdev`.
- **Buckets:** created when the container starts, from the `-bucket=` list
  in `docker-compose.yml`: `stash-data-dev`, `den-data-dev`,
  `events-data-dev`, `hr-data-dev`, `finance-data-dev`, `learn-data-dev`,
  `wiki-data-dev`, `tasks-data-dev`, `desk-data-dev` and `conservices-backups`. The service
  only reports `healthy` once they exist, and backends wait for that.
- **Addresses:** backends use `http://s3:9000` with path-style requests.
  Browsers get presigned links on `https://s3.conservices.test` (set by
  `S3_PUBLIC_BASE_URL`); the Caddy proxy forwards them with the original
  `Host` so the signatures stay valid.
- **No web console.** Use any S3 client instead. With the AWS CLI in Docker:

    ```sh
    docker run --rm --network conservices_default \
      -e AWS_ACCESS_KEY_ID=conservices -e AWS_SECRET_ACCESS_KEY=conservicesdev \
      -e AWS_DEFAULT_REGION=us-east-1 \
      amazon/aws-cli:2.31.30 --endpoint-url http://s3:9000 s3 ls
    ```

    ```text
    2026-11-07 15:35:00 conservices-backups
    2026-11-07 15:35:00 den-data-dev
    2026-11-07 15:35:00 events-data-dev
    ...
    ```

To add a bucket for a new module, append it to the `-bucket=` list of the
`s3` service and to `FILES_S3_BUCKETS` of `den-operator` (so Den's backups
include it), then run `docker compose up -d s3 den-operator`. The full
checklist is [Wiring a new module](new-module.md).

## Keeping Compose and Kubernetes in step

The Compose file is the quickest way to see which settings each module
needs, but deployments use the Kustomize manifests in `deploy/kubernetes/`.
When you add or change a setting, change both and the docs in the same
change (see [Contributing](index.md)).

## Troubleshooting

**`Bind for 127.0.0.1:5432 failed: port is already allocated`.** Another
program uses the port (often a locally installed PostgreSQL, IIS or a
local kind cluster from the quickstart on 80/443). Find it with
`Get-NetTCPConnection -LocalPort 5432 -State Listen` (Windows) or
`sudo lsof -i :5432`, and stop it.

**`dependency failed to start: container conservices-keycloak is unhealthy`.**
Keycloak takes up to a few minutes on first start. Watch
`docker compose logs -f keycloak` and run the `up` command again once it
says `started`.

**`den-backend` keeps restarting with `oidc discovery`.** Keycloak was not
ready or was recreated. Run `docker compose --profile den restart den-backend`.

**`service "den-migrate" didn't complete successfully`.** Read
`docker compose --profile den logs den-migrate`. `password authentication
failed` usually means a database volume from an older setup; on a dev
machine `docker compose --profile den down -v` starts fresh.

**`dependency failed to start: container conservices-den-backend is unhealthy`.**
`/den-server healthcheck` failed for too long. Read
`docker compose --profile den logs den-backend`. An `unknown command` or
`exec: "/den-server healthcheck"` error means your `den/` checkout is older
than the healthcheck subcommand: pull it (`./scripts/workspace.ps1 pull`)
and rebuild with `--build`.

**A device on your network cannot open `http://<your-ip>:3001`.** On
purpose: the stack binds its ports to `127.0.0.1` (see
[How the stack protects your computer](#how-the-stack-protects-your-computer)).

**`Bind for 127.0.0.1:9000 failed: port is already allocated`.** Another
container or program holds port 9000. Find it with `docker ps` and
`Get-NetTCPConnection -LocalPort 9000 -State Listen` (Windows) or
`sudo lsof -i :9000`, stop it, then run the `up` command again.

**`dependency failed to start: container conservices-s3 is unhealthy`.** A
bucket from the `-bucket=` list was not created. Read
`docker compose logs s3`; a `permission denied` on `/data` means the volume
was created by another image, so remove `conservices_conservices-s3-data`
(dev data only) and start again.

**Uploads fail in the browser with `SignatureDoesNotMatch` or a CORS
error.** The browser must use `https://s3.conservices.test` through the
proxy, not `localhost:9000`. Check `S3_PUBLIC_BASE_URL` on the backend and
that the hosts entry from step 5 exists.

**`workspace.ps1 clone` says `could not clone <module> (no access?)`.**
Some module repositories are private. Ask a maintainer for access, or
sign in with `gh auth login` so Git uses your GitHub account, then run
`clone` again; repositories that already exist are skipped.

**`workspace.ps1 pull` says `could not fast-forward`.** You have local
commits that are not on GitHub, and GitHub has new commits too. Go into
that folder and run `git pull --rebase`, then resolve any conflicts.

**Certificate warnings or "Can't reach the login server".** Redo step 5 and
restart the browser. The proxy's certificates last 30 days; after long
sleep, `docker compose --profile den restart proxy`.
