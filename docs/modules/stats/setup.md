# Set up Stats

Stats 1.1 is a development scaffold. It runs locally without Den, Keycloak or
a database; `AUTH_MODE=dev` is the only accepted mode.

## Run the dashboard shell

1. From the root Con Services workspace, build and start the `stats` profile:

   ```sh
   docker compose --profile stats up --build stats-frontend
   ```

2. Open <http://localhost:3011> (or <https://stats.conservices.test> when
   the local proxy is up). The local Compose default polls every module’s
   `GET /api/internal/stats` (shared `STATS_SERVICE_TOKEN` /
   `STATS_PULL_TOKEN`). Override with `STATS_SOURCES` in `.env` if needed.

   Local Den registers Stats via `DEN_PREREGISTER_MODULES`. For the
   scaffold to appear on the portal today it is listed as **paired** with
   portal visibility **everyone** (no role catalog / denlink yet).

3. Check the backend directly:

   ```sh
   curl http://localhost:8170/readyz
   ```

   ```json
   {"status":"ok","version":"dev"}
   ```

## Add an aggregate source

1. Make a module expose the
   [version 1 internal pull contract](api.md#internal-module-pull-contract).

2. Add its internal address and a development token to the root `.env`:

   ```dotenv
   STATS_SOURCES=desk=http://desk-backend:8080/api/internal/stats
   STATS_SERVICE_TOKEN=change-me-dev-only
   STATS_POLL_INTERVAL=2m
   ```

3. Recreate the backend:

   ```sh
   docker compose --profile stats up -d --build --force-recreate stats-backend stats-frontend
   ```

4. Refresh <http://localhost:3011>. After the first pull, the module card
   should say `ok` and list its aggregate values.

The shared token is a temporary scaffold convention. Production work must use
secret-manager-backed credentials and define token rotation before enabling
Stats outside local development.

## Troubleshooting

**The dashboard says `No metric sources configured`**
: `STATS_SOURCES` is empty or the backend was not recreated after `.env`
  changed. Set it and repeat step 3.

**A source says `error` or `stale`**
: Check that the URL is reachable from the Stats container, returns HTTP 200,
  names the same module as the left side of `module=url`, and accepts the
  configured bearer token.

**The backend exits immediately**
: `STATS_POLL_INTERVAL` must be from `1m` through `5m`,
  `STATS_PULL_TIMEOUT` must be at most `30s`, and this scaffold accepts only
  `AUTH_MODE=dev`.

**Port 3011 or 8170 is already in use**
: Stop the process using the port or change the host-side port in the root
  `docker-compose.yml`. Do not change container port 8080.
