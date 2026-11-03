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
END
\$\$;
EOSQL

for db in stash den events hr keycloak; do
  owner="postgres"
  case "$db" in
    stash) owner=stash ;;
    den) owner=den ;;
    events) owner=events ;;
    hr) owner=hr ;;
  esac
  exists="$(psql -U "$POSTGRES_USER" -tAc "SELECT 1 FROM pg_database WHERE datname='${db}'")"
  if [ "$exists" != "1" ]; then
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -c "CREATE DATABASE ${db} OWNER ${owner};"
  fi
done

echo "Databases ready: stash den events hr keycloak"
