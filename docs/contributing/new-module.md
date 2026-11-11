# Wiring a new module

**Goal:** add a new module to the suite so that it runs in the development
stack, on Kubernetes (Helm chart and the Argo CD template) and on Docker
production, with sign-in, a database, files, secrets, network rules and
docs. Every module so far went through these steps; missing one shows up
later as a module that cannot sign in, is not backed up, or cannot reach
Den.

The examples use a new module **`shop`** with the web client `shop-spa`,
the database and role `shop`, the bucket `shop-data-dev` in development,
host `shop.<domain>`, backend port `8080` in the container, and the next
free host ports in the dev stack (`8170` for the API, `3011` for the web
app). Replace them with your module's names.

Before you start, the module's own repository should exist under
`github.com/AGlElectronics/shop`, with `backend/` (Go, `infra/Dockerfile.backend`
on `gcr.io/distroless/static-debian12:nonroot`), `frontend/`
(`infra/Dockerfile.frontend` on `nginxinc/nginx-unprivileged`),
`infra/nginx.conf` (Kubernetes) and `infra/nginx.stack.conf` (Docker, with
`server shop-backend:8080 resolve;` and
`include /etc/nginx/snippets/security-headers.conf;`), and a
`CHANGELOG.md`.

## Part 1: Development stack

All paths are in the root repository `con-services` unless they start
with `shop/`.

1. **Workspace.** Add `shop` to the repository lists in
   `scripts/workspace.ps1` (`$repos`) and `scripts/workspace.sh`
   (`repos=(...)`), and `/shop/` to `.gitignore`. Then:

    ```powershell
    ./scripts/workspace.ps1 clone
    ```

    You should see `shop` cloned next to the other modules.

2. **Shared code.** Copy the shared Go packages the backend uses into it
   and keep them in sync (see [Shared code](../concepts/shared-code.md)):

    ```powershell
    ./scripts/sync-shared.ps1 -Modules shop -Packages authbase,denlink,groupmatch
    ```

    Copy `shared/nginx/security-headers.conf` into `shop/infra/` as the
    snippet the web app's nginx includes.

3. **Keycloak, dev realm.** In `infra/keycloak/realm-conservices.json`
   add the public client `shop-spa` (copy `wiki-spa`: PKCE `S256`, the
   `groups` mapper, redirect URIs `https://shop.conservices.test/*` and
   `http://localhost:3011/*`) and the groups the module uses, for example
   `shop-admin`. The realm file is imported only into a new dev database,
   so also add the client to `infra/keycloak/apply-mvp.sh`, which updates
   an existing dev realm:

    ```sh
    module_spa shop-spa "Shop SPA"
    spa_urls shop-spa 3011 shop.conservices.test
    ```

4. **Database.** In `infra/postgres/01-init-databases.sh` add the role
   (`CREATE ROLE shop LOGIN PASSWORD 'shop'`, dev only) and `shop` to the
   database loop and its owner `case`. The script runs only on a new data
   volume; on an existing one create them once by hand:

    ```sh
    docker compose exec postgres psql -U postgres -c "CREATE ROLE shop LOGIN PASSWORD 'shop'" -c "CREATE DATABASE shop OWNER shop"
    ```

5. **Bucket** (only if the module stores files). Append `shop-data-dev` to
   the `-bucket=` list of the `s3` service **and** to `FILES_S3_BUCKETS`
   of `den-operator` in `docker-compose.yml`, so Den's backups include it.

6. **Compose services.** In `docker-compose.yml`, add `shop-migrate`,
   `shop-backend` and `shop-frontend` with `profiles: ["shop"]`, copied
   from Wiki or Tasks:
    - ports bound to loopback: `"127.0.0.1:8170:8080"` and
      `"127.0.0.1:3011:8080"`;
    - `APP_ENV: development`, `DEN_MODE: ${DEN_MODE:-standalone}`,
      `DEN_INTERNAL_URL: http://den-backend:8080`, a public dev
      `DEN_LINK_ENCRYPTION_KEY` (`openssl rand -base64 32`, labelled DEV
      ONLY), `OIDC_*` with `shop-spa`, `TRUSTED_PROXY_CIDRS`, the S3 values;
    - `depends_on` with `condition: service_healthy` for `keycloak`, `s3`
      and the backend (once its image has a `healthcheck` subcommand like
      `/den-server healthcheck`, add the healthcheck and let the web app
      wait for `service_healthy`);
    - the web app's healthcheck
      (`wget -q --spider http://127.0.0.1:8080/`) and its config mount
      `./infra/frontend-config/shop.json:/etc/conservices/config.json:ro`.

7. **Web app settings.** Create `infra/frontend-config/shop.json` (copy
   `wiki.json`, set `"oidcClientId": "shop-spa"` and `"productName"`).

8. **Proxy and local names.** In `infra/proxy/Caddyfile` add

    ```text
    shop.conservices.test {
    	import hsts
    	reverse_proxy shop-frontend:8080
    }
    ```

    add `shop.conservices.test` to the `proxy` service's network aliases
    in `docker-compose.yml`, to `$names` in `scripts/setup-local-dns.ps1`,
    and to the `/etc/hosts` line in
    [Local development](local-development.md#run-den-from-source). Run
    `setup-local-dns.ps1` again.

9. **HR and other modules.** If the module offers roles, add
   `shop=http://shop-backend:8080/api/role-catalog` to `ROLE_CATALOG_SOURCES`
   of `hr-backend` (see [Role catalog](../concepts/role-catalog.md)), and
   any hook it serves to HR's `OFFBOARD_HOOKS` or `DEPARTMENT_HOOKS` with a
   dev service token.

10. **Smoke test.** Add the module to the catalog list in
    `scripts/smoke-access-catalog.ps1` and, if it has its own flow, a
    `scripts/smoke-shop.ps1` (see [CI and releases](ci.md#smoke-tests)).

11. **Check it:**

    ```sh
    docker compose --profile den --profile shop config --quiet
    docker compose --profile den --profile shop up -d --build shop-frontend
    curl -s http://localhost:8170/readyz
    ```

    ```json
    {"database":"ok","status":"ok","version":"dev"}
    ```

    Then open `https://shop.conservices.test`, sign in as `admin` /
    `adminadmin`, and pair the module from Den.

## Part 2: Kubernetes and the Argo CD template

12. **Helm chart.** Copy the chart of a similar module to
    `deploy/charts/shop` and rename. Keep: `version` = `appVersion` =
    `1.0.0` (the module's version), the annotation
    `conservices.io/den-major`, image tags `1.0.0-1`, `den.mode: required`,
    `route.responseHeaders` (HSTS), the NetworkPolicies, Pod Security
    settings and `existingSecret`. Check:

    ```sh
    helm lint --strict deploy/charts/shop
    python3 scripts/check-chart-versions.py
    ```

13. **Network policies.** Label the namespace
    `conservices.io/tier=module` and `conservices.io/module=shop`, and add
    the allow rules for every new connection on **both** sides (for
    example HR → shop for the role catalog: egress in `conservices-hr`,
    ingress in `conservices-shop`) and a row in
    [Every allowed flow](../operations/network-policies.md#every-allowed-flow).
    The rules are on [Rules for a new module](../operations/network-policies.md#rules-for-a-new-module).

14. **Argo CD template** (`con-services-gitops`), as described on
    [Add a new module](../deploy/apps.md#add-a-new-module):
    - `root.moduleNames` and `root.moduleMeta` in
      `charts/root/templates/_helpers.tpl` (role, host label, slug, title,
      `s3`, `migrate`, `access`); this also gives it a database
      ([details](../deploy/data.md#add-a-database-for-a-new-module)), its
      generated `DEN_LINK_ENCRYPTION_KEY` (`modules/shop/den-link`) and its
      bucket in Den's backups;
    - `modules.shop` in `charts/root/values.yaml`, the schema and
      `cluster.yaml`;
    - `charts/module-extras/templates/shop.yaml` (the ExternalSecret,
      including `DEN_LINK_ENCRYPTION_KEY`) and
      `charts/module-extras/files/access-config/shop.toml` if it reads an
      access configuration;
    - `shop` in `APP_HOSTS` of `bootstrap/scripts/keycloak-realm.py` and
      under `appHosts` in `charts/keycloak/values.yaml`, then regenerate
      the realm templates ([The realms](../deploy/identity.md#the-realms));
    - HR's `ROLE_CATALOG_SOURCES` and `moduleEgressNamespaces` in
      `charts/root/templates/_apps.tpl`, if HR calls it.

    Run the template's checks (`python ci/render.py ...`,
    `python ci/check.py build/rendered`); `check.py` fails when an
    ExternalSecret reads an OpenBao path that is not in the seed plan.

15. **Kustomize.** `deploy/kubernetes/modules/` holds only Stash, as the
    example of a module without a chart; nothing to add there.

## Part 3: Docker production

16. In `deploy/docker/`:
    - `compose.production.yml`: `shop-migrate`, `shop-backend`,
      `shop-frontend` with `profiles: ["shop"]`, using the `x-backend`,
      `x-frontend` and `x-module-env` anchors; module variables as
      `${SHOP_...:-}` (Compose checks every service, also those of
      profiles that are off);
    - `Caddyfile`: a `shop.{$DOMAIN}` site with `import common`;
    - `.env.example`: a commented `SHOP_*` block;
    - `postgres/init-databases.sh` and the `postgres-init` environment:
      `ensure shop shop "${SHOP_DB_PASSWORD:-}"`;
    - `web-config/shop.json`;
    - the module's step in [Docker production](../operations/docker-production.md).

    Check:

    ```sh
    docker compose -f deploy/docker/compose.production.yml --env-file deploy/docker/.env.example config --quiet
    ```

## Part 4: Secrets and docs

17. **Secrets.** Add every secret the module reads to the inventory on
    [Secrets](../operations/secrets.md#inventory) (name, Secret and
    namespace, who uses it, how to rotate it), a dev value to the example
    overlay's `secrets.yaml` if it has a Kustomize example, the
    `ExternalSecret` example, and the test value to the table on
    [Production](../operations/production.md#secrets).
18. **Docs.** Add `docs/modules/shop/` (`index.md`, `setup.md`,
    `configuration.md` with every variable, `api.md` with every endpoint)
    and link it from `mkdocs.yml` `nav`. Check:

    ```sh
    mkdocs build --strict
    ```

19. **Changelogs.** The module's first release in `shop/CHANGELOG.md`;
    the root changes (Compose, realm, Caddy, scripts) in the root
    `CHANGELOG.md`; the template changes in the GitOps `CHANGELOG.md`.

## Troubleshooting

**Sign-in says *Invalid parameter: redirect_uri***
: The client `shop-spa` is missing in the running realm or lacks the
  address. The realm file is imported only once: run `apply-mvp.sh` in dev
  (`docker compose exec keycloak bash /opt/keycloak/data/import/apply-mvp.sh`)
  or add the client in the admin console.

**`shop-backend` exits with `password authentication failed for user "shop"`**
: The dev database volume existed before you added the role. Create it by
  hand (step 4).

**HR shows no Shop roles**
: `ROLE_CATALOG_SOURCES` lacks `shop=…`, or (Kubernetes) the NetworkPolicy
  from HR to `conservices-shop` is missing on one of the two sides.

**Den's backup does not contain the module's files**
: The bucket is missing from `FILES_S3_BUCKETS` (dev stack, Docker
  production) or the module has `s3: false` in `root.moduleMeta`
  (Argo CD template).

**The Argo CD template's CI fails with `reads … which is not in the seed plan`**
: The ExternalSecret in `module-extras` reads an OpenBao path the root
  chart does not generate or ask for. Check `root.moduleMeta` and the
  `root.seedPlan` helper.

## Related pages

- [Local development](local-development.md)
- [Add a new module (Argo CD)](../deploy/apps.md#add-a-new-module)
- [Network policies: rules for a new module](../operations/network-policies.md#rules-for-a-new-module)
- [Secrets](../operations/secrets.md)
- [Shared code](../concepts/shared-code.md)
