#!/usr/bin/env bash
#
# Inspect, list, and clean the local container registry.
#
# Usage:
#   ./scripts/registry-inspect.sh list                  # all repositories
#   ./scripts/registry-inspect.sh tags <repo>           # tags for a repo
#   ./scripts/registry-inspect.sh delete <repo> <tag>   # delete a tag
#   ./scripts/registry-inspect.sh gc                    # garbage-collect blobs
#   ./scripts/registry-inspect.sh size                  # disk usage

set -euo pipefail

readonly REGISTRY="localhost:5001"
readonly REGISTRY_CONTAINER="kind-registry"

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

require_registry() {
  if ! curl -sSf --max-time 3 "http://${REGISTRY}/v2/" >/dev/null 2>&1; then
    fail "Registry not reachable at ${REGISTRY} — run scripts/cluster-up.sh first"
  fi
}

cmd_list() {
  require_registry
  log "Repositories in ${REGISTRY}:"
  local repos
  repos=$(curl -sS "http://${REGISTRY}/v2/_catalog" | jq -r '.repositories[]?')
  if [[ -z "$repos" ]]; then
    echo "  (none)"
    return
  fi
  while IFS= read -r repo; do
    echo "  ${repo}"
  done <<< "$repos"
}

cmd_tags() {
  local repo="${1:-}"
  [[ -n "$repo" ]] || fail "Usage: $0 tags <repo>"
  require_registry

  log "Tags for ${repo}:"
  local tags
  tags=$(curl -sS "http://${REGISTRY}/v2/${repo}/tags/list" | jq -r '.tags[]?')
  if [[ -z "$tags" ]]; then
    echo "  (none)"
    return
  fi
  while IFS= read -r tag; do
    echo "  ${tag}"
  done <<< "$tags"
}

cmd_delete() {
  local repo="${1:-}" tag="${2:-}"
  [[ -n "$repo" && -n "$tag" ]] || fail "Usage: $0 delete <repo> <tag>"
  require_registry

  # Fetch the manifest digest — required to delete
  local digest
  digest=$(curl -sS -I \
    -H "Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json" \
    "http://${REGISTRY}/v2/${repo}/manifests/${tag}" \
    | grep -i '^docker-content-digest:' \
    | awk '{print $2}' \
    | tr -d '\r')

  [[ -n "$digest" ]] || fail "Could not resolve manifest digest for ${repo}:${tag}"

  log "Deleting ${repo}:${tag} (digest: ${digest})"
  local status
  status=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X DELETE "http://${REGISTRY}/v2/${repo}/manifests/${digest}")

  if [[ "$status" == "202" ]]; then
    success "Deleted ${repo}:${tag}"
    echo "  (Run '$0 gc' to actually reclaim disk)"
  else
    fail "Delete failed with HTTP ${status}"
  fi
}

cmd_gc() {
  require_registry
  log "Running garbage collection inside container..."
  docker exec "${REGISTRY_CONTAINER}" \
    bin/registry garbage-collect /etc/docker/registry/config.yml
  success "Garbage collection complete"
}

cmd_size() {
  log "Registry storage:"
  local data_dir="${HOME}/.atlas/registry-data"
  if [[ -d "$data_dir" ]]; then
    echo "  Path:  ${data_dir}"
    echo "  Size:  $(du -sh "${data_dir}" 2>/dev/null | awk '{print $1}')"
  else
    echo "  Path:  ${data_dir} (does not exist)"
  fi
}

usage() {
  grep -E '^# Usage:|^#   \./' "$0" | sed 's/^# //'
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    list)   cmd_list ;;
    tags)   cmd_tags "$@" ;;
    delete) cmd_delete "$@" ;;
    gc)     cmd_gc ;;
    size)   cmd_size ;;
    -h|--help|"") usage ;;
    *) fail "Unknown command: $cmd (see --help)" ;;
  esac
}

main "$@"
