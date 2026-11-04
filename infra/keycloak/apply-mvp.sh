#!/bin/bash
# Patch an already-imported conservices realm (import-realm skips existing realms).
# Run: docker exec conservices-keycloak bash /opt/keycloak/data/import/apply-mvp.sh
set -euo pipefail
KC=/opt/keycloak/bin/kcadm.sh
$KC config credentials --server http://localhost:8080 --realm master --user admin --password admin >/dev/null

$KC update realms/conservices -s registrationAllowed=true

# Keycloak's own admin console login (master realm): Con Services look too.
# Den only pushes the organisation brand into conservices, so this one stays neutral.
$KC update realms/master -s loginTheme=conservices \
  -s displayName="Con Services admin" -s displayNameHtml="Con Services admin"

# Onboarding emails (set-password link). Dev: Mailpit; prod: override SMTP.
$KC update realms/conservices \
  -s emailTheme=conservices \
  -s 'smtpServer.host=mailpit' -s 'smtpServer.port=1025' \
  -s 'smtpServer.from=no-reply@conservices.local' -s 'smtpServer.fromDisplayName=Con Services' \
  -s 'smtpServer.auth=false' -s 'smtpServer.ssl=false' -s 'smtpServer.starttls=false'

HR_SPA=$($KC get clients -r conservices -q clientId=hr-spa --fields id --format csv --noquotes | tail -n1)
if [ -n "$HR_SPA" ]; then
  $KC update "clients/$HR_SPA" -r conservices -s directAccessGrantsEnabled=true
fi

PROV=$($KC get clients -r conservices -q clientId=hr-provisioner --fields id --format csv --noquotes | tail -n1 || true)
if [ -z "$PROV" ]; then
  $KC create clients -r conservices \
    -s clientId=hr-provisioner \
    -s name="HR Keycloak provisioner" \
    -s enabled=true \
    -s publicClient=false \
    -s clientAuthenticatorType=client-secret \
    -s secret=hr-provisioner-dev-secret \
    -s serviceAccountsEnabled=true \
    -s standardFlowEnabled=false \
    -s directAccessGrantsEnabled=false
fi

$KC add-roles -r conservices --uusername service-account-hr-provisioner --cclientid realm-management \
  --rolename manage-users --rolename view-users --rolename query-users \
  --rolename view-realm --rolename query-groups

# Den pushes login branding (theme, display name, brand attribute) into the realm.
DEN_KC=$($KC get clients -r conservices -q clientId=den-keycloak --fields id --format csv --noquotes | tail -n1 || true)
if [ -z "$DEN_KC" ]; then
  $KC create clients -r conservices \
    -s clientId=den-keycloak \
    -s name="Den realm branding" \
    -s enabled=true \
    -s publicClient=false \
    -s clientAuthenticatorType=client-secret \
    -s secret=den-keycloak-dev-secret \
    -s serviceAccountsEnabled=true \
    -s standardFlowEnabled=false \
    -s directAccessGrantsEnabled=false
fi
$KC add-roles -r conservices --uusername service-account-den-keycloak --cclientid realm-management \
  --rolename manage-realm --rolename view-realm

# SPA clients: local DNS (https://<app>.conservices.test) plus the localhost ports.
spa_urls() {
  local client=$1 port=$2 host=$3 id
  id=$($KC get clients -r conservices -q clientId="$client" --fields id --format csv --noquotes | tail -n1 || true)
  [ -n "$id" ] || return 0
  $KC update "clients/$id" -r conservices \
    -s "rootUrl=https://$host" -s "baseUrl=https://$host" \
    -s "redirectUris=[\"https://$host/*\",\"http://localhost:$port/*\",\"http://127.0.0.1:$port/*\"]" \
    -s "webOrigins=[\"https://$host\",\"http://localhost:$port\",\"http://127.0.0.1:$port\"]" \
    -s "attributes.\"post.logout.redirect.uris\"=https://$host/*##http://localhost:$port/*"
}
spa_urls stash-spa 3000 stash.conservices.test
spa_urls den-spa 3001 den.conservices.test
spa_urls events-spa 3002 events.conservices.test
spa_urls hr-spa 3003 hr.conservices.test

# Declare the attributes HR mirrors (undeclared attributes are dropped).
$KC update users/profile -r conservices -f /opt/keycloak/data/profile/user-profile.json

echo "conservices MVP patch applied"
