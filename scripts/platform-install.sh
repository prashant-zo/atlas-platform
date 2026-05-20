#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED='' GREEN='' BLUE='' BOLD='' NC=''
fi

log()     { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
fail()    { echo -e "${RED}✗${NC} $*" >&2; exit 1; }
section() { echo; echo -e "${BOLD}── $* ──${NC}"; }

require_cluster() {
  kubectl cluster-info >/dev/null 2>&1 \
    || fail "No cluster reachable — run scripts/cluster-up.sh first"
  local ctx
  ctx=$(kubectl config current-context)
  [[ "$ctx" == "kind-atlas" ]] \
    || fail "Wrong context '$ctx' — expected kind-atlas"
}

install_metrics_server() {
  section "metrics-server"
  log "Applying manifest..."
  kubectl apply -f "${REPO_ROOT}/platform/metrics-server/metrics-server.yaml"

  log "Waiting for metrics-server to become ready (up to 90s)..."
  kubectl wait --for=condition=Available \
    --timeout=90s \
    -n kube-system \
    deployment/metrics-server

  success "metrics-server is ready"
}

verify_metrics() {
  section "Verifying metrics API"
  log "Waiting for first scrape (up to 30s)..."

  local attempt=0
  while ! kubectl top nodes >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [[ $attempt -gt 10 ]]; then
      fail "Metrics API not returning data after 30s"
    fi
    sleep 3
  done

  echo
  kubectl top nodes
  echo
  kubectl top pods -A | head -10
  success "Metrics API working"
}

main() {
  log "═══ Atlas platform-install ═══"
  require_cluster
  install_metrics_server
  verify_metrics
  echo
  success "Platform install complete"
}

main "$@"
