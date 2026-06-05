#!/usr/bin/env bash

set -euo pipefail

# Configuration

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPC_DIR="${SCRIPT_DIR}/vpc"
EKS_DIR="${SCRIPT_DIR}/eks"
IAM_IRSA_DIR="${SCRIPT_DIR}/iam-irsa"

VPC_OUTPUTS="/tmp/atlas-vpc-outputs.json"
EKS_OUTPUTS="/tmp/atlas-eks-outputs.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # No Color

log()     { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
success() { echo -e "${GREEN}[$(date +%H:%M:%S)] ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}[$(date +%H:%M:%S)] !${NC} $*"; }
error()   { echo -e "${RED}[$(date +%H:%M:%S)] ✗${NC} $*" >&2; }

# Pre-flight checks

preflight() {
  log "Pre-flight checks..."

  # Required commands
  for cmd in terraform aws jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      error "Required command not found: $cmd"
      exit 1
    fi
  done
  success "terraform, aws, jq installed"

  # AWS auth
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    error "AWS credentials not configured. Run: aws configure --profile atlas"
    exit 1
  fi
  local arn
  arn=$(aws sts get-caller-identity --query Arn --output text)
  success "AWS auth: ${arn}"

  # Confirm we're using atlas-admin, not root
  if [[ "$arn" == *":root" ]]; then
    error "Refusing to apply as root. Use atlas-admin IAM user."
    exit 1
  fi

  # Module directories exist
  for dir in "$VPC_DIR" "$EKS_DIR" "$IAM_IRSA_DIR"; do
    if [[ ! -d "$dir" ]]; then
      error "Module directory missing: $dir"
      exit 1
    fi
  done
  success "All three module directories present"
}

# User confirmation — costs are real, require explicit consent

confirm_apply() {
  echo
  warn "=== ABOUT TO CREATE AWS RESOURCES ==="
  echo
  echo "This will create:"
  echo "  - VPC with 6 subnets across 3 AZs"
  echo "  - NAT Gateway       (~\$0.045/hour)"
  echo "  - EKS control plane (~\$0.10/hour)"
  echo "  - 2× t3.large Spot nodes (~\$0.05/hour combined)"
  echo "  - IAM roles for workloads"
  echo
  echo "Estimated cost while running: ~\$0.20/hour (~\$5/day)"
  echo
  echo "Apply takes ~15-20 minutes total."
  echo "Run destroy.sh when done to avoid ongoing charges."
  echo
  read -rp "Type 'apply' to proceed: " confirm
  if [[ "$confirm" != "apply" ]]; then
    log "Aborted by user."
    exit 0
  fi
  echo
}

# Apply VPC module

apply_vpc() {
  log "═══ Step 1/3 — Applying VPC module ═══"
  cd "$VPC_DIR"

  if [[ ! -d .terraform ]]; then
    log "Initializing VPC module..."
    terraform init -input=false
  fi

  terraform apply -auto-approve -input=false

  # Save outputs for the next module
  terraform output -json > "$VPC_OUTPUTS"
  success "VPC applied. Outputs cached at $VPC_OUTPUTS"

  cd "$SCRIPT_DIR"
}

# Wire VPC outputs into EKS tfvars

wire_eks_inputs() {
  log "Wiring VPC outputs into EKS module's terraform.tfvars..."

  local vpc_id
  local public_subnets_json
  local private_subnets_json

  vpc_id=$(jq -r '.vpc_id.value' "$VPC_OUTPUTS")
  public_subnets_json=$(jq -c '.public_subnet_ids.value' "$VPC_OUTPUTS")
  private_subnets_json=$(jq -c '.private_subnet_ids.value' "$VPC_OUTPUTS")

  if [[ -z "$vpc_id" || "$vpc_id" == "null" ]]; then
    error "Failed to extract vpc_id from VPC outputs"
    exit 1
  fi

  # Build a fresh tfvars file (idempotent — overwrites the previous one)
  cat > "$EKS_DIR/terraform.tfvars" <<EOF
region             = "ap-south-1"
environment        = "dev"
cluster_name       = "atlas-eks-dev"
kubernetes_version = "1.31"

# Wired automatically by bootstrap.sh from vpc module outputs.
vpc_id             = "${vpc_id}"
public_subnet_ids  = ${public_subnets_json}
private_subnet_ids = ${private_subnets_json}

# Node group
node_instance_type = "t3.large"
node_desired_size  = 2
node_min_size      = 2
node_max_size      = 4
node_disk_size     = 20

# Endpoint access
endpoint_public_access  = true
endpoint_private_access = true
public_access_cidrs     = ["0.0.0.0/0"]
EOF

  success "EKS terraform.tfvars updated"
}

# Apply EKS module

apply_eks() {
  log "═══ Step 2/3 — Applying EKS module (~12-15 min) ═══"
  cd "$EKS_DIR"

  if [[ ! -d .terraform ]]; then
    log "Initializing EKS module..."
    terraform init -input=false
  fi

  terraform apply -auto-approve -input=false

  terraform output -json > "$EKS_OUTPUTS"
  success "EKS applied. Outputs cached at $EKS_OUTPUTS"

  cd "$SCRIPT_DIR"
}

# Wire EKS outputs into IAM-IRSA tfvars

wire_iam_irsa_inputs() {
  log "Wiring EKS outputs into IAM-IRSA module's terraform.tfvars..."

  local oidc_arn
  local oidc_url

  oidc_arn=$(jq -r '.oidc_provider_arn.value' "$EKS_OUTPUTS")
  oidc_url=$(jq -r '.oidc_provider_url.value' "$EKS_OUTPUTS")

  if [[ -z "$oidc_arn" || "$oidc_arn" == "null" ]]; then
    error "Failed to extract oidc_provider_arn from EKS outputs"
    exit 1
  fi

  cat > "$IAM_IRSA_DIR/terraform.tfvars" <<EOF
region       = "ap-south-1"
environment  = "dev"
cluster_name = "atlas-eks-dev"

# Wired automatically by bootstrap.sh from eks module outputs.
oidc_provider_arn = "${oidc_arn}"
oidc_provider_url = "${oidc_url}"
EOF

  success "IAM-IRSA terraform.tfvars updated"
}

# Apply IAM-IRSA module

apply_iam_irsa() {
  log "═══ Step 3/3 — Applying IAM-IRSA module ═══"
  cd "$IAM_IRSA_DIR"

  if [[ ! -d .terraform ]]; then
    log "Initializing IAM-IRSA module..."
    terraform init -input=false
  fi

  terraform apply -auto-approve -input=false

  success "IAM-IRSA applied"
  cd "$SCRIPT_DIR"
}

# Configure kubectl to talk to the new EKS cluster

configure_kubectl() {
  log "Configuring kubectl..."

  local cluster_name
  cluster_name=$(jq -r '.cluster_name.value' "$EKS_OUTPUTS")

  aws eks update-kubeconfig \
    --region ap-south-1 \
    --name "$cluster_name" \
    --alias atlas-eks-dev

  if kubectl --context atlas-eks-dev get nodes >/dev/null 2>&1; then
    success "kubectl configured. Context: atlas-eks-dev"
  else
    warn "kubectl configured but couldn't list nodes. Try: kubectl --context atlas-eks-dev get nodes"
  fi
}

# Final summary

print_summary() {
  local cluster_name
  local cluster_endpoint
  cluster_name=$(jq -r '.cluster_name.value' "$EKS_OUTPUTS")
  cluster_endpoint=$(jq -r '.cluster_endpoint.value' "$EKS_OUTPUTS")

  echo
  echo "═══════════════════════════════════════════════════════════════"
  success "Bootstrap complete!"
  echo "═══════════════════════════════════════════════════════════════"
  echo
  echo "  Cluster:    $cluster_name"
  echo "  Endpoint:   $cluster_endpoint"
  echo "  Region:     ap-south-1"
  echo "  kubectl:    kubectl --context atlas-eks-dev get nodes"
  echo
  warn "Cost: ~\$0.20/hour while running."
  warn "Run ./destroy.sh when done."
  echo
}

# Main

main() {
  preflight
  confirm_apply
  apply_vpc
  wire_eks_inputs
  apply_eks
  wire_iam_irsa_inputs
  apply_iam_irsa
  configure_kubectl
  print_summary
}

main "$@"
