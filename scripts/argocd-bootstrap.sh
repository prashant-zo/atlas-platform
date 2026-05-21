#!/usr/bin/env bash
set -euo pipefail

readonly NAMESPACE="argocd"
readonly LOCAL_PORT="8080"
readonly STATE_DIR="${HOME}/.atlas"
readonly PID_FILE="${STATE_DIR}/argocd-portforward.pid"
readonly LOG_FILE="${STATE_DIR}/argocd-portforward.log"

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

log()     { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $*"; }
fail()    { echo -e "${RED}✗${NC} $*" >&2; exit 1; }
section() { echo; echo -e "${BOLD}── $* ──${NC}"; }

preflight() {
  command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
  command -v argocd  >/dev/null 2>&1 || fail "argocd CLI not found (brew install argocd)"

  kubectl cluster-info >/dev/null 2>&1 \
    || fail "No cluster reachable — run 'make up' first"

  kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 \
    || fail "Namespace '${NAMESPACE}' missing — run 'make platform' first"

  kubectl get deployment argocd-server -n "${NAMESPACE}" >/dev/null 2>&1 \
    || fail "ArgoCD not installed — run 'make platform' first"

  mkdir -p "${STATE_DIR}"
}

is_portforward_running() {
  if [[ ! -f "${PID_FILE}" ]]; then
    return 1
  fi
  local pid
  pid=$(cat "${PID_FILE}")
  if kill -0 "${pid}" 2>/dev/null && ps -p "${pid}" -o command= | grep -q "port-forward"; then
    return 0
  fi
  rm -f "${PID_FILE}"
  return 1
}

stop_portforward() {
  if [[ -f "${PID_FILE}" ]]; then
    local pid
    pid=$(cat "${PID_FILE}")
    if kill -0 "${pid}" 2>/dev/null; then
      log "Stopping existing port-forward (PID ${pid})"
      kill "${pid}" 2>/dev/null || true
      sleep 1
    fi
    rm -f "${PID_FILE}"
  fi
}

start_portforward() {
  # Free the port if something else is squatting on it
  if lsof -nP -iTCP:"${LOCAL_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
    if ! is_portforward_running; then
      fail "Port ${LOCAL_PORT} in use by another process. Free it before continuing."
    fi
    return  # Our own forward is already running
  fi

  # Wait for the argocd-server pod to be Ready. Forwarding to a
  # not-yet-ready pod is the most common cause of "port-forward exists
  # but nothing serves" — be patient before establishing the forward.
  log "Waiting for argocd-server pod to be Ready..."
  if ! kubectl wait --for=condition=Ready pod \
        -l app.kubernetes.io/name=argocd-server \
        -n "${NAMESPACE}" \
        --timeout=120s >/dev/null 2>&1; then
    fail "argocd-server pod did not become Ready in 120s"
  fi

  # Forward to the SERVICE on its http port. kubectl resolves the service
  # to a healthy backing pod and connects to that pod's targetPort.
  # We deliberately leave kubectl to do the resolution rather than
  # hardcoding pod names (which change on every restart).
  local svc_port="80"
  log "Starting port-forward (localhost:${LOCAL_PORT} → svc/argocd-server:${svc_port})..."

  # Use --address 127.0.0.1 explicitly to avoid IPv6 weirdness on some Macs.
  kubectl port-forward svc/argocd-server -n "${NAMESPACE}" \
    --address 127.0.0.1 \
    "${LOCAL_PORT}:${svc_port}" \
    >"${LOG_FILE}" 2>&1 &
  echo $! > "${PID_FILE}"

  # Readiness loop — curl until the forward actually serves a response.
  # ArgoCD returns 307 (redirect to /login) on the root path, which
  # counts as success for -sSf.
  log "Waiting for forward to become reachable..."
  local attempt=0
  while ! curl -sS --max-time 2 -o /dev/null -w '%{http_code}' \
            "http://localhost:${LOCAL_PORT}" 2>/dev/null | grep -qE '^(200|301|302|303|307|308)$'; do

    attempt=$((attempt + 1))

    # Also verify kubectl is still alive — if it died, the forward is dead
    local pid
    pid=$(cat "${PID_FILE}")
    if ! kill -0 "${pid}" 2>/dev/null; then
      echo "kubectl port-forward process died. Log output:"
      tail -20 "${LOG_FILE}" 2>/dev/null || true
      fail "Port-forward process exited unexpectedly"
    fi

    if [[ $attempt -gt 20 ]]; then
      stop_portforward
      echo "Last 20 lines of port-forward log:"
      tail -20 "${LOG_FILE}" 2>/dev/null || true
      fail "Port-forward did not become reachable after 20s"
    fi
    sleep 1
  done

  success "Port-forward running (PID $(cat "${PID_FILE}")) — http://localhost:${LOCAL_PORT}"
}


get_admin_password() {
  kubectl -n "${NAMESPACE}" get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" 2>/dev/null \
    | base64 -d
}

cli_login() {
  local password
  password=$(get_admin_password)

  if [[ -z "${password}" ]]; then
    warn "argocd-initial-admin-secret not found — likely already rotated."
    warn "Skipping CLI login. Manage existing user via 'argocd account'."
    return
  fi

  log "Logging in via argocd CLI..."
  set +o pipefail
  yes | argocd login "localhost:${LOCAL_PORT}" \
    --username admin \
    --password "${password}" \
    --insecure \
    --grpc-web
  local login_rc=$?
  set -o pipefail

  if [[ $login_rc -ne 0 ]]; then
    fail "argocd login failed with exit code ${login_rc}"
  fi

  success "Logged in as admin"
}

print_summary() {
  local password
  password=$(get_admin_password)

  echo
  echo -e "${BOLD}═══ ArgoCD is ready ═══${NC}"
  echo
  echo "  Web UI:    http://localhost:${LOCAL_PORT}"
  echo "  Username:  admin"
  if [[ -n "${password}" ]]; then
    echo "  Password:  ${password}"
  else
    echo "  Password:  (rotated — secret no longer present)"
  fi
  echo
  echo "  CLI:       argocd app list"
  echo "  Stop:      make argocd-stop"
  echo
}

cmd_up() {
  preflight

  section "ArgoCD bootstrap"

  # Stop any existing port-forward so we always have a fresh, healthy one
  stop_portforward
  start_portforward
  cli_login
  print_summary
}

cmd_stop() {
  preflight
  if is_portforward_running; then
    stop_portforward
    success "Port-forward stopped"
  else
    warn "No port-forward running"
  fi
}

cmd_status() {
  preflight
  if is_portforward_running; then
    local pid
    pid=$(cat "${PID_FILE}")
    success "Port-forward running (PID ${pid}) → http://localhost:${LOCAL_PORT}"
  else
    warn "No port-forward running"
  fi

  if argocd account get-user-info --grpc-web >/dev/null 2>&1; then
    success "ArgoCD CLI session is active"
  else
    warn "ArgoCD CLI not logged in"
  fi
}

main() {
  local cmd="${1:-up}"
  case "${cmd}" in
    up|"")    cmd_up ;;
    --stop)   cmd_stop ;;
    --status) cmd_status ;;
    -h|--help)
      grep -E '^# Usage:|^#   \./' "$0" | sed 's/^# //'
      exit 0 ;;
    *) fail "Unknown command: ${cmd} (see --help)" ;;
  esac
}

main "$@"
