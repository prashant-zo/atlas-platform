#!/usr/bin/env bash
# Pre-destroy hook: clean up Kubernetes-managed AWS resources that survive
# `terraform destroy` because they're outside Terraform's state.
#
# Run this BEFORE `cd infrastructure/terraform && ./destroy.sh`.
#
# Why this exists:
# - EBS CSI driver creates EBS volumes from PVCs (dynamic provisioning)
# - AWS Load Balancer Controller creates ALBs/NLBs from Service/Ingress
# - These resources are tagged but Terraform doesn't know about them
# - When the cluster is destroyed, the controllers die before cleanup
# - Result: orphaned AWS resources that accrue cost
#
# This script forces clean deletion of those resources first, then waits for
# the controllers to release the underlying AWS objects.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-atlas-eks-dev}"
REGION="${AWS_REGION:-ap-south-1}"

echo "==> Pre-destroy cleanup for cluster: $CLUSTER_NAME (region: $REGION)"
echo ""

# Step 1: Verify we can reach the cluster
if ! kubectl get nodes &>/dev/null; then
  echo "ERROR: cannot reach cluster $CLUSTER_NAME via kubectl"
  echo "Run: aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION"
  exit 1
fi

# Step 2: Delete all Services of type=LoadBalancer (releases ALBs/NLBs)
echo "==> Deleting LoadBalancer Services (releases ALBs/NLBs)..."
LB_SVCS=$(kubectl get svc --all-namespaces \
  -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')
if [[ -n "$LB_SVCS" ]]; then
  echo "$LB_SVCS" | while IFS='/' read -r ns name; do
    [[ -z "$ns" || -z "$name" ]] && continue
    echo "  Deleting svc $ns/$name"
    kubectl delete svc "$name" -n "$ns" --wait=true --timeout=120s || true
  done
else
  echo "  No LoadBalancer services to delete."
fi

# Step 3: Delete all Ingresses (releases ALBs from AWS LB Controller)
echo ""
echo "==> Deleting Ingresses (releases ALBs)..."
INGRESSES=$(kubectl get ingress --all-namespaces \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')
if [[ -n "$INGRESSES" ]]; then
  echo "$INGRESSES" | while IFS='/' read -r ns name; do
    [[ -z "$ns" || -z "$name" ]] && continue
    echo "  Deleting ingress $ns/$name"
    kubectl delete ingress "$name" -n "$ns" --wait=true --timeout=120s || true
  done
else
  echo "  No Ingresses to delete."
fi

# Step 4: Wait for ALBs to actually be deleted in AWS
echo ""
echo "==> Waiting 60s for AWS LB Controller to delete ALBs..."
sleep 60

# Step 5: Delete all PVCs in workload namespaces (triggers EBS CSI to delete volumes)
echo ""
echo "==> Deleting PVCs (triggers EBS CSI to delete underlying volumes)..."
NAMESPACES=$(kubectl get ns -o jsonpath='{.items[*].metadata.name}')
for ns in $NAMESPACES; do
  # Skip system namespaces — they shouldn't have PVCs but skip just in case
  if [[ "$ns" =~ ^(kube-system|kube-public|kube-node-lease|default)$ ]]; then
    continue
  fi

  PVCS=$(kubectl get pvc -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
  if [[ -n "$PVCS" ]]; then
    echo "  Deleting PVCs in $ns: $PVCS"
    for pvc in $PVCS; do
      kubectl delete pvc "$pvc" -n "$ns" --wait=false || true
    done
  fi
done

# Step 6: Wait for EBS volumes to actually be deleted
echo ""
echo "==> Waiting 90s for EBS CSI to delete underlying volumes..."
sleep 90

# Step 7: Sanity check — list any remaining cluster-tagged available volumes
echo ""
echo "==> Checking for remaining orphaned volumes..."
REMAINING=$(aws ec2 describe-volumes \
  --region "$REGION" \
  --filters "Name=status,Values=available" \
            "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" \
  --query 'Volumes[*].VolumeId' \
  --output text)
if [[ -n "$REMAINING" ]]; then
  echo "  WARNING: still found orphaned volumes:"
  echo "  $REMAINING"
  echo "  These will need manual cleanup if 'terraform destroy' does not delete them."
else
  echo "  Clean. No orphaned volumes detected."
fi

echo ""
echo "==> Pre-destroy cleanup complete."
echo "Now run: cd infrastructure/terraform && ./destroy.sh"
