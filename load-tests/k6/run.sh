#!/usr/bin/env bash
set -euo pipefail

NAMESPACE=three-tier-dev
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[1/4] Creating/updating ConfigMap with k6 script..."
kubectl create configmap k6-backend-canary \
  --from-file="${SCRIPT_DIR}/backend-canary-load.js" \
  -n "${NAMESPACE}" \
  --dry-run=client -o yaml \
  | kubectl apply -f -

echo "[2/4] Deleting old job if it exists..."
kubectl delete job k6-backend-canary-load -n "${NAMESPACE}" --ignore-not-found

echo "[3/4] Creating Job..."
kubectl apply -f "${SCRIPT_DIR}/backend-canary-load-job.yaml"

echo "[4/4] Waiting for pod to start, then streaming logs..."
sleep 3
POD=$(kubectl get pods -n "${NAMESPACE}" -l app=k6-load-test \
  -o jsonpath='{.items[0].metadata.name}' --sort-by=.metadata.creationTimestamp \
  | awk '{print $NF}')
echo "Pod: ${POD}"
kubectl logs -n "${NAMESPACE}" "${POD}" -f
