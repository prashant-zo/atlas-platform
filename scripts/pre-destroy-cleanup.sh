#!/usr/bin/env bash
# Pre-destroy hook: clean up Kubernetes-managed AWS resources that survive
# `terraform destroy` because they're outside Terraform's state.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-atlas-eks-dev}"
REGION="${AWS_REGION:-ap-south-1}"

EBS_WAIT_MAX_SECONDS=300       # 5 minutes
EBS_WAIT_POLL_INTERVAL=15      # check every 15s

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

# Step 5: Delete all PVCs (triggers EBS CSI to delete volumes)
echo ""
echo "==> Deleting PVCs (triggers EBS CSI to delete underlying volumes)..."
NAMESPACES=$(kubectl get ns -o jsonpath='{.items[*].metadata.name}')
TOTAL_PVCS=0
for ns in $NAMESPACES; do
  if [[ "$ns" =~ ^(kube-system|kube-public|kube-node-lease|default)$ ]]; then
    continue
  fi

  PVCS=$(kubectl get pvc -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
  if [[ -n "$PVCS" ]]; then
    PVC_COUNT=$(echo "$PVCS" | wc -w | tr -d ' ')
    TOTAL_PVCS=$((TOTAL_PVCS + PVC_COUNT))
    echo "  Deleting $PVC_COUNT PVCs in $ns: $PVCS"
    for pvc in $PVCS; do
      kubectl delete pvc "$pvc" -n "$ns" --wait=false || true
    done
  fi
done
echo "  Total PVCs marked for deletion: $TOTAL_PVCS"

# Step 6: Also delete PVs explicitly. With reclaimPolicy=Delete this is
# usually automatic, but stuck finalizers can leave PVs Released and
# the underlying EBS volumes orphaned. We patch finalizers off to force
# cleanup.
echo ""
echo "==> Removing finalizers from any stuck PVs..."
STUCK_PVS=$(kubectl get pv -o jsonpath='{range .items[?(@.status.phase=="Released")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")
if [[ -n "$STUCK_PVS" ]]; then
  echo "$STUCK_PVS" | while read -r pv; do
    [[ -z "$pv" ]] && continue
    echo "  Patching finalizers off PV: $pv"
    kubectl patch pv "$pv" -p '{"metadata":{"finalizers":null}}' --type=merge || true
  done
else
  echo "  No stuck Released PVs."
fi

# Step 7: Poll AWS until volumes are gone OR until we hit max wait time.
echo ""
echo "==> Polling AWS for EBS volume deletion (max ${EBS_WAIT_MAX_SECONDS}s)..."
ELAPSED=0
while [[ $ELAPSED -lt $EBS_WAIT_MAX_SECONDS ]]; do
  REMAINING_COUNT=$(aws ec2 describe-volumes \
    --region "$REGION" \
    --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" \
    --query 'length(Volumes)' \
    --output text 2>/dev/null || echo "0")

  if [[ "$REMAINING_COUNT" == "0" ]]; then
    echo "  Clean. All cluster-tagged volumes are gone."
    break
  fi

  echo "  ${ELAPSED}s: $REMAINING_COUNT cluster-tagged volume(s) still present, waiting..."
  sleep $EBS_WAIT_POLL_INTERVAL
  ELAPSED=$((ELAPSED + EBS_WAIT_POLL_INTERVAL))
done

# Step 8: Force-delete any orphans that survived.
echo ""
echo "==> Force-deleting any remaining orphan volumes via AWS CLI..."
ORPHANS=$(aws ec2 describe-volumes \
  --region "$REGION" \
  --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" \
            "Name=status,Values=available" \
  --query 'Volumes[*].VolumeId' \
  --output text)
if [[ -n "$ORPHANS" ]]; then
  ORPHAN_COUNT=$(echo "$ORPHANS" | tr '\t' '\n' | wc -l | tr -d ' ')
  echo "  Found $ORPHAN_COUNT orphan volume(s) — force-deleting..."
  echo "$ORPHANS" | tr '\t' '\n' | while read -r vol_id; do
    [[ -z "$vol_id" ]] && continue
    echo "    Deleting $vol_id"
    aws ec2 delete-volume --region "$REGION" --volume-id "$vol_id" || \
      echo "    WARNING: failed to delete $vol_id (may already be deleting)"
  done

  # Brief wait for the force-deletes to register, then re-verify.
  sleep 10
  POST_CHECK=$(aws ec2 describe-volumes \
    --region "$REGION" \
    --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" \
              "Name=status,Values=available" \
    --query 'length(Volumes)' \
    --output text 2>/dev/null || echo "0")
  if [[ "$POST_CHECK" != "0" ]]; then
    echo "  WARNING: $POST_CHECK volume(s) still in 'available' state."
    echo "  Manual cleanup may be needed:"
    echo "    aws ec2 describe-volumes --region $REGION --filters Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned"
  else
    echo "  All orphans force-deleted."
  fi
else
  echo "  No orphan volumes found."
fi

# Step 9: Also check for orphan snapshots — same pattern, less common.
echo ""
echo "==> Checking for orphan EBS snapshots..."
ORPHAN_SNAPS=$(aws ec2 describe-snapshots \
  --region "$REGION" --owner-ids self \
  --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" \
  --query 'Snapshots[*].SnapshotId' \
  --output text)
if [[ -n "$ORPHAN_SNAPS" ]]; then
  echo "  Found orphan snapshots — deleting:"
  echo "$ORPHAN_SNAPS" | tr '\t' '\n' | while read -r snap_id; do
    [[ -z "$snap_id" ]] && continue
    echo "    Deleting $snap_id"
    aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$snap_id" || true
  done
else
  echo "  No orphan snapshots."
fi

echo ""
echo "==> Pre-destroy cleanup complete."
echo "Now run: cd infrastructure/terraform && ./destroy.sh"
