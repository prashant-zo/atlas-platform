#!/usr/bin/env bash
set -euo pipefail

# Configuration
readonly CLUSTER_NAME="atlas"
readonly REGISTRY_NAME="kind-registry"

# Color output
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

# Flag parsing
FORCE=false
KEEP_REGISTRY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)         FORCE=true; shift ;;
    --keep-registry) KEEP_REGISTRY=true; shift ;;
    -h|--help)
      grep -E '^# Usage:|^#   \./' "$0" | sed 's/^# //'
      exit 0 ;;
    *) fail "Unknown flag: $1 (use --help)" ;;
  esac
done

# Preflight
preflight() {
  command -v docker >/dev/null 2>&1 || fail "docker not found"
  command -v kind   >/dev/null 2>&1 || fail "kind not found"
  docker info >/dev/null 2>&1 || fail "Docker daemon not running"
}

# Confirmation prompt (skipped with --force)
confirm() {
  if [[ "${FORCE}" == "true" ]]; then
    warn "Force mode — skipping confirmation"
    return
  fi

  echo
  warn "This will destroy:"
  echo "    • kind cluster:  ${CLUSTER_NAME}"
  if [[ "${KEEP_REGISTRY}" == "false" ]]; then
    echo "    • registry:      ${REGISTRY_NAME} (and any cached images)"
  fi
  echo "    • all Kubernetes resources, PVCs, and data inside the cluster"
  echo

  read -r -p "Continue? Type 'yes' to proceed: " response
  if [[ "${response}" != "yes" ]]; then
    log "Aborted by user"
    exit 0
  fi
}

# Delete kind cluster (idempotent)
delete_cluster() {
  log "Checking for kind cluster '${CLUSTER_NAME}'..."

  if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    success "Cluster '${CLUSTER_NAME}' does not exist — skipping"
    return
  fi

  log "Deleting kind cluster (this removes all PVCs, namespaces, and pods)"
  kind delete cluster --name "${CLUSTER_NAME}"
  success "Cluster deleted"
}

# Stop & remove the registry container (idempotent)
delete_registry() {
  if [[ "${KEEP_REGISTRY}" == "true" ]]; then
    log "Keeping registry per --keep-registry flag"
    return
  fi

  log "Checking for registry container '${REGISTRY_NAME}'..."

  if ! docker inspect "${REGISTRY_NAME}" >/dev/null 2>&1; then
    success "Registry '${REGISTRY_NAME}' does not exist — skipping"
    return
  fi

  docker network disconnect kind "${REGISTRY_NAME}" 2>/dev/null || true

  log "Stopping and removing registry"
  docker stop "${REGISTRY_NAME}"  >/dev/null 2>&1 || true
  docker rm   "${REGISTRY_NAME}"  >/dev/null 2>&1 || true
  success "Registry removed"
}

cleanup_network() {
  log "Checking for orphan kind network..."

  if ! docker network inspect kind >/dev/null 2>&1; then
    success "No 'kind' network present — skipping"
    return
  fi

  local connected
  connected=$(docker network inspect kind -f '{{len .Containers}}')
  if [[ "${connected}" -gt 0 ]]; then
    warn "Network 'kind' still has ${connected} container(s) attached — leaving in place"
    return
  fi

  log "Removing orphan kind network"
  docker network rm kind >/dev/null 2>&1 || true
  success "Network cleaned"
}

# Final summary
summary() {
  echo
  success "Atlas teardown complete"
  echo
  echo "  To bring everything back up:  ./scripts/cluster-up.sh"
  echo
}

# Main
main() {
  log "═══ Atlas cluster-down ═══"
  preflight
  confirm
  delete_cluster
  delete_registry
  cleanup_network
  summary
}

main "$@"
