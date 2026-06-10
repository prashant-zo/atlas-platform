#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-atlas-eks-dev}"
REGION="${AWS_REGION:-ap-south-1}"

ARGOCD_APP_WAIT=60
CNPG_CLEANUP_WAIT=180
STATEFULSET_WAIT=120
EBS_VOLUME_WAIT=600

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

step()   { echo -e "${BLUE}==>${NC} $*"; }
detail() { echo "    $*"; }
ok()     { echo -e "    ${GREEN}✓${NC} $*"; }
warn()   { echo -e "    ${YELLOW}!${NC} $*"; }
err()    { echo -e "    ${RED}✗${NC} $*"; }

ebs_count() {
  aws ec2 describe-volumes \
    --region "$REGION" \
    --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" \
    --query 'length(Volumes)' \
    --output text 2>/dev/null || echo "0"
}

ebs_count_state() {
  local state="$1"
  aws ec2 describe-volumes \
    --region "$REGION" \
    --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" \
              "Name=status,Values=$state" \
    --query 'length(Volumes)' \
    --output text 2>/dev/null || echo "0"
}

echo ""
step "Pre-destroy cleanup for cluster: $CLUSTER_NAME (region: $REGION)"
echo ""

# Phase 0: cluster reachability & context safety guard
if ! kubectl get nodes &>/dev/null; then
  warn "Cannot reach cluster via kubectl. Skipping Kubernetes layers."
  warn "Proceeding directly to AWS verification + safety-net cleanup."
  K8S_REACHABLE=false
else
  CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "unknown")
  if [[ "$CURRENT_CONTEXT" != *"$CLUSTER_NAME"* ]]; then
    err "Safety abort: Current kube-context ($CURRENT_CONTEXT) does not match target cluster ($CLUSTER_NAME)."
    err "Aborting to prevent destructive operations against the wrong environment."
    exit 1
  fi
  K8S_REACHABLE=true
fi

if [[ "$K8S_REACHABLE" == "true" ]]; then

# Phase 1: Delete ArgoCD Applications
step "Phase 1: Deleting ArgoCD workload Applications..."
APPS=$(kubectl get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E "^three-tier-" || echo "")

if [[ -n "$APPS" ]]; then
  echo "$APPS" | while read -r app; do
    [[ -z "$app" ]] && continue
    detail "Deleting application argocd/$app"
    kubectl delete application "$app" -n argocd --wait=false 2>/dev/null || true
  done

  ELAPSED=0
  while [[ $ELAPSED -lt $ARGOCD_APP_WAIT ]]; do
    # Execute API call separately to prevent pipefail returning false 0s on timeouts
    RAW_OUT=$(kubectl get applications -n argocd --no-headers 2>/dev/null || echo "API_ERROR")
    if [[ "$RAW_OUT" == *"API_ERROR"* ]]; then
      detail "${ELAPSED}s: API unreachable, retrying..."
    else
      REMAINING=$(echo "$RAW_OUT" | grep -E "^three-tier-" | wc -l | tr -d ' ' || true)
      if [[ "$REMAINING" -eq 0 ]]; then
        ok "All workload Applications deleted."
        break
      fi
      detail "${ELAPSED}s: $REMAINING Application(s) still present..."
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
  done
else
  ok "No workload Applications found."
fi
echo ""

# Phase 2: Delete CNPG Cluster CRs
step "Phase 2: Deleting CNPG Cluster CRs (operator-driven teardown)..."
CLUSTERS=$(kubectl get cluster.postgresql.cnpg.io --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")

if [[ -n "$CLUSTERS" ]]; then
  echo "$CLUSTERS" | while IFS='/' read -r ns name; do
    [[ -z "$ns" || -z "$name" ]] && continue
    detail "Deleting CNPG cluster $ns/$name"
    kubectl delete cluster.postgresql.cnpg.io "$name" -n "$ns" --wait=false 2>/dev/null || true
  done

  ELAPSED=0
  while [[ $ELAPSED -lt $CNPG_CLEANUP_WAIT ]]; do
    RAW_OUT=$(kubectl get cluster.postgresql.cnpg.io --all-namespaces --no-headers 2>/dev/null || echo "API_ERROR")
    if [[ "$RAW_OUT" == *"API_ERROR"* ]]; then
      detail "${ELAPSED}s: API unreachable, retrying..."
    else
      REMAINING=$(echo "$RAW_OUT" | wc -l | tr -d ' ' || true)
      if [[ "$REMAINING" -eq 0 ]]; then
        ok "CNPG operator finished teardown."
        break
      fi
      detail "${ELAPSED}s: $REMAINING CNPG cluster(s) still present..."
    fi
    sleep 15
    ELAPSED=$((ELAPSED + 15))
  done
else
  ok "No CNPG clusters found."
fi
echo ""

# Phase 3: Delete non-CNPG StatefulSets
step "Phase 3: Deleting non-CNPG StatefulSets (MinIO, Prometheus, Loki)..."
SS_LIST=$(kubectl get statefulset --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -vE "^(kube-system|argocd|cnpg-system|ingress-nginx|argo-rollouts)/" || echo "")

if [[ -n "$SS_LIST" ]]; then
  echo "$SS_LIST" | while IFS='/' read -r ns name; do
    [[ -z "$ns" || -z "$name" ]] && continue
    detail "Deleting statefulset $ns/$name"
    kubectl delete statefulset "$name" -n "$ns" --wait=false 2>/dev/null || true
  done

  ELAPSED=0
  while [[ $ELAPSED -lt $STATEFULSET_WAIT ]]; do
    RAW_OUT=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null || echo "API_ERROR")
    if [[ "$RAW_OUT" == *"API_ERROR"* ]]; then
      detail "${ELAPSED}s: API unreachable, retrying..."
    else
      STORAGE_PODS=$(echo "$RAW_OUT" | awk '{print $1, $2}' | grep -E "(minio-[0-9]|loki-[0-9]|prometheus-kps-)" | wc -l | tr -d ' ' || true)
      if [[ "$STORAGE_PODS" -eq 0 ]]; then
        ok "All storage StatefulSet pods terminated."
        break
      fi
      detail "${ELAPSED}s: $STORAGE_PODS storage pod(s) still present..."
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
  done
else
  ok "No non-system StatefulSets found."
fi
echo ""

# Phase 3.5: LoadBalancer & Ingress Cleanup
step "Phase 3.5: Deleting Ingresses and LoadBalancer Services (ALB/NLB cleanup)..."
kubectl delete ingress --all --all-namespaces --wait=false 2>/dev/null || true

LB_SVC=$(kubectl get svc --all-namespaces -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")
if [[ -n "$LB_SVC" ]]; then
  echo "$LB_SVC" | while IFS='/' read -r ns name; do
    [[ -z "$ns" || -z "$name" ]] && continue
    detail "Deleting LoadBalancer Service $ns/$name"
    kubectl delete svc "$name" -n "$ns" --wait=false 2>/dev/null || true
  done
  detail "Waiting 60s for AWS Load Balancers to detach and delete..."
  sleep 60
else
  ok "No LoadBalancer Services found."
fi
echo ""

fi  # end K8S_REACHABLE

# Phase 4: Wait for EBS volumes to actually delete in AWS
step "Phase 4: Waiting for EBS volumes to be deleted in AWS (max ${EBS_VOLUME_WAIT}s)..."
INITIAL=$(ebs_count)
IN_USE=$(ebs_count_state in-use)
AVAILABLE=$(ebs_count_state available)
DELETING=$(ebs_count_state deleting)
detail "Initial state: Total: $INITIAL  (in-use: $IN_USE, available: $AVAILABLE, deleting: $DELETING)"

ELAPSED=0
LAST_REPORTED=-1
while [[ $ELAPSED -lt $EBS_VOLUME_WAIT ]]; do
  COUNT=$(ebs_count)

  if [[ "$COUNT" -eq 0 ]]; then
    ok "All cluster-tagged EBS volumes deleted."
    break
  fi

  if [[ "$COUNT" != "$LAST_REPORTED" ]]; then
    IN_USE=$(ebs_count_state in-use)
    AVAILABLE=$(ebs_count_state available)
    DELETING=$(ebs_count_state deleting)
    detail "${ELAPSED}s: $COUNT volume(s) remaining (in-use: $IN_USE, available: $AVAILABLE, deleting: $DELETING)"
    LAST_REPORTED="$COUNT"
  fi
  sleep 15
  ELAPSED=$((ELAPSED + 15))
done
echo ""

# Phase 5: Safety net recovery operations
FINAL_COUNT=$(ebs_count)
if [[ "$FINAL_COUNT" != "0" ]]; then
  warn "═══ Safety net engaging — normal teardown did not complete ═══"
  warn "$FINAL_COUNT volume(s) still present after Phase 4."
  step "Phase 5: Safety-net cleanup (recovery operations)..."

  IN_USE_VOLS=$(aws ec2 describe-volumes --region "$REGION" --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" "Name=status,Values=in-use" --query 'Volumes[*].VolumeId' --output text 2>/dev/null || echo "")
  if [[ -n "$IN_USE_VOLS" ]]; then
    warn "Force-detaching in-use volumes (recovery mode):"
    echo "$IN_USE_VOLS" | tr '\t' '\n' | while read -r vol_id; do
      [[ -z "$vol_id" ]] && continue
      detail "force-detach $vol_id"
      aws ec2 detach-volume --region "$REGION" --volume-id "$vol_id" --force >/dev/null 2>&1 || true
    done
    sleep 30
  fi

  ALL_VOLS=$(aws ec2 describe-volumes --region "$REGION" --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" --query 'Volumes[*].VolumeId' --output text 2>/dev/null || echo "")
  if [[ -n "$ALL_VOLS" ]]; then
    warn "Force-deleting remaining volumes (recovery mode):"
    echo "$ALL_VOLS" | tr '\t' '\n' | while read -r vol_id; do
      [[ -z "$vol_id" ]] && continue
      detail "delete $vol_id"
      aws ec2 delete-volume --region "$REGION" --volume-id "$vol_id" >/dev/null 2>&1 || true
    done
    sleep 15
  fi

  POST=$(ebs_count)
  if [[ "$POST" -eq 0 ]]; then
    ok "Safety net cleared all volumes."
  else
    err "$POST volume(s) STILL present after safety net."
    err "Manual investigation required."
    exit 1
  fi
  echo ""
fi

# Phase 6: Snapshot cleanup
step "Phase 6: Checking for orphan EBS snapshots..."
ORPHAN_SNAPS=$(aws ec2 describe-snapshots --region "$REGION" --owner-ids self --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" --query 'Snapshots[*].SnapshotId' --output text 2>/dev/null || echo "")
if [[ -n "$ORPHAN_SNAPS" ]]; then
  echo "$ORPHAN_SNAPS" | tr '\t' '\n' | while read -r snap_id; do
    [[ -z "$snap_id" ]] && continue
    detail "Deleting $snap_id"
    aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$snap_id" >/dev/null 2>&1 || true
  done
else
  ok "No orphan snapshots."
fi
echo ""

step "Pre-destroy cleanup complete. AWS storage and LB layers clean."
echo ""
