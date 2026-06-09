#!/usr/bin/env bash
set -euo pipefail

# Parameterized k6 load test driver.
#
# Usage:
#   ./run.sh                                            # dev (default)
#   NAMESPACE=three-tier-staging \
#     HOST_HEADER=backend-staging.atlas.local \
#     ./run.sh                                          # staging
#   NAMESPACE=three-tier-prod \
#     HOST_HEADER=backend-prod.atlas.local \
#     ./run.sh                                          # prod

NAMESPACE="${NAMESPACE:-three-tier-dev}"
HOST_HEADER="${HOST_HEADER:-backend.atlas.local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Running k6 load test"
echo "    Namespace:   ${NAMESPACE}"
echo "    Host header: ${HOST_HEADER}"
echo ""

echo "[1/4] Creating/updating ConfigMap with k6 script..."
kubectl create configmap k6-backend-canary \
  --from-file="${SCRIPT_DIR}/backend-canary-load.js" \
  -n "${NAMESPACE}" \
  --dry-run=client -o yaml \
  | kubectl apply -f -

echo "[2/4] Deleting old job if it exists..."
kubectl delete job k6-backend-canary-load -n "${NAMESPACE}" --ignore-not-found

echo "[3/4] Applying Job with HOST_HEADER substituted..."
sed "s|PLACEHOLDER_SET_BY_RUN_SH|${HOST_HEADER}|g" \
  "${SCRIPT_DIR}/backend-canary-load-job.yaml" \
  | kubectl apply -n "${NAMESPACE}" -f -

echo "[4/4] Waiting for pod to start, then streaming logs..."
sleep 3
POD=$(kubectl get pods -n "${NAMESPACE}" -l app=k6-load-test \
  -o jsonpath='{.items[0].metadata.name}' --sort-by=.metadata.creationTimestamp \
  | awk '{print $NF}')
echo "Pod: ${POD}"
kubectl logs -n "${NAMESPACE}" "${POD}" -f
