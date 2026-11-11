# Full stack on Docker (production)

**Goal:** run Den, Keycloak and the modules on one Linux server with Docker
Compose, safely enough for a small convention, using the same pinned images
as on Kubernetes.

Kubernetes ([Deploy with Argo CD](../deploy/index.md)) is the recommended
way to run Con Services. Some organisations have one server and no
Kubernetes; for them, **Docker production** is a supported target: a tested
compose file in the root repository, `deploy/docker/compose.production.yml`,
with everything it needs next to it. It is **not** the development stack:
that one ([Local development](../contributing/local-development.md)) builds
from source and uses public passwords.

!!! warning "Know what you give up"
    A single Docker host has no network policies between namespaces, no Pod
    Security, no automatic rescheduling and no rolling upgrades. One host
    failing takes everything down. It suits a small convention with one
    server and good backups. Anything bigger belongs on
    [Kubernetes](running.md).

## What you get

| Piece | In `deploy/docker/` | What it does |
| --- | --- | --- |
| `compose.production.yml` | yes | Every service, pinned images (`ghcr.io/aglelectronics/<app>-<component>:MAJOR.MINOR.PATCH-BUILD`, PostgreSQL `16.15-alpine`, Keycloak `26.8.2`, Caddy `2.11.9-alpine`), healthchecks, non-root users, read-only file systems, only ports 80 and 443 published. Den always runs; each module is a Compose **profile**. |
| `Caddyfile` | yes | The proxy: certificates from Let's Encrypt, HSTS on every host, Keycloak limited to `/realms/` and `/resources/`, the admin console only from your admin networks. |
| `.env.example` | yes | Every setting and secret, as placeholders. Your copy `.env` is written from your secret manager. |
| `postgres/init-databases.sh` | yes | Creates the login and database of Den, Keycloak and every enabled module, if missing. Runs on every `up`, never changes or drops anything. |
| `web-config/*.json` | yes | Each web app's `/config.json` (sign-in address and client). |
| `keycloak/`, `nginx/`, `access-config/` | you create them (step 4) | The clean realm, the login theme, the web apps' nginx files with the security headers, the modules' access configurations. Git ignores them. |

How it differs from the development stack:

| Development stack (`docker-compose.yml`) | Docker production (`deploy/docker/compose.production.yml`) |
| --- | --- |
| Builds every image from local source. | Pulls published images with pinned tags; never `latest`. |
| Passwords written in the compose file. | Secrets only in `.env` (mode 600), written from a secret manager. |
| Keycloak `start-dev` with test users; local S3 server, Mailpit, Adminer, GreenMail. | Keycloak `start` with a clean realm (no people, brute-force protection, password policy); managed S3 and SMTP; **no** dev services. |
| Caddy with its own local certificate authority. | Caddy with Let's Encrypt certificates and HSTS. |
| Ports bound to `127.0.0.1` for your own computer. | Only the proxy publishes ports (80, 443). PostgreSQL and the apps have no published port. |
| `APP_ENV=development`, `DEN_MODE=standalone`. | `APP_ENV=production`, `AUTH_MODE=oidc`, modules wait for Den (`DEN_MODE=required`). |

## Step 1: Prepare the host

1. A Linux server (4 CPU cores and 8 GB RAM are enough for Den and four
   modules) with Docker Engine 27 or later and the Compose plugin 2.30 or
   later. Check:

    ```sh
    docker compose version
    ```

    ```text
    Docker Compose version v2.40.3
    ```

2. A firewall that allows only 22 (from your admin network), 80 and 443.
3. DNS records pointing at the server for every host below your domain
   (`con.example.org` here): `auth`, `auth-admin`, `den`, and one per module
   you run: `hr`, `events` and `submit` (Rally), `stash`, `finance`,
   `learn`, `wiki`, `desk`, `tasks`. A wildcard record `*.con.example.org`
   covers them all.
4. Managed S3 storage (AWS S3, Hetzner Object Storage, Cloudflare R2,
   Backblaze B2, ...; see
   [Production](production.md#object-storage-use-managed-s3)): one bucket
   for Den and one per module that stores files (Stash, Rally, Learn,
   Wiki, Tasks), each with its own key that may only read and write that
   bucket; one read-only key on all of them for Den's backups; and a
   **backup bucket at another provider or account** with its own key.
5. An SMTP account for Keycloak's password resets and the modules' mail.
6. An age key pair for the backups (`age-keygen -o den-backup.key`); keep
   `den-backup.key` offline, in two places. See
   [The encryption key](databases-and-backups.md#the-encryption-key).

## Step 2: Get the files

Check out the root repository at the release you run and copy
`deploy/docker` to the server's deployment folder, for example
`/srv/conservices`:

```sh
git clone --depth 1 --branch v1.0.0 https://github.com/AGlElectronics/con-services.git
git clone --depth 1 https://github.com/AGlElectronics/con-services-gitops.git
sudo install -d -o "$USER" -m 750 /srv/conservices
cp -r con-services/deploy/docker/. /srv/conservices/
cd /srv/conservices
```

You should see the files from the table above:

```sh
ls -A
```

```text
.env.example  .gitignore  Caddyfile  compose.production.yml  postgres  web-config
```

Keep `/srv/conservices` in your own private Git repository if you like;
`.gitignore` keeps `.env` and the generated folders out of it.

## Step 3: Write `.env`

`.env` holds every setting and secret. It is read by Compose, so it must sit
next to the compose file, be readable only by you, and never be committed.

1. Create it from the example with the right permissions:

    ```sh
    install -m 600 /dev/null .env && cat .env.example > .env
    ```

2. Fill it from your secret manager. Generate random values with
   `openssl rand -hex 32` (passwords and tokens) and
   `openssl rand -base64 32` (every `*_DEN_LINK_ENCRYPTION_KEY`, one per
   module), store them in the secret manager first, then write `.env` from
   there. With SOPS, for example, keep `env.sops` encrypted in your
   deployment repository and decrypt on the server:

    ```sh
    sops --decrypt --input-type dotenv --output-type dotenv env.sops > .env
    ```

    Other options (OpenBao/Vault, 1Password, Bitwarden) are on
    [Secrets on Docker](secrets.md#secrets-on-docker).

3. Set `DOMAIN`, `ACME_EMAIL`, `ADMIN_ALLOWED_CIDRS` and the S3, SMTP and
   backup values. Leave `BACKUP_SAME_STORAGE_AS_DATA=false` unless the
   backup bucket is on the same S3 service as the live data (then set it to
   `true`, and Den warns about it; see
   [Where backups go](databases-and-backups.md#where-backups-go)).
4. For every module you run, add its name to `COMPOSE_PROFILES` (for
   example `COMPOSE_PROFILES=hr,stash,wiki`), uncomment its block and fill
   it in. List in `FILES_S3_BUCKETS` the Den bucket and the bucket of every
   module that has one, so they are backed up.

The full list of secrets, what they protect and how to rotate them is the
[inventory](secrets.md#inventory). Never put a real value into
`.env.example` or any file you commit.

## Step 4: Generate the realm and the per-installation files

### The realm

The realm files come from the development realm, cleaned for production
by `keycloak-realm.py` of the GitOps repository: no test people, no
`localhost` addresses, no password grant on the web apps, TLS required,
self-registration off for staff, brute-force protection, a password policy
(at least 12 characters, not the username, not the e-mail address), no
realm roles, and `den-keycloak` limited to `manage-realm`. Client secrets
and the SMTP login stay `${PLACEHOLDERS}` that Keycloak fills from its
environment (the values from `.env`).

```sh
pip install pyyaml
python3 ~/con-services-gitops/bootstrap/scripts/keycloak-realm.py \
  --source ~/con-services/infra/keycloak \
  --format json --domain con.example.org --smtp --out keycloak/realm
```

You should see:

```text
wrote keycloak/realm/realm-conservices.json (12 clients, users kept: ['service-account-hr-provisioner', 'service-account-den-keycloak', 'service-account-learn-provisioner'], placeholders: ['DEN_KEYCLOAK_CLIENT_SECRET', 'HR_PROVISIONER_CLIENT_SECRET', 'LEARN_PROVISIONER_CLIENT_SECRET', 'SMTP_FROM', 'SMTP_HOST', 'SMTP_PASSWORD', 'SMTP_PORT', 'SMTP_USERNAME'])
wrote keycloak/realm/realm-attendees.json (1 clients, users kept: none, placeholders: ['SMTP_FROM', 'SMTP_HOST', 'SMTP_PASSWORD', 'SMTP_PORT', 'SMTP_USERNAME'])
```

Options: `--min-password-length 14`, `--failure-factor 5` (failed
sign-ins before a temporary lockout), `--no-den-sync` (Den gets no rights
in the realm; then also set `DEN_KEYCLOAK_ADMIN_URL=` empty in `.env`).
Keycloak imports a realm only when it does not exist yet; later changes
are made in the admin console ([Changing a running realm](../deploy/identity.md#changing-a-running-realm)).

Copy the login theme (it fetches Den's brand in the browser):

```sh
mkdir -p keycloak/themes
cp -r ~/con-services/infra/keycloak/themes/conservices keycloak/themes/
```

### Web app settings

Point the web apps at your sign-in address:

```sh
sed -i 's/con\.example\.org/con.yourdomain.org/g' web-config/*.json
```

### nginx and security headers

Each web app's nginx file comes from its repository at the release you run
(`infra/nginx.stack.conf`, which finds its backend by service name). The
security headers (Content Security Policy, frame protection, `nosniff`,
`Referrer-Policy`, `Permissions-Policy`) come from the shared snippet with
your addresses filled in; Stash's copy allows the camera for barcode
scanning:

```sh
mkdir -p nginx
for app in den hr Rally stash finance learn wiki desk tasks; do
  curl -fsSL "https://raw.githubusercontent.com/AGlElectronics/$app/v1.0.0/infra/nginx.stack.conf" \
    -o "nginx/$(echo "$app" | tr 'A-Z' 'a-z').conf"
done
sed -e 's#KEYCLOAK_ORIGIN#https://auth.con.yourdomain.org#g' \
    -e 's#DEN_ORIGIN#https://den.con.yourdomain.org#g' \
    ~/con-services/shared/nginx/security-headers.conf > nginx/security-headers.conf
sed -e 's#camera=()#camera=(self)#' nginx/security-headers.conf > nginx/security-headers-stash.conf
```

Replace `v1.0.0` with each module's release tag. If a module's
`nginx.stack.conf` does not contain
`include /etc/nginx/snippets/security-headers.conf;` yet, add that line in
its `server` block and in every `location` that has its own `add_header`
(see [Nginx security headers](../concepts/shared-code.md#nginx-security-headers)).

### Access configurations

Stash, Rally, Learn, Wiki, Desk and Tasks read an access configuration
(which Keycloak group gets which role). Start from the template's files:

```sh
mkdir -p access-config
cp ~/con-services-gitops/charts/module-extras/files/access-config/*.toml access-config/
```

## Step 5: Check and start

1. Check the whole configuration. This catches a missing required value in
   `.env` and typos in the compose file:

    ```sh
    docker compose -f compose.production.yml config --quiet && echo OK
    ```

    ```text
    OK
    ```

    An error such as `required variable OPERATOR_TOKEN is missing a value`
    names the value to add to `.env`.

2. Pull and start:

    ```sh
    docker compose -f compose.production.yml pull
    docker compose -f compose.production.yml up -d
    docker compose -f compose.production.yml ps
    ```

    After two to three minutes every long-running service shows `Up` and
    `(healthy)` (module backends show only `Up`; they have no healthcheck
    yet), and `postgres-init`, `den-migrate` and the modules' `*-migrate`
    show `Exited (0)`.

3. Check the sign-in server and the headers:

    ```sh
    curl -s https://auth.con.yourdomain.org/realms/conservices/.well-known/openid-configuration | jq -r .issuer
    curl -sI https://den.con.yourdomain.org/ | grep -i -E 'strict-transport|content-security|x-frame'
    ```

    ```text
    https://auth.con.yourdomain.org/realms/conservices
    strict-transport-security: max-age=31536000; includeSubDomains
    content-security-policy: default-src 'self'; script-src 'self'; …
    x-frame-options: DENY
    ```

4. **First admin login.** Open `https://auth-admin.con.yourdomain.org` from
   an address in `ADMIN_ALLOWED_CIDRS`, sign in as `temp-admin` with
   `KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD`, create your own admin in the
   `master` realm, then delete `temp-admin`
   ([First admin login](../deploy/identity.md#first-admin-login)). Create
   the first staff account in the `conservices` realm and put it in the
   group `den-admin`.
5. **Den:** sign in at `https://den.con.yourdomain.org`, then
   **Backups → Back up now**; it must succeed.
6. **Modules:** each module waits for Den. In Den, **Modules → Pair**
   creates a pairing URL; paste it into the module's *Den connection*
   page ([Pairing](../concepts/pairing.md)).

## Step 6: Upgrade, back up, restore

- **Upgrade:** read the release notes of every app you raise
  ([Versions and upgrades](versioning.md)), change its `*_VERSION` in
  `.env` (all images of one app share the tag), refresh its
  `nginx/<app>.conf` from the new release, then:

    ```sh
    docker compose -f compose.production.yml config --quiet
    docker compose -f compose.production.yml pull
    docker compose -f compose.production.yml up -d
    ```

    The `*-migrate` services run before the new backends start.

- **Backups:** Den's operator backs up every database (Den, Keycloak and
  the modules) and the buckets in `FILES_S3_BUCKETS`, encrypted to your age
  key, once a day, exactly as on Kubernetes; see
  [Databases, backups and restore](databases-and-backups.md). The server
  itself holds only `postgres-data` and the files in `/srv/conservices`;
  keep a copy of `.env` in your secret manager and the folder in your
  deployment repository, and a lost server is rebuilt from them plus the
  last backup.
- **Restore:** follow [Restore](databases-and-backups.md#restore), with
  `docker compose -f compose.production.yml exec den-operator sh` instead
  of `kubectl exec`, and `docker compose -f compose.production.yml stop
  <service>` to stop what uses the data.
- **Secrets changed:** update the secret manager, rewrite `.env`, then
  `docker compose -f compose.production.yml up -d` (only services whose
  values changed are recreated). Client secrets are also stored in
  Keycloak: regenerate them there first
  ([Secrets](secrets.md#inventory)).
- **A new module later:** add its profile and block to `.env`, its bucket
  to `FILES_S3_BUCKETS`, then `up -d`; `postgres-init` creates its database.

## Checklist

- [ ] Only ports 80 and 443 (and SSH from your admin network) are open;
  `docker compose -f compose.production.yml config --format json | jq '[.services[] | select(.ports)] | length'`
  prints `1` (the proxy).
- [ ] Pinned image tags; no `build:`; no `latest`.
- [ ] `.env` mode 600, written from a secret manager, not in Git.
- [ ] Keycloak realm generated by `keycloak-realm.py`: no test people,
  brute-force protection and password policy on; `temp-admin` deleted.
- [ ] `curl -sI` shows `strict-transport-security` and
  `content-security-policy` on every web app.
- [ ] Managed S3, one key per bucket; backups at another provider or
  account; own age key, secret half offline; one test restore done.
- [ ] Everything on [Production and security](production.md#checklist) that
  applies outside Kubernetes.

## Troubleshooting

Start with the state of every service and the last log lines of the one
that fails:

```sh
docker compose -f compose.production.yml ps -a
docker compose -f compose.production.yml logs --tail 50 den-backend
```

**`required variable … is missing a value: set … in .env`**
: A required setting is empty. Add it to `.env` (from your secret manager)
  and run the command again.

**A module backend keeps restarting with `DEN_LINK_ENCRYPTION_KEY is required` or `password authentication failed`**
: Its block in `.env` is incomplete: module values are not checked by
  `config` (a module that is not running needs none). Fill in every line of
  the block and run `up -d` again. `password authentication failed` after
  you changed `<MODULE>_DB_PASSWORD`: `postgres-init` never changes an
  existing password; set it in PostgreSQL too:

    ```sh
    docker compose -f compose.production.yml exec postgres \
      psql -U postgres -c "ALTER ROLE hr PASSWORD 'the-new-value'"
    ```

**`service "postgres-init" didn't complete successfully`**
: Read `docker compose -f compose.production.yml logs postgres-init`.
  `password authentication failed for user "postgres"`: `POSTGRES_PASSWORD`
  in `.env` differs from the one the database was created with (it is only
  used when `postgres-data` is new).

**Keycloak stays `(health: starting)` and logs `Failed to import realm`**
: The realm files are missing or were not generated for this domain. Check
  `ls keycloak/realm` shows both JSON files and that they contain your
  domain, then `docker compose -f compose.production.yml up -d keycloak`.

**Caddy logs `obtaining certificate: … timeout during connect`**
: Let's Encrypt cannot reach port 80 on the server. Check that every DNS
  name points at the server and that the firewall allows 80 and 443 from
  anywhere.

**`https://auth-admin.…` answers `403` from your admin network**
: Caddy does not see your address in `ADMIN_ALLOWED_CIDRS`. Its access log
  shows the address it saw: `docker compose -f compose.production.yml logs proxy | grep auth-admin`.
  Behind NAT that is your public address; add it, then
  `docker compose -f compose.production.yml up -d proxy`.

**The web app returns `502 Bad Gateway`**
: Its frontend is not running (its profile is missing from
  `COMPOSE_PROFILES`) or still starting. Check `ps`. Caddy logs
  `dial tcp …:80: connect: connection refused` when an old nginx file
  listens on 80: the images listen on **8080**.

**Sign-in fails with *Invalid parameter: redirect_uri* or an issuer mismatch**
: The realm was generated for another domain, or `web-config/*.json` still
  names `con.example.org`. Fix the file and reload the page; for the realm,
  change the client's redirect URIs in the admin console (it is imported
  only once).

**A web app shows a blank page and the browser console says `Refused to connect … Content Security Policy`**
: The security headers snippet still contains `KEYCLOAK_ORIGIN` or names
  another domain. Generate `nginx/security-headers*.conf` again (step 4)
  and restart the web apps.

**`den-backend` logs `oidc discovery … no such host` or a certificate error for `auth.`**
: Containers reach `auth.<DOMAIN>` through the proxy (a network alias), so
  the proxy must be healthy and have its certificate. Check
  `docker compose -f compose.production.yml ps proxy` and the Caddy log.

## Related pages

- [Secrets: Secrets on Docker](secrets.md#secrets-on-docker)
- [Production and security](production.md)
- [Databases, backups and restore](databases-and-backups.md)
- [Identity: Keycloak](../deploy/identity.md)
- [Versions and upgrades](versioning.md)
