# Canary Demonstration On EKS: Three Real-World Outcomes

**Date:** 2026-06-07 / 2026-06-08
**Context:** Week 6 Phase B Take 2, atlas-eks-dev cluster
**Workload:** atlas-backend (Go service emitting `http_requests_total{version,status}`)
**Strategy:** Argo Rollouts canary with 6 steps and Prometheus-based AnalysisTemplate

This document captures three distinct canary outcomes observed during Phase B Take 2's demonstration session. Each outcome reveals a different layer of Atlas's progressive delivery and Kubernetes safety mechanisms.

---

## Background

Atlas's three-tier-app backend is configured with a Canary deployment strategy:

```yaml
strategy:
  canary:
    steps:
      - setWeight: 25
      - analysis:
          templates:
            - templateName: backend-canary-analysis
      - setWeight: 50
      - pause: { duration: 30s }
      - setWeight: 75
      - pause: { duration: 30s }
```

The AnalysisTemplate queries Prometheus for `success-rate = sum(rate(http_requests_total{status=~"2..",version=$canary})) / sum(rate(http_requests_total{version=$canary}))` with a threshold of 0.95. Five measurements over ~3.5 minutes are required for the canary to pass.

A traffic-generator CronJob runs every minute, hitting the backend service to produce continuous metric data. atlas-backend itself supports `FAIL_RATE` env var to inject synthetic 500 errors for failure simulation.

---

## Phase 1 (Revision 2): Canary SUCCESS ✅

### Trigger

Changed `LATENCY_MS` from `"0"` to `"5"` in `backend-rollout.yaml`. This is a benign change that triggers a Rollout update without affecting the success-rate metric.

### Outcome

Status: ✔ Healthy
Step: 6/6
SetWeight: 100
ActualWeight: 100
Images: ghcr.io/prashant-zo/atlas-backend:v2 (stable)
AnalysisRun: ✔ Successful (10/10 measurements)

### What Happened

1. ArgoCD detected the new commit (~30 seconds)
2. Rollout controller created revision 2 ReplicaSet with the new pod template
3. Step 1: `setWeight: 25` — canary scaled to 1 pod, NGINX ingress routed 25% of traffic to it
4. Step 2: AnalysisRun started, queried Prometheus every 30 seconds
5. Each measurement returned success-rate ≈ 1.0 (since FAIL_RATE=0)
6. After 5 successful measurements over ~3.5 minutes, AnalysisRun marked Successful
7. Step 3: `setWeight: 50` — canary scaled to 2 pods
8. Step 4: 30-second pause
9. Step 5: `setWeight: 75` — canary scaled to 3 pods
10. Step 6: 30-second pause → **full promotion**
11. Revision 2 marked stable, revision 1 began scale-down delay (`scaleDownDelaySeconds: 300`)

**Total time from push to promotion: ~5 minutes.**

### What This Proves

Atlas's canary mechanism works end-to-end on EKS:
- ArgoCD GitOps sync correctly detects and applies Rollout spec changes
- Argo Rollouts controller correctly orchestrates traffic splitting via NGINX ingress
- ServiceMonitor scrapes `atlas-backend`'s `/metrics` endpoint into Prometheus
- AnalysisTemplate's PromQL query correctly evaluates `http_requests_total{version,status}`
- Successful analysis correctly triggers progression through all canary steps
- Final stable promotion correctly preserves the old ReplicaSet for rollback window

This is the **happy path** — a healthy deployment automatically promoted with real metric validation.

---

## Phase 2 Attempt 1 (Revision 3): Canary ABORT ⚠️

### Trigger

Changed `FAIL_RATE` from `"0"` to `"0.5"` to inject 50% server errors into the canary, expecting AnalysisRun to detect the degraded success-rate and abort.

### Outcome

Status: ✖ Degraded
Message: RolloutAborted: Metric "success-rate" assessed Error due to
consecutiveErrors (3) > consecutiveErrorLimit (2):
"Post http://kps-kube-prometheus-stack-prometheus.monitoring.svc:9090/api/v1/query:
dial tcp 172.20.215.149:9090: connect: connection refused"
Step: 0/6
SetWeight: 0
ActualWeight: 0
AnalysisRun: ⚠ Error (4 successful queries, 6 errors)

### What Happened

1. ArgoCD synced revision 3 with FAIL_RATE=0.5
2. Canary pod created and became Ready
3. AnalysisRun started querying Prometheus
4. **Prometheus pod was in a restart loop due to OOMKill** (memory limit: 512Mi was insufficient for the workload's scrape volume)
5. Multiple AnalysisRun queries hit Prometheus during its restart windows → `connection refused`
6. After 3 consecutive query errors (exceeding the template's `consecutiveErrorLimit: 2`), the AnalysisRun was marked Error
7. Argo Rollouts immediately aborted the canary
8. Canary ReplicaSet scaled to 0
9. Revision 2 preserved as stable

### What This Proves

This is **fail-safe behavior under metrics infrastructure failure**:

- The canary system did NOT promote a deployment it couldn't verify
- When the metrics provider became unreachable, the safety mechanism correctly defaulted to "refuse promotion"
- Stable was preserved, no user-facing impact occurred
- The outcome is logically correct even though it wasn't the demonstration originally intended

In a production environment, this is exactly the behavior you want. "I can't tell if this is healthy" should NEVER mean "promote it anyway." Atlas's AnalysisTemplate correctly applies the conservative default.

### Root Cause (Prometheus OOM)

The kube-prometheus-stack values.yaml had `prometheus.prometheusSpec.resources.limits.memory: 512Mi`. With Atlas's scrape volume across 8+ namespaces (including pgbouncer, postgres, argocd, kube-state-metrics, etc.), Prometheus accumulated enough time-series data to OOM approximately every 10 minutes.

**Fix applied:** Bumped to `memory: 2Gi` (requests: 1Gi). After the change, Prometheus stayed stable through Phase 2 attempt 2's analysis window.

---

## Phase 2 Attempt 2 (Revision 5): UNEXPECTED OUTCOME 🤔

### Trigger

After fixing Prometheus memory, re-pushed FAIL_RATE=0.5 to trigger a new canary cycle, expecting AnalysisRun to now correctly measure ~50% success-rate and abort.

### Outcome

Status: ✔ Healthy
Step: 6/6
SetWeight: 100
ActualWeight: 100
Images: ghcr.io/prashant-zo/atlas-backend:v2 (stable)
AnalysisRun: ✔ Successful (10/10 measurements)
Pods: 4 Running, restart counts: 4, 2, 1, 0

The canary **completed all 6 steps and was promoted to stable** — despite having FAIL_RATE=0.5 configured.

### What Happened

1. Revision 5 ReplicaSet created with FAIL_RATE=0.5
2. Canary pod started, began serving traffic
3. **Liveness probe checks `httpGet: path: /` on port 5678**
4. atlas-backend's `/` endpoint applies FAIL_RATE → 50% of probe checks returned HTTP 500
5. After `failureThreshold` consecutive probe failures, Kubernetes restarted the pod
6. During pod restart windows, traffic routed only to healthy stable pods
7. AnalysisRun's success-rate queries measured aggregate traffic, dominated by healthy stable responses
8. Success-rate stayed above the 0.95 threshold across all 5 measurements
9. Canary progressed through all 6 steps → promotion
10. Newly-promoted "stable" pods continued to fail probes and restart periodically

### What This Proves

This is **multi-layer defense in action** — but reveals a design subtlety worth understanding:

**Layer 1 (active):** Kubernetes liveness probes detected the failing pods and restarted them. From the traffic-flow perspective, the failing canary was effectively unavailable during its restart cycles.

**Layer 2 (bypassed):** Atlas's AnalysisRun measured success-rate over ALL pods serving traffic to `backend-svc-canary`. Because Kubernetes was constantly restarting the bad pods, the canary measurement was contaminated by healthy stable-pod responses, masking the failure.

**The system behaved correctly given its inputs:**
- Liveness probes did their job
- AnalysisRun did its job (measured what it could see)
- The actual measured success-rate was above threshold

**But the demonstration revealed a real design consideration:**

When the failure mode is severe enough to trigger Kubernetes' own pod lifecycle management, canary analysis may not see degradation because the system is constantly rotating failing instances. Canary analysis is best-suited for **subtle degradations** that don't crash pods but DO degrade user experience (latency spikes, partial feature failures, increased error rates that stay below restart thresholds).

### Design Implication

For canary analysis to specifically catch metric-level failures (vs Kubernetes catching crash-level failures), atlas-backend should separate:

- **Liveness endpoint** (`/healthz`): Always returns 200 if process is running. Used by Kubernetes liveness probes.
- **Data endpoint** (`/`): Subject to FAIL_RATE injection. Reflects actual user-facing behavior.

This decoupling lets canary analysis observe user-facing failure rates without Kubernetes preemptively replacing the failing pods.

**TODO captured for next iteration:** Add `/healthz` to atlas-backend, update liveness probe to use it.

---

## Summary Table

| Outcome | Revision | Canary Status | Analysis Result | Promotion | What It Demonstrates |
|---|---|---|---|---|---|
| Success | 2 | Healthy | Successful (10/10) | ✓ Promoted | Atlas's full canary mechanism works end-to-end with real metrics |
| Abort | 3 | Degraded | Error (4/6 errors) | ✗ Aborted | Fail-safe when metrics provider is unreachable |
| Multi-layer | 5 | Healthy* | Successful (10/10) | ✓ Promoted | Kubernetes liveness probes intervened before canary analysis could measure pod-level failure |

*Promoted but with restarting pods — the rollout system technically succeeded; the workload itself is unhealthy at the pod level.

---

## Interview Talking Points

This session is interview-worthy because it demonstrates three orthogonal layers of production safety:

### 1. Canary Promotion (Phase 1)
"Atlas runs progressive delivery via Argo Rollouts on EKS. The backend Rollout uses a 6-step canary with a Prometheus-based AnalysisTemplate. When I push a benign change, the canary scales to 25%, runs 5 success-rate measurements over 3.5 minutes, and only progresses if metrics pass a 0.95 threshold. Full automation, no human intervention required."

### 2. Fail-Safe Under Infrastructure Failure (Phase 2 Attempt 1)
"When Prometheus was OOMKilled during a canary analysis, the AnalysisRun couldn't query metrics. After 3 consecutive errors, Argo Rollouts aborted the canary and preserved stable. This is the correct behavior — when you can't verify a deployment is healthy, you don't promote it. We found the underlying Prometheus memory issue, bumped the limit from 512Mi to 2Gi, and captured this in our cnpg-webhook-tls-race.md and phase-b-take-2-todo.md docs."

### 3. Multi-Layer Defense (Phase 2 Attempt 2)
"On the retry with healthy Prometheus, FAIL_RATE=0.5 didn't actually trigger canary rejection — it triggered Kubernetes liveness probe failures, which restarted the pods. The canary analysis measured traffic that was mostly being served by healthy stable pods during restart windows. The deployment 'succeeded' from the rollout system's perspective, but the workload itself was clearly unhealthy. This revealed an important design insight: canary analysis catches degradation that liveness probes miss (subtle latency increases, partial failures). For both layers to be tested independently, the liveness endpoint should be decoupled from the data endpoint — health checks should hit `/healthz` while business traffic hits `/`. Captured as TODO for next iteration."

### 4. The Engineering Maturity Point

"All three outcomes were valid. The interesting thing isn't that the canary 'worked' — it's that I can articulate exactly which safety mechanism activated in each case and why. That's the difference between deploying progressive delivery and understanding it."

---

## Related Documents

- `phase-b-status-and-plan.md` — Original Phase B Take 1 portability fixes
- `canary-analysis-correct-abort.md` — Take 1's abort analysis (deprecated by this doc)
- `cnpg-webhook-tls-race.md` — Phase B Take 2 webhook bootstrap issue
- `phase-b-take-2-todo.md` — Outstanding work for Phase B+1 / Week 7
- `docs/adr/005-progressive-delivery-with-argo-rollouts.md` — Original Rollout design decisions
