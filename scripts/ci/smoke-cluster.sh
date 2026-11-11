#!/usr/bin/env bash
# CI ONLY. Builds the local-trial cluster of the Den quickstart on kind and
# installs every module from its Helm chart with pinned published images, for
# the nightly smoke workflow (.github/workflows/smoke.yml). Then it forwards
# the backends to fixed localhost ports for scripts/smoke-*.ps1.
#
#   scripts/ci/smoke-cluster.sh up             # cluster, platform, modules
#   scripts/ci/smoke-cluster.sh port-forward   # background port-forwards
#   scripts/ci/smoke-cluster.sh diagnose       # pods, events, logs on failure
#
# Needs: docker, kind, kubectl, helm, openssl, git. Run from the repository
# root. Every value here is a PUBLIC dev value (the same as the Docker Compose
# dev stack); nothing of this is fit for a real installation.
# Docs: https://aglelectronics.github.io/con-services/contributing/ci/#smoke-tests
set -euo pipefail

MODULES_VERSION="${MODULES_VERSION:-1.0.0-1}"
# Folder holding <repo>/infra/access-config.toml of the module repositories
# (the workflow checks them out at the release tag).
ACCESS_CONFIG_DIR="${ACCESS_CONFIG_DIR:-modules}"
GATEWAY_API_VERSION=v1.6.3
CILIUM_VERSION=1.20.4
CERT_MANAGER_VERSION=v1.21.3
TRUST_MANAGER_VERSION=v0.26.0

OVERLAY=deploy/kubernetes/overlays/example
PG_ADMIN_PASSWORD=postgres-dev-password # = overlays/example/secrets.yaml

# chart|namespace|database role|access-config repository ("" = none)
MODULES=(
  "stash|conservices-stash|stash|stash"
  "hr|conservices-hr|hr|"
  "rally|conservices-rally|events|Rally"
  "learn|conservices-learn|learn|learn"
  "finance|conservices-finance|finance|"
  "desk|conservices-desk|desk|desk"
  "tasks|conservices-tasks|tasks|tasks"
  "wiki|conservices-wiki|wiki|wiki"
)

# Local port for each backend (= the Docker Compose dev ports, so the smoke
# scripts' SMOKE_*_API variables follow one pattern), plus Den, Keycloak and
# the Tasks web app.
PORT_FORWARDS=(
  "conservices-den|den-backend|8090|8080"
  "conservices-identity|keycloak-public|8443|443"
  "conservices-stash|stash-backend|8088|8080"
  "conservices-hr|hr-backend|8110|8080"
  "conservices-rally|rally-backend|8100|8080"
  "conservices-learn|learn-backend|8120|8080"
  "conservices-finance|finance-backend|8130|8080"
  "conservices-desk|desk-backend|8150|8080"
  "conservices-tasks|tasks-backend|8160|8080"
  "conservices-tasks|tasks-frontend|3009|8080"
  "conservices-wiki|wiki-backend|8140|8080"
)

log() { printf '\n==> %s\n' "$*"; }

# retry <tries> <command...>: for applies that race webhooks and CRDs.
retry() {
  local n=$1 i; shift
  for ((i = 1; i <= n; i++)); do
    if "$@"; then return 0; fi
    echo "attempt $i/$n failed; retrying in 10s"
    sleep 10
  done
  return 1
}

psql_admin() {
  kubectl -n conservices-data exec postgres-0 -c postgres -- \
    env PGPASSWORD="$PG_ADMIN_PASSWORD" psql -v ON_ERROR_STOP=1 -U postgres -d postgres "$@"
}

# The dev values each module's Secret holds (same as docker-compose.yml).
module_secret_literals() {
  local chart=$1 role=$2
  local url="postgres://${role}:${role}-dev-password@postgres.conservices-data.svc.cluster.local:5432/${role}?sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt"
  printf '%s\n' "--from-literal=DATABASE_URL=$url"
  printf '%s\n' "--from-literal=DEN_LINK_ENCRYPTION_KEY=$(printf 'dev-only-%s-den-link-key-ci-0000' "$chart" | head -c 32 | base64)"
  case "$chart" in
    stash | rally | learn | tasks | wiki)
      printf '%s\n' "--from-literal=S3_ACCESS_KEY_ID=conservices" "--from-literal=S3_SECRET_ACCESS_KEY=conservicesdev" ;;
  esac
  case "$chart" in
    hr) printf '%s\n' "--from-literal=KEYCLOAK_CLIENT_SECRET=hr-provisioner-dev-secret" "--from-literal=LEARN_SERVICE_TOKEN=learn-service-dev-token" ;;
    learn) printf '%s\n' "--from-literal=KEYCLOAK_CLIENT_SECRET=learn-provisioner-dev-secret" "--from-literal=LEARN_SERVICE_TOKEN=learn-service-dev-token" ;;
    desk) printf '%s\n' "--from-literal=DESK_SECRET_KEY=desk-dev-secret-change-me" ;;
    tasks) printf '%s\n' "--from-literal=TASKS_SERVICE_TOKEN=tasks-service-dev-token" ;;
    wiki) printf '%s\n' "--from-literal=WIKI_SERVICE_TOKEN=wiki-service-dev-token" ;;
  esac
}

cluster_up() {
  log "kind cluster"
  kind create cluster --config deploy/kubernetes/local-cluster/kind-config.yaml

  log "Gateway API $GATEWAY_API_VERSION, Cilium $CILIUM_VERSION"
  kubectl apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/standard-install.yaml"
  helm repo add cilium https://helm.cilium.io >/dev/null
  helm install cilium cilium/cilium --version "$CILIUM_VERSION" -n kube-system \
    -f deploy/kubernetes/local-cluster/cilium-values.yaml
  kubectl -n kube-system rollout status daemonset/cilium --timeout=300s
  kubectl wait node --all --for=condition=Ready --timeout=180s

  log "cert-manager $CERT_MANAGER_VERSION, trust-manager $TRUST_MANAGER_VERSION"
  kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/$CERT_MANAGER_VERSION/cert-manager.yaml"
  kubectl wait --namespace cert-manager --for=condition=Available deployment --all --timeout=180s
  helm upgrade --install trust-manager oci://quay.io/jetstack/charts/trust-manager \
    --namespace cert-manager --version "$TRUST_MANAGER_VERSION" --wait
}

fill_local() {
  log "local/ files (CI certificate authority instead of mkcert)"
  local d="$OVERLAY/local"
  mkdir -p "$d"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 \
    -subj "/CN=Con Services CI smoke CA" -keyout "$RUNNER_TMP/ca.key" -out "$d/rootCA.pem" 2>/dev/null
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -subj "/CN=*.conservices.test" -keyout "$d/tls.key" -out "$RUNNER_TMP/tls.csr" 2>/dev/null
  printf 'subjectAltName=DNS:*.conservices.test,DNS:auth.conservices.test,DNS:den.conservices.test\n' >"$RUNNER_TMP/san.ext"
  openssl x509 -req -in "$RUNNER_TMP/tls.csr" -CA "$d/rootCA.pem" -CAkey "$RUNNER_TMP/ca.key" \
    -CAcreateserial -days 2 -extfile "$RUNNER_TMP/san.ext" -out "$d/tls.crt" 2>/dev/null
  cp infra/keycloak/realm-conservices.json "$d/"
  rm -rf "$d/theme"
  cp -R infra/keycloak/themes/conservices "$d/theme"
}

platform_up() {
  log "Platform: kubectl apply -k $OVERLAY"
  retry 6 kubectl apply -k "$OVERLAY"
  kubectl -n conservices-data rollout status statefulset/postgres --timeout=300s
  kubectl -n conservices-data rollout status deployment/s3 --timeout=300s
  kubectl -n conservices-identity rollout status deployment/keycloak --timeout=600s
  kubectl -n conservices-den rollout status deployment/den-backend --timeout=600s
}

module_up() {
  local chart=$1 ns=$2 role=$3 repo=$4
  log "Module $chart ($MODULES_VERSION)"

  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  # The labels the platform's NetworkPolicies and trust-manager select on.
  kubectl label namespace "$ns" --overwrite \
    app.kubernetes.io/part-of=conservices conservices.io/tier=module \
    "conservices.io/module=$chart" pod-security.kubernetes.io/enforce=restricted

  # What Den's "Create a database for it" does in the quickstart.
  if [ "$(psql_admin -tAc "SELECT 1 FROM pg_roles WHERE rolname='$role'")" != 1 ]; then
    psql_admin -c "CREATE ROLE \"$role\" LOGIN PASSWORD '${role}-dev-password'"
    psql_admin -c "CREATE DATABASE \"$role\" OWNER \"$role\""
  fi

  local -a literals
  mapfile -t literals < <(module_secret_literals "$chart" "$role")
  kubectl -n "$ns" create secret generic "$chart-secrets" "${literals[@]}" \
    --dry-run=client -o yaml | kubectl apply -f -

  local -a args=(
    --namespace "$ns"
    --set "image.backend.tag=$MODULES_VERSION"
    --set "image.frontend.tag=$MODULES_VERSION"
    # Pairing is not part of this run; the modules answer on their own.
    --set den.mode=standalone
    # One node, no Gateway routes needed: the smoke scripts use port-forwards.
    --set frontend.replicas=1
    --set ha.podDisruptionBudget=false
    --set ha.topologySpread=false
    --set route.enabled=false
    # The charts' policies target the GitOps platform (CloudNativePG, Garage);
    # the trial platform's own policies still apply on its side.
    --set networkPolicy.enabled=false
    # Tokens are issued for https://auth.conservices.test; the trial pins
    # keycloak-public at 10.96.0.100 (overlays/example/keycloak-local.yaml).
    --set 'backend.hostAliases[0].ip=10.96.0.100'
    --set 'backend.hostAliases[0].hostnames[0]=auth.conservices.test'
  )
  [ "$chart" = stash ] || args+=(--set "image.migrate.tag=$MODULES_VERSION")
  if [ "$chart" = hr ]; then
    # Every catalog, like the dev stack (slug=URL; Rally's slug is "events").
    local sources="den=https://den-backend.conservices-den.svc.cluster.local:8080/api/role-catalog" slug app
    for slug in stash events learn finance desk tasks wiki; do
      app=$slug; [ "$slug" = events ] && app=rally
      sources+=",$slug=https://$app-backend.conservices-$app.svc.cluster.local:8080/api/role-catalog"
    done
    # Helm splits --set on commas; escape them.
    args+=(--set-string "config.ROLE_CATALOG_SOURCES=${sources//,/\\,}")
  fi
  if [ -n "$repo" ]; then
    kubectl -n "$ns" create configmap "$chart-access-config" \
      --from-file="access-config.toml=$ACCESS_CONFIG_DIR/$repo/infra/access-config.toml" \
      --dry-run=client -o yaml | kubectl apply -f -
  fi

  helm upgrade --install "$chart" "deploy/charts/$chart" "${args[@]}"
}

modules_up() {
  local m chart ns role repo
  for m in "${MODULES[@]}"; do
    IFS='|' read -r chart ns role repo <<<"$m"
    module_up "$chart" "$ns" "$role" "$repo"
  done
  for m in "${MODULES[@]}"; do
    IFS='|' read -r chart ns role repo <<<"$m"
    kubectl -n "$ns" rollout status "deployment/$chart-backend" --timeout=600s
    kubectl -n "$ns" rollout status "deployment/$chart-frontend" --timeout=300s
  done
}

port_forward() {
  local p ns svc local_port remote_port
  for p in "${PORT_FORWARDS[@]}"; do
    IFS='|' read -r ns svc local_port remote_port <<<"$p"
    nohup kubectl -n "$ns" port-forward "svc/$svc" "$local_port:$remote_port" \
      >"$RUNNER_TMP/pf-$svc.log" 2>&1 &
  done
  # Any HTTP answer means the forward works; status codes are the smoke's job.
  for p in "${PORT_FORWARDS[@]}"; do
    IFS='|' read -r ns svc local_port remote_port <<<"$p"
    retry 12 curl -ksS -o /dev/null "https://127.0.0.1:$local_port/"
  done
}

diagnose() {
  kubectl get pods -A -o wide || true
  kubectl get events -A --sort-by=.lastTimestamp | tail -n 100 || true
  local ns
  for ns in $(kubectl get ns -l app.kubernetes.io/part-of=conservices -o name | cut -d/ -f2); do
    echo "::group::logs $ns"
    kubectl -n "$ns" logs --all-containers --prefix --tail=80 -l app.kubernetes.io/component=backend || true
    echo "::endgroup::"
  done
}

RUNNER_TMP="${RUNNER_TEMP:-$(mktemp -d)}"
case "${1:-}" in
  up) cluster_up; fill_local; platform_up; modules_up ;;
  port-forward) port_forward ;;
  diagnose) diagnose ;;
  *) echo "usage: $0 up|port-forward|diagnose" >&2; exit 2 ;;
esac
