#!/bin/bash
# Patch an already-imported conservices realm (import-realm skips existing realms).
# Run: docker exec conservices-keycloak bash /opt/keycloak/data/import/apply-mvp.sh
set -euo pipefail
KC=/opt/keycloak/bin/kcadm.sh
$KC config credentials --server http://localhost:8080 --realm master --user admin --password admin >/dev/null

$KC update realms/conservices -s registrationAllowed=true

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

# Declare the attributes HR mirrors (undeclared attributes are dropped).
$KC update users/profile -r conservices -f /opt/keycloak/data/profile/user-profile.json

echo "conservices MVP patch applied"
