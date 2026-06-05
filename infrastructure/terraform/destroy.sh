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

# Strong confirmation — destroy is irreversible

confirm_destroy() {
  echo
  warn "=== ABOUT TO DESTROY AWS RESOURCES ==="
  echo
  echo "This will destroy:"
  echo "  - IAM-IRSA roles"
  echo "  - EKS cluster (control plane + 2 worker nodes)"
  echo "  - VPC, subnets, NAT gateway, route tables, EIPs"
  echo
  echo "All Kubernetes workloads on the cluster will be deleted."
  echo "All persistent volumes will be deleted."
  echo "This action is IRREVERSIBLE."
  echo
  read -rp "Type 'destroy atlas' to confirm: " confirm
  if [[ "$confirm" != "destroy atlas" ]]; then
    log "Aborted by user. Resources still running (still costing money)."
    exit 0
  fi
  echo
}

# Destroy in reverse order: iam-irsa → eks → vpc

destroy_iam_irsa() {
  log "═══ Step 1/3 — Destroying IAM-IRSA ═══"

  if [[ ! -f "$IAM_IRSA_DIR/terraform.tfstate" && ! -d "$IAM_IRSA_DIR/.terraform" ]]; then
    warn "IAM-IRSA has no state — skipping"
    return 0
  fi

  cd "$IAM_IRSA_DIR"
  terraform destroy -auto-approve -input=false
  success "IAM-IRSA destroyed"
  cd "$SCRIPT_DIR"
}

destroy_eks() {
  log "═══ Step 2/3 — Destroying EKS (~8-10 min) ═══"

  if [[ ! -f "$EKS_DIR/terraform.tfstate" && ! -d "$EKS_DIR/.terraform" ]]; then
    warn "EKS has no state — skipping"
    return 0
  fi

  cd "$EKS_DIR"
  terraform destroy -auto-approve -input=false
  success "EKS destroyed"
  cd "$SCRIPT_DIR"
}

destroy_vpc() {
  log "═══ Step 3/3 — Destroying VPC ═══"

  if [[ ! -f "$VPC_DIR/terraform.tfstate" && ! -d "$VPC_DIR/.terraform" ]]; then
    warn "VPC has no state — skipping"
    return 0
  fi

  cd "$VPC_DIR"
  terraform destroy -auto-approve -input=false
  success "VPC destroyed"
  cd "$SCRIPT_DIR"
}

# Verify nothing's left behind

verify_clean() {
  log "Verifying no Atlas resources remain..."

  # Quick check: list any EC2 instances tagged Project=atlas
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

  # Check NAT gateways (most expensive lingering resource)
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

# Summary

print_summary() {
  echo
  echo "═══════════════════════════════════════════════════════════════"
  success "Teardown complete!"
  echo "═══════════════════════════════════════════════════════════════"
  echo
  echo "  All Atlas modules destroyed."
  echo "  Verify in AWS console: https://console.aws.amazon.com"
  echo "  Check Cost Explorer in 24h to confirm \$0 ongoing charges."
  echo
}

# Main

main() {
  preflight
  confirm_destroy
  destroy_iam_irsa
  destroy_eks
  destroy_vpc
  verify_clean
  print_summary
}

main "$@"
