#!/bin/bash
set -euo pipefail
# Shared local Postgres — one DB per module (+ keycloak). DEV / Docker Desktop only.

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'stash') THEN
    CREATE ROLE stash LOGIN PASSWORD 'stash';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'den') THEN
    CREATE ROLE den LOGIN PASSWORD 'den';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'events') THEN
    CREATE ROLE events LOGIN PASSWORD 'events';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hr') THEN
    CREATE ROLE hr LOGIN PASSWORD 'hr';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'learn') THEN
    CREATE ROLE learn LOGIN PASSWORD 'learn';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'finance') THEN
    CREATE ROLE finance LOGIN PASSWORD 'finance';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'desk') THEN
    CREATE ROLE desk LOGIN PASSWORD 'desk';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'tasks') THEN
    CREATE ROLE tasks LOGIN PASSWORD 'tasks';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'wiki') THEN
    CREATE ROLE wiki LOGIN PASSWORD 'wiki';
  END IF;
END
\$\$;
EOSQL

for db in stash den events hr learn finance desk tasks wiki keycloak; do
  owner="postgres"
  case "$db" in
    stash) owner=stash ;;
    den) owner=den ;;
    events) owner=events ;;
    hr) owner=hr ;;
    learn) owner=learn ;;
    finance) owner=finance ;;
    desk) owner=desk ;;
    tasks) owner=tasks ;;
    wiki) owner=wiki ;;
  esac
  exists="$(psql -U "$POSTGRES_USER" -tAc "SELECT 1 FROM pg_database WHERE datname='${db}'")"
  if [ "$exists" != "1" ]; then
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -c "CREATE DATABASE ${db} OWNER ${owner};"
  fi
  # Postgres grants CONNECT to PUBLIC by default; each module may only reach its own database.
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" \
    -c "REVOKE CONNECT, TEMPORARY ON DATABASE ${db} FROM PUBLIC;" \
    -c "GRANT CONNECT, TEMPORARY ON DATABASE ${db} TO ${owner};"
done

echo "Databases ready: stash den events hr learn finance desk tasks wiki keycloak"
