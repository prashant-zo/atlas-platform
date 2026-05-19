#!/usr/bin/env bash
set -euo pipefail

readonly CLUSTER_NAME="atlas"
readonly REGISTRY_NAME="kind-registry"
readonly REGISTRY_PORT="5001"
readonly KIND_CONFIG="infrastructure/kind/atlas-cluster.yaml"
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Color output (skip if not a terminal)
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

log()     { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $*"; }
fail()    { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

# Preflight checks
preflight() {
  log "Running preflight checks..."

  command -v docker >/dev/null 2>&1 || fail "docker not found"
  command -v kind   >/dev/null 2>&1 || fail "kind not found"
  command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"

  # Docker daemon must be running (Colima)
  docker info >/dev/null 2>&1 || fail "Docker daemon not running — start Colima: 'colima start'"

  # Verify the kind config file exists
  [[ -f "${REPO_ROOT}/${KIND_CONFIG}" ]] || fail "Kind config not found at ${KIND_CONFIG}"

  success "Preflight passed"
}

# Local Docker registry (idempotent)
start_registry() {
  log "Ensuring local registry is running..."

  # If the registry container already exists in any state, restart or reuse it
  if [[ "$(docker inspect -f '{{.State.Running}}' "${REGISTRY_NAME}" 2>/dev/null || echo false)" == "true" ]]; then
    success "Registry '${REGISTRY_NAME}' already running"
    return
  fi

  if docker inspect "${REGISTRY_NAME}" >/dev/null 2>&1; then
    log "Registry container exists but stopped — restarting"
    docker start "${REGISTRY_NAME}" >/dev/null
  else
    log "Creating registry container on port ${REGISTRY_PORT}"
    docker run -d \
      --restart=always \
      -p "127.0.0.1:${REGISTRY_PORT}:5000" \
      --network bridge \
      --name "${REGISTRY_NAME}" \
      registry:2 >/dev/null
  fi

  success "Registry ready at localhost:${REGISTRY_PORT}"
}

# Kind cluster (idempotent)
create_cluster() {
  log "Ensuring kind cluster '${CLUSTER_NAME}' exists..."

  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    success "Cluster '${CLUSTER_NAME}' already exists — skipping creation"
    return
  fi

  log "Creating cluster (this takes ~60 seconds on first run)"
  kind create cluster \
    --name "${CLUSTER_NAME}" \
    --config "${REPO_ROOT}/${KIND_CONFIG}" \
    --wait 90s

  success "Cluster created"
}

# Wire registry to cluster nodes
connect_registry_to_cluster() {
  log "Wiring registry into cluster nodes..."

  local registry_dir="/etc/containerd/certs.d/localhost:${REGISTRY_PORT}"

  for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
    docker exec "${node}" mkdir -p "${registry_dir}"
    cat <<EOF | docker exec -i "${node}" cp /dev/stdin "${registry_dir}/hosts.toml"
[host."http://${REGISTRY_NAME}:5000"]
EOF
  done

  # Connect the registry container to the kind Docker network so nodes can reach it by name
  if [[ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${REGISTRY_NAME}")" == "null" ]]; then
    docker network connect kind "${REGISTRY_NAME}" >/dev/null 2>&1 || true
  fi

  # Publish a ConfigMap documenting the registry — this is the official kind convention
  # so tools like Tilt/Skaffold auto-discover the registry.
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

  success "Registry wired to cluster"
}

# Show cluster summary
summary() {
  log "Cluster summary:"
  kubectl cluster-info --context "kind-${CLUSTER_NAME}"
  echo
  kubectl get nodes -o wide
  echo
  success "Atlas cluster is ready"
  echo
  echo "  Context:   kind-${CLUSTER_NAME}"
  echo "  Registry:  localhost:${REGISTRY_PORT}"
  echo "  Ingress:   http://localhost  https://localhost"
  echo
  echo "  Next:  k9s   |   kubectl get pods -A"
}

# Main
main() {
  log "═══ Atlas cluster-up ═══"
  preflight
  start_registry
  create_cluster
  connect_registry_to_cluster
  summary
}

main "$@"
