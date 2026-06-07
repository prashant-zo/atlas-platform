#!/usr/bin/env bash

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

# Cluster detection — returns "kind" or "eks" via stdout

detect_cluster_type() {
  local ctx
  ctx=$(kubectl config current-context 2>/dev/null || echo "")

  case "$ctx" in
    kind-atlas)
      echo "kind"
      ;;
    atlas-eks-*)
      echo "eks"
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

# Preflight — verifies cluster is reachable and is one we know

require_cluster() {
  command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"
  command -v helm    >/dev/null 2>&1 || fail "helm not found (brew install helm)"

  kubectl cluster-info >/dev/null 2>&1 \
    || fail "No cluster reachable — run 'make up' (kind) or './infrastructure/terraform/bootstrap.sh' (EKS) first"

  local ctx cluster_type
  ctx=$(kubectl config current-context)
  cluster_type=$(detect_cluster_type)

  case "$cluster_type" in
    kind|eks)
      log "Cluster context: ${ctx} (type: ${cluster_type})"
      ;;
    unknown)
      fail "Unknown cluster context: ${ctx}. Expected 'kind-atlas' or 'atlas-eks-*'."
      ;;
  esac

  # EKS-only: verify AWS CLI and credentials
  if [[ "$cluster_type" == "eks" ]]; then
    command -v aws >/dev/null 2>&1 || fail "aws CLI not found (brew install awscli)"
    command -v jq  >/dev/null 2>&1 || fail "jq not found (brew install jq)"

    aws sts get-caller-identity >/dev/null 2>&1 \
      || fail "AWS credentials not configured. Run: aws configure --profile atlas"

    local arn
    arn=$(aws sts get-caller-identity --query Arn --output text)
    if [[ "$arn" == *":root" ]]; then
      fail "Refusing to install as root. Use atlas-admin IAM user."
    fi
    success "AWS auth: ${arn}"
  fi
}

# EKS-only: install AWS Load Balancer Controller with IRSA

install_eks_prerequisites() {
  section "AWS Load Balancer Controller (EKS only)"

  # Read IRSA role ARN from the iam-irsa Terraform module's state
  local terraform_dir="${REPO_ROOT}/infrastructure/terraform/iam-irsa"
  [[ -d "$terraform_dir" ]] || fail "IAM-IRSA module directory not found: ${terraform_dir}"

  local role_arn
  role_arn=$(cd "$terraform_dir" && terraform output -raw load_balancer_controller_role_arn 2>/dev/null || echo "")

  if [[ -z "$role_arn" ]]; then
    fail "Could not read load_balancer_controller_role_arn from Terraform. Did iam-irsa module apply succeed?"
  fi

  log "IRSA role: ${role_arn}"

  # Add the AWS EKS chart repo (idempotent)
  if ! helm repo list 2>/dev/null | grep -q '^eks\s'; then
    log "Adding AWS EKS Helm repo..."
    helm repo add eks https://aws.github.io/eks-charts >/dev/null
  fi
  helm repo update eks >/dev/null

  # Get cluster name from current context (atlas-eks-dev → atlas-eks-dev)
  local cluster_name
  cluster_name=$(kubectl config current-context)

  # Install/upgrade AWS Load Balancer Controller via Helm
  # Annotations on the SA must point to the IRSA role we created in Terraform
  # Read VPC ID and region from VPC module's Terraform state
  # The ALB controller needs these explicitly — IMDS auto-discovery is
  # blocked by default in EKS 1.30+ pod networking.
  local vpc_dir="${REPO_ROOT}/infrastructure/terraform/vpc"
  local vpc_id region
  vpc_id=$(cd "$vpc_dir" && terraform output -raw vpc_id 2>/dev/null || echo "")
  region=$(cd "$vpc_dir" && terraform output -raw region 2>/dev/null || echo "ap-south-1")

  if [[ -z "$vpc_id" ]]; then
    fail "Could not read vpc_id from Terraform. Did vpc module apply succeed?"
  fi

  log "VPC ID: ${vpc_id}, Region: ${region}"
  log "Installing AWS Load Balancer Controller (cluster=${cluster_name})..."
  helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    --namespace kube-system \
    --set "clusterName=${cluster_name}" \
    --set "vpcId=${vpc_id}" \
    --set "region=${region}" \
    --set serviceAccount.create=true \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${role_arn}" \
    --wait \
    --timeout 5m

  success "AWS Load Balancer Controller installed"
}

# Prometheus CRDs — required by ArgoCD chart's ServiceMonitor resources

install_prometheus_crds() {
  section "Prometheus CRDs (required by ArgoCD ServiceMonitors)"

  local crd_version="v0.79.2"   # Matches kube-prometheus-stack 65.x
  local crd_base="https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/${crd_version}/example/prometheus-operator-crd"

  local crds=(
    "monitoring.coreos.com_servicemonitors.yaml"
    "monitoring.coreos.com_podmonitors.yaml"
    "monitoring.coreos.com_prometheusrules.yaml"
  )

  for crd in "${crds[@]}"; do
    log "Applying ${crd}..."
    kubectl apply --server-side -f "${crd_base}/${crd}" >/dev/null
  done

  success "Prometheus CRDs installed"
}

# ArgoCD install — same on both kind and EKS

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

# Summary — differs slightly per cluster type

print_summary() {
  local cluster_type="$1"

  echo
  success "Platform install complete"
  echo

  if [[ "$cluster_type" == "kind" ]]; then
    echo "  Next:  make argocd       # bring up ArgoCD UI and CLI session"
  else
    echo "  ArgoCD installed. Next steps for EKS:"
    echo ""
    echo "    1. Apply the root App-of-Apps:"
    echo "         make bootstrap-gitops"
    echo ""
    echo "    2. Bring up ArgoCD UI via port-forward:"
    echo "         make argocd"
    echo ""
    echo "    3. (Optional) Watch sync progress:"
    echo "         watch -n 2 argocd app list"
    echo ""
    echo "  Cluster cost: ~\$0.20/hour while running."
    echo "  Don't forget to destroy: ./infrastructure/terraform/destroy.sh"
  fi
}

# Main

main() {
  log "═══ Atlas platform-install ═══"
  require_cluster

  local cluster_type
  cluster_type=$(detect_cluster_type)

  # EKS-specific prerequisites before ArgoCD
  if [[ "$cluster_type" == "eks" ]]; then
    install_eks_prerequisites
  fi

  install_prometheus_crds

  install_argocd
  print_summary "$cluster_type"
}

main "$@"
