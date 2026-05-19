#!/usr/bin/env bash
set -uo pipefail

# Configuration — minimum required versions
readonly MIN_DOCKER_VERSION="20.10"
readonly MIN_KUBECTL_VERSION="1.28"
readonly MIN_KIND_VERSION="0.20"
readonly MIN_HELM_VERSION="3.13"
readonly MIN_COLIMA_CPU=4
readonly MIN_COLIMA_MEMORY_GB=8

# Ports Atlas needs available on the host
readonly REQUIRED_PORTS=(80 443 5001)

# Color output
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

# Global state
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
FIX_NOTES=()

pass() {
  echo -e "${GREEN}✓${NC}  $*"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo -e "${RED}✗${NC}  $*"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

warn() {
  echo -e "${YELLOW}⚠${NC}  $*"
  WARN_COUNT=$((WARN_COUNT + 1))
}

note_fix() {
  FIX_NOTES+=("$*")
}

section() {
  echo
  echo -e "${BOLD}── $* ──${NC}"
}

# Version comparison helper
version_ge() {
  local got="${1#v}"   # strip leading v
  local need="$2"

  # Normalize — strip anything after a dash, plus, or space
  got="${got%%[-+ ]*}"

  # printf trick: comparing dotted versions via sort -V
  [[ "$(printf '%s\n%s' "$need" "$got" | sort -V | head -n1)" == "$need" ]]
}

# Generic tool check with version
# Usage: check_tool <name> <min_version> <version_command>
check_tool() {
  local name="$1"
  local min_version="$2"
  local version_cmd="$3"

  if ! command -v "$name" >/dev/null 2>&1; then
    fail "$name not installed"
    note_fix "brew install $name"
    return
  fi

  local actual_version
  actual_version=$(eval "$version_cmd" 2>/dev/null || echo "unknown")

  if [[ "$actual_version" == "unknown" ]]; then
    warn "$name installed but version could not be parsed"
    return
  fi

  if version_ge "$actual_version" "$min_version"; then
    pass "$name $actual_version (min: $min_version)"
  else
    fail "$name $actual_version is older than required $min_version"
    note_fix "brew upgrade $name"
  fi
}

# Tool checks
check_required_tools() {
  section "Required tools"

  check_tool "docker"  "$MIN_DOCKER_VERSION"  "docker version --format '{{.Client.Version}}'"
  check_tool "kubectl" "$MIN_KUBECTL_VERSION" "kubectl version --client -o json 2>/dev/null | jq -r .clientVersion.gitVersion"
  check_tool "kind"    "$MIN_KIND_VERSION"    "kind version -q"
  check_tool "helm"    "$MIN_HELM_VERSION"    "helm version --short | sed 's/+.*//'"
}

check_optional_tools() {
  section "Atlas-specific tools"

  for tool in k9s k6 yq stern kustomize argocd mkcert jq; do
    if command -v "$tool" >/dev/null 2>&1; then
      pass "$tool installed"
    else
      warn "$tool not installed (recommended)"
      note_fix "brew install $tool"
    fi
  done
}

# Docker daemon + resources
check_docker_daemon() {
  section "Docker daemon (Colima)"

  if ! docker info >/dev/null 2>&1; then
    fail "Docker daemon not responding"
    note_fix "colima start --cpu $MIN_COLIMA_CPU --memory $MIN_COLIMA_MEMORY_GB"
    return
  fi
  pass "Docker daemon is running"

  # Check resources Colima exposed to Docker
  local cpus mem_bytes mem_gb
  cpus=$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)
  mem_bytes=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
  mem_gb=$((mem_bytes / 1024 / 1024 / 1024))

  if [[ "$cpus" -ge "$MIN_COLIMA_CPU" ]]; then
    pass "Docker has $cpus CPUs (min: $MIN_COLIMA_CPU)"
  else
    fail "Docker has only $cpus CPUs — Atlas needs at least $MIN_COLIMA_CPU"
    note_fix "colima stop && colima start --cpu $MIN_COLIMA_CPU --memory $MIN_COLIMA_MEMORY_GB"
  fi

  if [[ "$mem_gb" -ge "$MIN_COLIMA_MEMORY_GB" ]]; then
    pass "Docker has ${mem_gb}GB memory (min: ${MIN_COLIMA_MEMORY_GB}GB)"
  else
    fail "Docker has only ${mem_gb}GB memory — Atlas needs at least ${MIN_COLIMA_MEMORY_GB}GB"
    note_fix "colima stop && colima start --cpu $MIN_COLIMA_CPU --memory $MIN_COLIMA_MEMORY_GB"
  fi
}

# Port availability
check_ports() {
  section "Required ports"

  for port in "${REQUIRED_PORTS[@]}"; do
    # lsof returns 0 if the port is in use
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      # Allow it if Atlas itself owns the port (registry, kind worker)
      local user
      user=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -F c 2>/dev/null | grep '^c' | head -1 | sed 's/^c//')

      if [[ "$user" == "com.docke"* ]] || [[ "$user" == "docker"* ]] || [[ "$user" == "vmnet"* ]]; then
        pass "Port $port is in use by Docker (likely Atlas itself — OK)"
      else
        fail "Port $port is in use by process: $user"
        note_fix "lsof -nP -iTCP:$port -sTCP:LISTEN   # identify and stop it"
      fi
    else
      pass "Port $port is free"
    fi
  done
}

# Internet connectivity (for image pulls)
check_connectivity() {
  section "Network connectivity"

  if curl -sSf --max-time 5 https://registry-1.docker.io/v2/ -o /dev/null -w '' 2>&1 | true; then
    pass "Docker Hub reachable"
  else
    warn "Docker Hub unreachable — image pulls may fail"
    note_fix "Check your network / proxy settings"
  fi

  if curl -sSf --max-time 5 https://github.com -o /dev/null; then
    pass "GitHub reachable"
  else
    warn "GitHub unreachable — Helm repos and git pushes may fail"
  fi
}

# Repo structure sanity check
check_repo_structure() {
  section "Repository structure"

  local repo_root
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  local required_paths=(
    "infrastructure/kind/atlas-cluster.yaml"
    "scripts/cluster-up.sh"
    "scripts/cluster-down.sh"
    "ROADMAP.md"
    "README.md"
  )

  for path in "${required_paths[@]}"; do
    if [[ -e "${repo_root}/${path}" ]]; then
      pass "${path}"
    else
      fail "${path} missing"
    fi
  done
}

# Final summary
print_summary() {
  echo
  echo -e "${BOLD}═══ Verification summary ═══${NC}"
  echo -e "  ${GREEN}Passed:  ${PASS_COUNT}${NC}"
  echo -e "  ${YELLOW}Warn:    ${WARN_COUNT}${NC}"
  echo -e "  ${RED}Failed:  ${FAIL_COUNT}${NC}"

  if [[ ${#FIX_NOTES[@]} -gt 0 ]]; then
    echo
    echo -e "${BOLD}Suggested fixes:${NC}"
    for note in "${FIX_NOTES[@]}"; do
      echo "  • $note"
    done
  fi

  echo
  if [[ "$FAIL_COUNT" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}✓ Environment ready for Atlas${NC}"
    return 0
  else
    echo -e "${RED}${BOLD}✗ Environment has issues — fix the failures above${NC}"
    return 1
  fi
}

# Main
main() {
  echo -e "${BOLD}Atlas environment verification${NC}"
  echo "Checking your machine is ready to run Atlas..."

  check_required_tools
  check_optional_tools
  check_docker_daemon
  check_ports
  check_connectivity
  check_repo_structure

  print_summary
}

main "$@"
