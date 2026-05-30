# NGINX Canary Traffic Split — Demonstrated 2026-05-30

End-to-end progressive delivery verified working on Atlas backend.

## Setup
- Argo Rollouts controller managing backend (Rollout resource, 4 replicas)
- NGINX ingress controller as traffic router
- backend-svc (stable) + backend-svc-canary (canary) Services
- backend Ingress at backend.atlas.local (NGINX clones it as canary
  Ingress mid-rollout)
- Rollout strategy: setWeight 25 -> pause -> 50 -> 30s -> 75 -> 30s -> 100

## Trigger
Changed args text in Git from `"version":"v1"` to `"version":"v2"`,
committed, pushed. ArgoCD applied the spec change.

## Observed Behavior
- At setWeight 25 (paused for manual promotion):
  curl through ingress (40 requests): 30 v1 / 10 v2 — exact 25% canary
- After `kubectl argo rollouts promote backend`:
  Step advanced through 50% and 75% (auto-timed 30s pauses), then 100%
- At completion: 40/40 requests served v2, zero v1
- ArgoCD: Synced / Healthy, revision:1 ReplicaSet scaled to 0

## Why This Matters
NGINX splits HTTP requests by exact weight (canary-weight annotation on
a cloned Ingress), not by pod ratio. With 4 stable + 1 canary pod,
pod-ratio would give 20%; NGINX gave 25% exactly.

## Note On ArgoCD Mid-Canary Status
During the canary, ArgoCD shows `Suspended` (paused at gate) and
`OutOfSync` (live state differs from Git because the canary RS exists
and the canary-cloned Ingress is dynamic). Both resolve to Healthy/Synced
once the rollout completes. This is expected, not a sync failure.

## Files
- gitops/workloads/three-tier-app/base/backend-rollout.yaml
- gitops/workloads/three-tier-app/base/backend-service.yaml
- gitops/workloads/three-tier-app/base/backend-ingress.yaml
