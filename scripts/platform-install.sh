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

install_argocd() {
  section "ArgoCD"

  local namespace="argocd"
  local release="argocd"
  local chart_version="7.6.12"
  local values_file="${REPO_ROOT}/platform/argocd/values.yaml"

  [[ -f "${values_file}" ]] || fail "ArgoCD values not found: ${values_file}"

  if ! helm repo list 2>/dev/null | grep -q '^argo\s'; then
    log "Adding argo Helm repo..."
    helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
  fi
  helm repo update argo >/dev/null

  kubectl get namespace "${namespace}" >/dev/null 2>&1 \
    || kubectl create namespace "${namespace}" >/dev/null

  log "Installing ArgoCD chart version ${chart_version}..."
  helm upgrade --install "${release}" argo/argo-cd \
    --namespace "${namespace}" \
    --version "${chart_version}" \
    --values "${values_file}" \
    --wait \
    --timeout 5m

  success "ArgoCD installed"
}

main() {
  log "═══ Atlas platform-install ═══"
  require_cluster
  install_argocd
  echo
  success "Platform install complete"
  echo
  echo "  Next:  make argocd      # bring up ArgoCD UI and CLI session"
}

main "$@"
