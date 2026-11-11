# Full stack on Docker (production)

**Goal:** run Den and its platform on one Linux server with Docker Compose,
safely enough for a small convention, using the same pinned images as on
Kubernetes.

Kubernetes is the recommended way to run Con Services. Some organisations
have one server and no Kubernetes; for them, the suite can run on a single
**Docker** host with Docker Compose, using the same published images. This
page shows how to do that safely. It is **not** the development stack: that
one (described in [Local development](../contributing/local-development.md))
builds from source and uses public passwords.

!!! warning "Know what you give up"
    A single Docker host has no network policies between namespaces, no Pod
    Security, no automatic rescheduling and no rolling upgrades. One host
    failing takes everything down. It suits a small convention with one
    server and good backups. Anything bigger belongs on
    [Kubernetes](running.md).

## How it differs from the development stack

| Development stack (`docker-compose.yml`) | Production on Docker |
| --- | --- |
| Builds every image from local source (`build:`). | Pulls published images with pinned tags (`image: ghcr.io/aglelectronics/den-backend:1.0.0-1`). |
| Passwords written in the compose file. | Secrets in root-only env files outside Git, filled from a secret manager (see [Secrets on Docker](secrets.md#secrets-on-docker)). |
| Keycloak in `start-dev` mode, a local S3 server (SeaweedFS, service `s3`), Mailpit, Adminer, GreenMail. | Keycloak in production mode (`start`); managed S3 and SMTP; **no** Adminer, Mailpit, GreenMail or local S3 server. |
| Caddy with its own local certificate authority. | Caddy (or another reverse proxy) with real certificates from Let's Encrypt. |
| Many published ports (`8090`, `5432`, `9000`, …). | Only the proxy publishes ports 80 and 443. |
| `APP_ENV=development`. | `APP_ENV=production`, `AUTH_MODE=oidc`. |

## Step 1: Prepare the host

1. A Linux server with Docker Engine and the Compose plugin, a firewall that
   allows only 22 (from your admin network), 80 and 443.
2. DNS names for every app pointing at the server, for example
   `auth.con.example.org`, `den.con.example.org`, `stash.con.example.org`.
3. Managed PostgreSQL 16 (or PostgreSQL on another host you back up) and
   managed S3 storage; any S3-compatible service works (AWS S3, Hetzner
   Object Storage, Cloudflare R2, Backblaze B2, ...; see
   [Production](production.md#object-storage-use-managed-s3)).
4. A folder for secrets, owned by root:

    ```sh
    sudo install -d -m 700 /etc/conservices
    ```

## Step 2: Write the env files

One file per service, readable only by root, filled from your secret
manager as shown in [Secrets on Docker](secrets.md#secrets-on-docker).
Non-secret settings can sit in the compose file; secrets go only in these
files. The variables are the same as on Kubernetes:
[Den configuration](../modules/den/configuration.md).

```text
# /etc/conservices/den-backend.env   (mode 600; values from the secret manager)
DATABASE_URL=postgres://den:change-me@db.example.org:5432/den?sslmode=require
S3_ACCESS_KEY_ID=change-me
S3_SECRET_ACCESS_KEY=change-me
KEYCLOAK_CLIENT_SECRET=change-me
OPERATOR_TOKEN=change-me
```

```text
# /etc/conservices/den-operator.env
OPERATOR_TOKEN=change-me
PG_ADMIN_URL=postgres://postgres:change-me@db.example.org:5432/postgres?sslmode=require
BACKUP_S3_ACCESS_KEY_ID=change-me
BACKUP_S3_SECRET_ACCESS_KEY=change-me
FILES_S3_ACCESS_KEY_ID=change-me
FILES_S3_SECRET_ACCESS_KEY=change-me
```

## Step 3: The compose file

A hardened starting point for the platform and Den. Keep it in your own Git
repository (it holds no secrets). Add modules the same way as Den.

```yaml
# compose.production.yml
name: conservices

x-hardening: &hardening
  restart: unless-stopped
  read_only: true
  security_opt: ["no-new-privileges:true"]
  cap_drop: ["ALL"]
  tmpfs: ["/tmp"]
  networks: [internal]

services:
  proxy:
    image: caddy:2.8
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
    networks: [internal, public]

  keycloak:
    image: quay.io/keycloak/keycloak:26.0.7
    restart: unless-stopped
    command: ["start", "--import-realm"]
    networks: [internal, egress]
    env_file: /etc/conservices/keycloak.env   # KC_DB_PASSWORD, KC_BOOTSTRAP_ADMIN_*
    environment:
      KC_HOSTNAME: https://auth.con.example.org
      KC_PROXY_HEADERS: xforwarded
      KC_HTTP_ENABLED: "true"
      KC_HEALTH_ENABLED: "true"
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://db.example.org:5432/keycloak?sslmode=require
      KC_DB_USERNAME: keycloak
    volumes:
      - ./realm:/opt/keycloak/data/import:ro
      - ./themes/conservices:/opt/keycloak/themes/conservices:ro

  den-migrate:
    image: ghcr.io/aglelectronics/den-backend:1.0.0-1
    <<: *hardening
    restart: "no"
    entrypoint: ["/den-migrate"]
    networks: [internal, egress]
    env_file: /etc/conservices/den-backend.env
    environment:
      APP_ENV: production

  den-backend:
    image: ghcr.io/aglelectronics/den-backend:1.0.0-1
    <<: *hardening
    depends_on:
      den-migrate: { condition: service_completed_successfully }
    networks: [internal, egress]
    env_file: /etc/conservices/den-backend.env
    environment:
      APP_ENV: production
      APP_BASE_URL: https://den.con.example.org
      HTTP_ADDR: ":8080"
      AUTH_MODE: oidc
      OIDC_ISSUER_URL: https://auth.con.example.org/realms/conservices
      OIDC_CLIENT_ID: den-spa
      CORS_ALLOWED_ORIGINS: https://den.con.example.org
      S3_ENDPOINT: https://fsn1.your-objectstorage.com
      S3_BUCKET: example-den
      S3_REGION: fsn1
      KEYCLOAK_ADMIN_URL: http://keycloak:8080
      KEYCLOAK_REALM: conservices
      OPERATOR_URL: http://den-operator:8080

  den-operator:
    image: ghcr.io/aglelectronics/den-operator:1.0.0-1
    <<: *hardening
    networks: [internal, egress]
    env_file: /etc/conservices/den-operator.env
    environment:
      MODULE_DB_HOST: db.example.org:5432
      BACKUP_S3_ENDPOINT: https://s3.eu-central-1.amazonaws.com
      BACKUP_S3_BUCKET: example-conservices-backups
      BACKUP_S3_REGION: eu-central-1
      BACKUP_AGE_RECIPIENTS: age1change-me
      BACKUP_TIMEZONE: Europe/Vienna
      FILES_S3_ENDPOINT: https://fsn1.your-objectstorage.com
      FILES_S3_REGION: fsn1
      FILES_S3_BUCKETS: example-den,example-stash

  den-frontend:
    image: ghcr.io/aglelectronics/den-frontend:1.0.0-1
    # nginx runs as UID 101 on port 8080 and writes only to /tmp.
    <<: *hardening
    networks: [internal]
    volumes:
      # Den's infra/nginx.stack.conf: forwards /api/ to den-backend:8080.
      - ./den-frontend/nginx.conf:/etc/nginx/conf.d/default.conf:ro
      # The web app's sign-in settings, served as /config.json.
      - ./den-frontend/config.json:/etc/conservices/config.json:ro

networks:
  internal: { internal: true }   # no route out, no published ports
  public: {}                    # the proxy's ports
  egress: {}                    # outbound only: database, S3, SMTP

volumes:
  caddy-data: {}
```

What the hardening does:

- **Only the proxy is reachable from outside.** It is the only service
  with published ports. Everything talks on the `internal` network, which
  has no route out. Services that must reach the managed database, S3 or
  SMTP (`keycloak`, `den-migrate`, `den-backend`, `den-operator`) also join
  `egress`, which has no published ports. Restrict that traffic further
  with the host firewall or an egress proxy if you can.
- `read_only`, `cap_drop: ALL` and `no-new-privileges` mirror Kubernetes'
  `restricted` Pod Security. The operator needs its `/tmp` (a `tmpfs` here)
  to be large enough for database dumps; give it a volume instead if your
  databases are big.
- **Migrations run in `den-migrate`** before the Den backend starts. The
  backend keeps no state of its own (backup download links are in the
  database), so you may run more than one container behind a load balancer.
- **The published frontend image works for any domain.** Two files next to
  the compose file make it yours:

    ```sh
    # infra/nginx.stack.conf from a checkout of github.com/AGlElectronics/den
    # at the release you run (it names no domain)
    mkdir den-frontend
    cp ~/src/den/infra/nginx.stack.conf den-frontend/nginx.conf
    ```

    ```json
    {
      "authMode": "oidc",
      "oidcAuthority": "https://auth.con.example.org/realms/conservices",
      "oidcClientId": "den-spa"
    }
    ```

    Save the second one as `den-frontend/config.json`. The keys are listed
    under [Web app settings](../modules/den/configuration.md#web-app-settings-configjson).
    A change shows on the next page load; no restart needed.

!!! note "Verify before relying on it"
    This compose file is a reference, not a tested release artifact. Run
    `docker compose -f compose.production.yml config` to check it, and
    test a full start, sign-in and backup on a staging server first. Some
    images (for example Keycloak) need writable paths; add `tmpfs` entries
    or drop `read_only` for that service if it fails to start.

## Step 4: The proxy

Caddy gets real certificates from Let's Encrypt automatically when the DNS
names point at the server:

```text
# Caddyfile
auth.con.example.org {
	reverse_proxy keycloak:8080
}

den.con.example.org {
	reverse_proxy den-frontend:8080
}
```

The web app images listen on port **8080** inside the container (nginx
runs as a normal user, which cannot use ports below 1024). Older images
built on `nginx:1.27-alpine` listened on port 80; if you upgrade from one
of them, change `reverse_proxy den-frontend:80` to
`reverse_proxy den-frontend:8080`.

Add rate limiting at this proxy or in front of the server; Den has none
built in.

## Step 5: Start, upgrade, back up

```sh
docker compose -f compose.production.yml pull
docker compose -f compose.production.yml up -d
docker compose -f compose.production.yml ps
```

- **Upgrade:** read the module's changelog, change the image tags, then
  `pull` and `up -d` again. `den-migrate` runs before the new backend starts.
  See [Versions and upgrades](versioning.md).
- **Backups:** Den's operator backs up the database server and the listed
  buckets, exactly as on Kubernetes. Follow
  [Databases, backups and restore](databases-and-backups.md); for restores,
  use `docker compose exec den-operator sh` instead of `kubectl exec`.
- **Secrets changed:** rewrite the env file, then
  `docker compose -f compose.production.yml up -d <service>`.

## Checklist

- [ ] Only ports 80 and 443 (and SSH from your admin network) are open.
- [ ] Pinned image tags; no `build:`; no `latest`.
- [ ] Secrets only in root-only env files outside Git, written from a secret
  manager.
- [ ] Keycloak in production mode; no test accounts; real SMTP.
- [ ] Managed PostgreSQL and S3 (AWS S3 or Hetzner Object Storage); no local S3
  server (SeaweedFS), Adminer, Mailpit or GreenMail.
- [ ] Backups to a different provider or account, own age key, one test
  restore done.
- [ ] Everything on [Production and security](production.md#checklist) that
  applies outside Kubernetes.

## Troubleshooting

Start with the state of every service and the last log lines of the one
that fails:

```sh
docker compose -f compose.production.yml ps -a
docker compose -f compose.production.yml logs --tail 50 den-backend
```

**`den-backend` never starts: `service "den-migrate" didn't complete successfully: exit 1`**
: Read `docker compose -f compose.production.yml logs den-migrate`. Usually
  a wrong `DATABASE_URL` or the database is not reachable from the `egress`
  network (host firewall, provider allow-list).

**A service exits with `read-only file system`**
: That image needs a writable path. Add a `tmpfs` entry for the path named
  in the error, or drop `read_only` for that one service.

**`env file /etc/conservices/den-backend.env not found`**
: The file does not exist or you ran Compose as a user who cannot read it.
  Run the command with `sudo`, or as the user that owns the deployment.

**The web app returns `502 Bad Gateway` after an upgrade, and Caddy logs `dial tcp …:80: connect: connection refused`**
: The web app image now listens on port 8080. Change the `reverse_proxy`
  line for that web app to port 8080 (see [Step 4](#step-4-the-proxy)) and
  reload Caddy:

    ```sh
    docker compose -f compose.production.yml exec proxy caddy reload --config /etc/caddy/Caddyfile
    ```

**Caddy logs `obtaining certificate: … timeout during connect`**
: Let's Encrypt cannot reach port 80 on the server. Check the DNS name
  points at the server and that the firewall allows 80 and 443 from
  anywhere.

**Sign-in fails with *Invalid parameter: redirect_uri* or an issuer mismatch**
: `KC_HOSTNAME`, `OIDC_ISSUER_URL` and `oidcAuthority` in
  `den-frontend/config.json` must use the same `https://auth.…` address. See
  [Troubleshooting](../getting-started/troubleshooting.md#sign-in-loops-back-to-the-sign-in-page).

**`den-backend` logs `oidc discovery … no such host` for the `auth.` name**
: Containers resolve names through Docker, which uses the host's resolver.
  The backend image has no shell, so test from the host instead; this must
  print a JSON document whose `issuer` equals `OIDC_ISSUER_URL`:

    ```sh
    curl https://auth.con.example.org/realms/conservices/.well-known/openid-configuration
    ```

    Also check `den-backend` is on the `egress` network: the `internal`
    network has no route out, not even to the server's own public address.

## Related pages

- [Secrets: Secrets on Docker](secrets.md#secrets-on-docker)
- [Versions and upgrades](versioning.md)
- [Databases, backups and restore](databases-and-backups.md)
- [Production and security](production.md)
