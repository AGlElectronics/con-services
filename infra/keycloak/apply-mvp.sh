#!/bin/bash
# Patch already-imported conservices and attendees realms (import-realm skips existing realms).
# Run: docker exec conservices-keycloak bash /opt/keycloak/data/import/apply-mvp.sh
set -euo pipefail
KC=/opt/keycloak/bin/kcadm.sh
$KC config credentials --server http://localhost:8080 --realm master --user admin --password admin >/dev/null

$KC update realms/conservices -s registrationAllowed=true
# HR renames the login when a nickname changes; the user profile keeps
# username edits admin-only, so people cannot change it themselves.
$KC update realms/conservices -s editUsernameAllowed=true

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

# Learn module (added after the first realm import): SPA client, groups, and
# dev group memberships. All idempotent.
LEARN_SPA=$($KC get clients -r conservices -q clientId=learn-spa --fields id --format csv --noquotes | tail -n1 || true)
if [ -z "$LEARN_SPA" ]; then
  $KC create clients -r conservices \
    -s clientId=learn-spa \
    -s name="Learn SPA" \
    -s enabled=true \
    -s publicClient=true \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=true \
    -s implicitFlowEnabled=false \
    -s 'attributes."pkce.code.challenge.method"=S256'
  LEARN_SPA=$($KC get clients -r conservices -q clientId=learn-spa --fields id --format csv --noquotes | tail -n1)
  $KC create "clients/$LEARN_SPA/protocol-mappers/models" -r conservices \
    -s name=groups \
    -s protocol=openid-connect \
    -s protocolMapper=oidc-group-membership-mapper \
    -s 'config."full.path"=true' \
    -s 'config."id.token.claim"=true' \
    -s 'config."access.token.claim"=true' \
    -s 'config."claim.name"=groups' \
    -s 'config."userinfo.token.claim"=true'
fi
spa_urls learn-spa 3005 learn.conservices.test

learn_group() {
  local name=$1
  if ! $KC get groups -r conservices -q search="$name" --fields name --format csv --noquotes | grep -qx "$name"; then
    $KC create groups -r conservices -s name="$name"
  fi
  $KC get groups -r conservices -q search="$name" --fields id,name --format csv --noquotes | grep ",$name$" | cut -d, -f1
}
LEARN_ADMIN_GID=$(learn_group learn-admin | tail -n1)
LEARN_TRAINER_GID=$(learn_group learn-trainer | tail -n1)
learn_group learn-coordinator >/dev/null
learn_group learn-manager >/dev/null
# Parent of the groups trainers may link (LEARN_LINKABLE_GROUPS=/learn/*),
# with one demo cohort.
LEARN_PARENT_GID=$(learn_group learn | tail -n1)
if ! $KC get "groups/$LEARN_PARENT_GID/children" -r conservices --fields name --format csv --noquotes | grep -qx demo-cohort; then
  $KC create "groups/$LEARN_PARENT_GID/children" -r conservices -s name=demo-cohort
fi

# Learn reads groups and members (quiz assignment by group). Read-only.
LEARN_PROV=$($KC get clients -r conservices -q clientId=learn-provisioner --fields id --format csv --noquotes | tail -n1 || true)
if [ -z "$LEARN_PROV" ]; then
  $KC create clients -r conservices \
    -s clientId=learn-provisioner \
    -s name="Learn group directory (read-only)" \
    -s enabled=true \
    -s publicClient=false \
    -s clientAuthenticatorType=client-secret \
    -s secret=learn-provisioner-dev-secret \
    -s serviceAccountsEnabled=true \
    -s standardFlowEnabled=false \
    -s directAccessGrantsEnabled=false
fi
$KC add-roles -r conservices --uusername service-account-learn-provisioner --cclientid realm-management \
  --rolename view-users --rolename query-groups

add_user_to_group() {
  local username=$1 gid=$2 uid
  uid=$($KC get users -r conservices -q username="$username" --fields id --format csv --noquotes | tail -n1 || true)
  [ -n "$uid" ] || return 0
  $KC update "users/$uid/groups/$gid" -r conservices -s realm=conservices -s userId="$uid" -s groupId="$gid" -n
}
# DEV users: admin runs Learn, alice trains, bob stays a plain learner.
add_user_to_group admin "$LEARN_ADMIN_GID"
add_user_to_group alice "$LEARN_TRAINER_GID"

# Finance module (added after the first realm import): SPA client, group, and
# dev group membership. All idempotent.
FINANCE_SPA=$($KC get clients -r conservices -q clientId=finance-spa --fields id --format csv --noquotes | tail -n1 || true)
if [ -z "$FINANCE_SPA" ]; then
  $KC create clients -r conservices \
    -s clientId=finance-spa \
    -s name="Finance SPA" \
    -s enabled=true \
    -s publicClient=true \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=true \
    -s implicitFlowEnabled=false \
    -s 'attributes."pkce.code.challenge.method"=S256'
  FINANCE_SPA=$($KC get clients -r conservices -q clientId=finance-spa --fields id --format csv --noquotes | tail -n1)
  $KC create "clients/$FINANCE_SPA/protocol-mappers/models" -r conservices \
    -s name=groups \
    -s protocol=openid-connect \
    -s protocolMapper=oidc-group-membership-mapper \
    -s 'config."full.path"=true' \
    -s 'config."id.token.claim"=true' \
    -s 'config."access.token.claim"=true' \
    -s 'config."claim.name"=groups' \
    -s 'config."userinfo.token.claim"=true'
fi
spa_urls finance-spa 3006 finance.conservices.test

# Finance roles. DEV users: admin is Finance admin, alice approves (the
# second person for four-eyes), bob keeps the books.
FINANCE_ADMIN_GID=$(learn_group finance_admin | tail -n1)
FINANCE_APPROVER_GID=$(learn_group finance_approver | tail -n1)
FINANCE_BOOKKEEPER_GID=$(learn_group finance_bookkeeper | tail -n1)
learn_group finance_read-only >/dev/null
add_user_to_group admin "$FINANCE_ADMIN_GID"
add_user_to_group alice "$FINANCE_APPROVER_GID"
add_user_to_group bob "$FINANCE_BOOKKEEPER_GID"

# Desk and Tasks modules: public PKCE SPA clients with the groups mapper.
module_spa() {
  local client=$1 name=$2 id
  id=$($KC get clients -r conservices -q clientId="$client" --fields id --format csv --noquotes | tail -n1 || true)
  if [ -z "$id" ]; then
    $KC create clients -r conservices \
      -s clientId="$client" \
      -s name="$name" \
      -s enabled=true \
      -s publicClient=true \
      -s standardFlowEnabled=true \
      -s directAccessGrantsEnabled=true \
      -s implicitFlowEnabled=false \
      -s 'attributes."pkce.code.challenge.method"=S256'
    id=$($KC get clients -r conservices -q clientId="$client" --fields id --format csv --noquotes | tail -n1)
    $KC create "clients/$id/protocol-mappers/models" -r conservices \
      -s name=groups \
      -s protocol=openid-connect \
      -s protocolMapper=oidc-group-membership-mapper \
      -s 'config."full.path"=true' \
      -s 'config."id.token.claim"=true' \
      -s 'config."access.token.claim"=true' \
      -s 'config."claim.name"=groups' \
      -s 'config."userinfo.token.claim"=true'
  fi
}
module_spa desk-spa "Desk SPA"
spa_urls desk-spa 3008 desk.conservices.test
module_spa tasks-spa "Tasks SPA"
spa_urls tasks-spa 3009 tasks.conservices.test

DESK_ADMIN_GID=$(learn_group desk-admin | tail -n1)
# Per-mailbox groups desk-<slug>-viewer|manager|delete for the dev mailbox
# support@conservices.test (slug "support").
learn_group desk-support-viewer >/dev/null
DESK_SUPPORT_MANAGER_GID=$(learn_group desk-support-manager | tail -n1)
learn_group desk-support-delete >/dev/null
TASKS_ADMIN_GID=$(learn_group tasks-admin | tail -n1)
TASKS_CREATOR_GID=$(learn_group tasks-creator | tail -n1)
# DEV users: admin runs both; alice answers the support mailbox and creates spaces.
add_user_to_group admin "$DESK_ADMIN_GID"
add_user_to_group admin "$TASKS_ADMIN_GID"
add_user_to_group alice "$DESK_SUPPORT_MANAGER_GID"
add_user_to_group alice "$TASKS_CREATOR_GID"

module_spa wiki-spa "Wiki SPA"
spa_urls wiki-spa 3007 wiki.conservices.test
WIKI_ADMIN_GID=$(learn_group wiki-admin | tail -n1)
WIKI_EDITOR_GID=$(learn_group wiki-editor | tail -n1)
# DEV users: admin runs the wiki; alice creates team spaces.
add_user_to_group admin "$WIKI_ADMIN_GID"
add_user_to_group alice "$WIKI_EDITOR_GID"

# Den portal access is the den-member group (DEN_MEMBER_GROUPS). Create it
# once and add every existing person account, so nobody loses access when
# Den starts enforcing it; HR adds new people from then on.
if ! $KC get groups -r conservices -q search=den-member --fields name --format csv --noquotes | grep -qx den-member; then
  $KC create groups -r conservices -s name=den-member
  MEMBER_GID=$($KC get groups -r conservices -q search=den-member --fields id,name --format csv --noquotes | grep ',den-member$' | cut -d, -f1)
  for uid in $($KC get users -r conservices --fields id,username --format csv --noquotes -q max=10000 | grep -v ',service-account-' | cut -d, -f1); do
    $KC update "users/$uid/groups/$MEMBER_GID" -r conservices -s realm=conservices -s userId="$uid" -s groupId="$MEMBER_GID" -n
  done
fi

# Token contract: each web app's access tokens name its own API in "aud"
# (an audience mapper per client). ID tokens are not changed, so backends
# that still take ID tokens keep working. The list is on
# docs/concepts/authentication.md (Audiences per API). Idempotent.
audience_mapper() {
  local realm=$1 client=$2 aud=$3 id names
  id=$($KC get clients -r "$realm" -q clientId="$client" --fields id --format csv --noquotes 2>/dev/null | tail -n1 || true)
  [ -n "$id" ] || return 0
  names=$($KC get "clients/$id/protocol-mappers/models" -r "$realm" --fields name --format csv --noquotes)
  if printf '%s\n' "$names" | grep -qx "audience $aud"; then
    return 0
  fi
  $KC create "clients/$id/protocol-mappers/models" -r "$realm" \
    -s "name=audience $aud" \
    -s protocol=openid-connect \
    -s protocolMapper=oidc-audience-mapper \
    -s "config.\"included.custom.audience\"=$aud" \
    -s 'config."id.token.claim"=false' \
    -s 'config."access.token.claim"=true' \
    -s 'config."introspection.token.claim"=true'
}
audience_mapper conservices den-spa den-api
audience_mapper conservices hr-spa hr-api
audience_mapper conservices stash-spa stash-api
audience_mapper conservices events-spa events-api
audience_mapper conservices learn-spa learn-api
audience_mapper conservices finance-spa finance-api
audience_mapper conservices desk-spa desk-api
audience_mapper conservices tasks-spa tasks-api
audience_mapper conservices wiki-spa wiki-api
audience_mapper attendees rally-submit events-public-api

# Full group paths on every web app's groups mapper, including realms
# imported before this (those mappers were created with full.path false).
# A top-level group still matches its short name (the leading "/" is
# stripped); a nested group such as /learn/demo-cohort matches only by path.
# Idempotent. rally-submit has no groups mapper.
full_group_paths() {
  local realm=$1 client=$2 id mid
  id=$($KC get clients -r "$realm" -q clientId="$client" --fields id --format csv --noquotes 2>/dev/null | tail -n1 || true)
  [ -n "$id" ] || return 0
  mid=$($KC get "clients/$id/protocol-mappers/models" -r "$realm" --fields id,name --format csv --noquotes | grep ',groups$' | head -n1 | cut -d, -f1 || true)
  [ -n "$mid" ] || return 0
  $KC update "clients/$id/protocol-mappers/models/$mid" -r "$realm" -s 'config."full.path"=true'
}
for client in den-spa hr-spa stash-spa events-spa learn-spa finance-spa desk-spa tasks-spa wiki-spa; do
  full_group_paths conservices "$client"
done

# Declare the attributes HR mirrors (undeclared attributes are dropped).
$KC update users/profile -r conservices -f /opt/keycloak/data/profile/user-profile.json

echo "conservices MVP patch applied"
