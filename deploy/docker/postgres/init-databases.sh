#!/bin/sh
# Run by the postgres-init service of compose.production.yml on every `up`.
# Creates the login and the database of Den, Keycloak and every module whose
# <MODULE>_DB_PASSWORD is set, if they do not exist yet. Never changes a
# password, never drops anything. Connection: PGHOST, PGUSER, PGPASSWORD.
set -eu

# role database password-variable
ensure() {
  role=$1 db=$2 pw=$3
  if [ -z "$pw" ]; then
    echo "skip $db (no password set)"
    return 0
  fi
  psql -v ON_ERROR_STOP=1 -q -d postgres -v role="$role" -v db="$db" -v pw="$pw" <<'EOSQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'role', :'pw')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'role') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'role')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db') \gexec
SELECT format('REVOKE CONNECT, TEMPORARY ON DATABASE %I FROM PUBLIC', :'db') \gexec
SELECT format('GRANT CONNECT, TEMPORARY ON DATABASE %I TO %I', :'db', :'role') \gexec
EOSQL
  echo "ok $db"
}

ensure den den "${DEN_DB_PASSWORD:-}"
ensure keycloak keycloak "${KEYCLOAK_DB_PASSWORD:-}"
ensure hr hr "${HR_DB_PASSWORD:-}"
ensure events events "${EVENTS_DB_PASSWORD:-}"
ensure stash stash "${STASH_DB_PASSWORD:-}"
ensure finance finance "${FINANCE_DB_PASSWORD:-}"
ensure learn learn "${LEARN_DB_PASSWORD:-}"
ensure wiki wiki "${WIKI_DB_PASSWORD:-}"
ensure desk desk "${DESK_DB_PASSWORD:-}"
ensure tasks tasks "${TASKS_DB_PASSWORD:-}"
