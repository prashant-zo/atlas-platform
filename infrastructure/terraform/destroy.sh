#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPC_DIR="${SCRIPT_DIR}/vpc"
EKS_DIR="${SCRIPT_DIR}/eks"
IAM_IRSA_DIR="${SCRIPT_DIR}/iam-irsa"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
success() { echo -e "${GREEN}[$(date +%H:%M:%S)] ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}[$(date +%H:%M:%S)] !${NC} $*"; }
error()   { echo -e "${RED}[$(date +%H:%M:%S)] ✗${NC} $*" >&2; }

# Pre-flight
preflight() {
  log "Pre-flight checks..."

  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    error "AWS credentials not configured"
    exit 1
  fi

  local arn
  arn=$(aws sts get-caller-identity --query Arn --output text)
  if [[ "$arn" == *":root" ]]; then
    error "Refusing to destroy as root. Use atlas-admin IAM user."
    exit 1
  fi
  success "AWS auth: $arn"
}

# Strong confirmation
confirm_destroy() {
  echo
  warn "=== ABOUT TO DESTROY AWS RESOURCES ==="
  echo
  echo "This will destroy:"
  echo "  - IAM-IRSA roles"
  echo "  - EKS cluster (control plane + worker nodes)"
  echo "  - VPC, subnets, NAT gateway, route tables, EIPs"
  echo
  echo "All Kubernetes workloads on the cluster will be deleted."
  echo "All persistent volumes will be deleted."
  echo "This action is IRREVERSIBLE."
  echo
  read -rp "Type 'destroy atlas' to confirm: " confirm
  if [[ "$confirm" != "destroy atlas" ]]; then
    log "Aborted by user. Resources still running."
    exit 0
  fi
  echo
}

# Generic module destroyer to handle remote/local state safely
destroy_module() {
  local name="$1"
  local dir="$2"
  
  log "═══ Destroying $name ═══"
  
  if [[ ! -d "$dir" ]]; then
    warn "$name directory not found at $dir — skipping"
    return 0
  fi

  cd "$dir"
  
  # Initialize to ensure remote backends and providers are ready
  log "Initializing Terraform for $name..."
  terraform init -input=false >/dev/null 2>&1 || true
  
  log "Applying destruction for $name..."
  terraform destroy -auto-approve -input=false
  success "$name destroyed"
  cd "$SCRIPT_DIR"
}

destroy_iam_irsa() { destroy_module "IAM-IRSA" "$IAM_IRSA_DIR"; }
destroy_eks()      { destroy_module "EKS" "$EKS_DIR"; }
destroy_vpc()      { destroy_module "VPC" "$VPC_DIR"; }

# Verify nothing's left behind
verify_clean() {
  log "Verifying no Atlas resources remain..."

  local instances
  instances=$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=atlas" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text 2>/dev/null || echo "")

  if [[ -n "$instances" ]]; then
    warn "Found EC2 instances tagged Project=atlas: $instances"
    warn "These may still be billing. Investigate manually."
  else
    success "No Atlas EC2 instances running"
  fi

  local nats
  nats=$(aws ec2 describe-nat-gateways \
    --filter "Name=tag:Project,Values=atlas" "Name=state,Values=available,pending" \
    --query 'NatGateways[].NatGatewayId' \
    --output text 2>/dev/null || echo "")

  if [[ -n "$nats" ]]; then
    warn "Found NAT gateways tagged Project=atlas: $nats"
    warn "These cost \$0.045/hour. Destroy them manually."
  else
    success "No Atlas NAT gateways running"
  fi
}

print_summary() {
  echo
  echo "═══════════════════════════════════════════════════════════════"
  success "Teardown complete!"
  echo "═══════════════════════════════════════════════════════════════"
  echo "  All Atlas modules destroyed."
  echo "  Verify in AWS console: https://console.aws.amazon.com"
  echo
}

predestroy_cleanup() {
  log "═══ Step 0/3 — Kubernetes pre-destroy cleanup ═══"

  local script="${SCRIPT_DIR}/../../scripts/pre-destroy-cleanup.sh"

  if [[ ! -x "$script" ]]; then
    warn "pre-destroy-cleanup.sh not found/executable at $script — skipping"
    return 0
  fi

  if ! "$script"; then
    error "Pre-destroy cleanup FAILED. Aborting before terraform destroy."
    exit 1
  fi

  success "Pre-destroy cleanup complete"
}

main() {
  preflight
  confirm_destroy
  predestroy_cleanup
  destroy_iam_irsa
  destroy_eks
  destroy_vpc
  verify_clean
  print_summary
}

main "$@"
