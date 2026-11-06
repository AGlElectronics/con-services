# Local development with Docker Compose

Deployments run on Kubernetes (see [Getting started](../getting-started/index.md)).
For **working on the code**, the root repository also has a Docker Compose
stack that builds every module from your local checkouts and runs them with
a local HTTPS proxy. This page explains how to use it.

!!! warning "Development only"
    The Compose stack uses fixed, public passwords, MinIO, Mailpit and a dev
    realm. It is never a way to run Con Services for real.

## What it contains

Everything is defined in the root `docker-compose.yml`. Shared services
(PostgreSQL, MinIO, Keycloak, the Caddy proxy, Mailpit, Adminer) have no
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
| MinIO | API `localhost:9000`, console <http://localhost:9001> |
| Mailpit | <https://mail.conservices.test>, direct <http://localhost:8025> |
| Adminer | <https://db.conservices.test>, direct <http://localhost:8095> |

## Run Den from source

1. Install Docker Desktop and Git, then clone the root repository and Den
   into it:

    ```sh
    git clone https://github.com/AGlElectronics/con-services.git
    cd con-services
    git clone https://github.com/AGlElectronics/den.git den
    ```

    Other modules go into folders of the same name (`hr`, `Rally`, `stash`,
    …) in the same way.

2. Copy the example settings file (no changes needed):

    === "Windows"

        ```powershell
        Copy-Item .env.example .env
        ```

    === "macOS / Linux"

        ```sh
        cp .env.example .env
        ```

3. Build and start Den with what it depends on:

    ```sh
    docker compose --profile den up -d --build den-frontend den-operator proxy
    ```

    Naming the services keeps Compose from building modules you have not
    cloned. At the end you should see `conservices-den-backend Started`;
    `minio-init`, `proxy-ca` and `den-migrate` show `Exited`, which is
    correct for one-off helpers.

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

## Keeping Compose and Kubernetes in step

The Compose file is the quickest way to see which settings each module
needs, but deployments use the Kustomize manifests in `deploy/kubernetes/`.
When you add or change a setting, change both and the docs in the same
change (see [Contributing](index.md)).

## Troubleshooting

**`Bind for 0.0.0.0:5432 failed: port is already allocated`.** Another
program uses the port (often a locally installed PostgreSQL, IIS or a
Kubernetes ingress controller on 80/443). Find it with
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

**Certificate warnings or "Can't reach the login server".** Redo step 5 and
restart the browser. The proxy's certificates last 30 days; after long
sleep, `docker compose --profile den restart proxy`.
