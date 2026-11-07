#!/bin/sh
# Runs once, when the PostgreSQL data volume is first initialised.
# Creates only the platform databases (den, keycloak). Module databases are
# created later by Den (Admin console -> Modules -> New module -> "Create a
# database for it"), through the Den operator.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" \
  -v den_pw="$DEN_DB_PASSWORD" -v kc_pw="$KEYCLOAK_DB_PASSWORD" <<'EOSQL'
CREATE ROLE den LOGIN PASSWORD :'den_pw';
CREATE DATABASE den OWNER den;
REVOKE CONNECT, TEMPORARY ON DATABASE den FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE den TO den;

CREATE ROLE keycloak LOGIN PASSWORD :'kc_pw';
CREATE DATABASE keycloak OWNER keycloak;
REVOKE CONNECT, TEMPORARY ON DATABASE keycloak FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE keycloak TO keycloak;
EOSQL
