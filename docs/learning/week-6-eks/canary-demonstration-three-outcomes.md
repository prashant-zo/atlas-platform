# Canary Demonstration On EKS: Three Real-World Outcomes

**Date:** 2026-06-07 / 2026-06-08
**Context:** Week 6 Phase B Take 2, atlas-eks-dev cluster
**Workload:** atlas-backend (Go service emitting `http_requests_total{version,status}`)
**Strategy:** Argo Rollouts canary with 6 steps and Prometheus-based AnalysisTemplate

This document captures three distinct canary outcomes observed during Phase B Take 2's demonstration session. Each outcome reveals different layers of Atlas's progressive delivery — and the third reveals a critical design flaw in the test harness that has direct production-engineering implications.

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

A traffic-generator CronJob runs every minute, hitting the backend service to produce continuous metric data. atlas-backend supports `FAIL_RATE` env var (range 0.0–1.0) to inject synthetic 500 errors into the `/` endpoint for failure simulation.

Liveness and readiness probes are configured against the same `/` endpoint on port 5678 — a configuration that will become important in Phase 2 Attempt 2.

---

## Phase 1 (Revision 2): Canary SUCCESS ✅

### Trigger

Changed `LATENCY_MS` from `"0"` to `"5"` in `backend-rollout.yaml`. Benign change to trigger a Rollout update without affecting success-rate.

### Outcome

Status: ✔ Healthy
Step: 6/6
SetWeight: 100
ActualWeight: 100
AnalysisRun: ✔ Successful (10/10 measurements)

### What Happened

1. ArgoCD detected the new commit (~30 seconds)
2. Rollout controller created revision 2 ReplicaSet with the new pod template
3. Step 1: `setWeight: 25` — canary scaled to 1 pod, NGINX ingress routed 25% of traffic to it
4. Step 2: AnalysisRun started, queried Prometheus every 30 seconds
5. Each measurement returned success-rate ≈ 1.0 (since FAIL_RATE=0)
6. After 5 successful measurements over ~3.5 minutes, AnalysisRun marked Successful
7. Steps 3–6 progressed through 50% → pause → 75% → pause → 100%
8. Revision 2 marked stable, revision 1 began scale-down delay (`scaleDownDelaySeconds: 300`)

**Total time from push to promotion: ~5 minutes.**

### What This Proves

Atlas's canary mechanism works end-to-end on EKS:
- ArgoCD GitOps sync correctly detects and applies Rollout spec changes
- Argo Rollouts controller correctly orchestrates traffic splitting via NGINX
- ServiceMonitor scrapes atlas-backend's `/metrics` endpoint into Prometheus
- AnalysisTemplate's PromQL query correctly evaluates `http_requests_total{version,status}`
- Successful analysis correctly triggers progression through all canary steps
- Final stable promotion correctly preserves the old ReplicaSet for rollback window

This is the **happy path** — a healthy deployment automatically promoted with real metric validation.

---

## Phase 2 Attempt 1 (Revision 3): Canary ABORT ⚠️

### Trigger

Changed `FAIL_RATE` from `"0"` to `"0.5"` to inject 50% server errors into the canary, expecting AnalysisRun to detect degraded success-rate and abort.

### Outcome

Status: ✖ Degraded
Message: RolloutAborted: Metric "success-rate" assessed Error due to
consecutiveErrors (3) > consecutiveErrorLimit (2):
"Post http://kps-kube-prometheus-stack-prometheus.monitoring.svc:9090/api/v1/query:
dial tcp 172.20.215.149:9090: connect: connection refused"
Step: 0/6
AnalysisRun: ⚠ Error (4 successful queries, 6 errors)

### What Happened

1. ArgoCD synced revision 3 with FAIL_RATE=0.5
2. Canary pod created and became Ready
3. AnalysisRun started querying Prometheus
4. **Prometheus pod was in a restart loop due to OOMKill** — memory limit (512Mi) was insufficient for the workload's scrape volume
5. Multiple AnalysisRun queries hit Prometheus during its restart windows → `connection refused`
6. After 3 consecutive query errors (exceeding `consecutiveErrorLimit: 2`), AnalysisRun marked Error
7. Argo Rollouts immediately aborted the canary
8. Canary ReplicaSet scaled to 0
9. Revision 2 preserved as stable

### What This Proves

This is **fail-safe behavior under metrics infrastructure failure**:

- The canary system did NOT promote a deployment it couldn't verify
- When the metrics provider became unreachable, the safety mechanism correctly defaulted to "refuse promotion"
- Stable was preserved, no user-facing impact occurred

In production, this is exactly the behavior you want. "I can't tell if this is healthy" should NEVER mean "promote it anyway." Atlas's AnalysisTemplate correctly applies the conservative default.

### Root Cause (Prometheus OOM)

The kube-prometheus-stack values had `prometheus.prometheusSpec.resources.limits.memory: 512Mi`. With Atlas's scrape volume across 8+ namespaces (pgbouncer, postgres, argocd, kube-state-metrics, etc.), Prometheus OOMed every ~10 minutes.

**Fix applied:** Bumped to `limits.memory: 2Gi`, `requests.memory: 1Gi`. After the change, Prometheus stayed stable through Phase 2 attempt 2's analysis window.

---

## Phase 2 Attempt 2 (Revision 5): FALSE PROMOTION → SERVICE FAILURE 🚨

This is the most consequential finding of the session, and the most valuable for production-engineering discussion. It happened in **two stages**, ~28 minutes apart.

### Trigger

After fixing Prometheus memory, re-pushed FAIL_RATE=0.5 to trigger a new canary cycle. Expected: AnalysisRun correctly measures ~50% success-rate and aborts.

### Stage 1: Canary "Succeeds" → Incorrect Promotion (T+0 to T+~7 min)

Status: ✔ Healthy
Step: 6/6
SetWeight: 100
ActualWeight: 100
AnalysisRun: ✔ Successful (10/10 measurements)
Pods at promotion: 4 Running, restart counts: 4, 2, 1, 0

The canary completed all 6 steps and was promoted to stable — despite FAIL_RATE=0.5.

#### Why The Canary Analysis Missed The Failure

Each canary pod cycled through this loop during the analysis window:

1. Pod starts → serves traffic → 50% of requests return HTTP 500
2. Readiness probe (3 consecutive failures threshold) trips → pod removed from Service endpoints
3. Liveness probe (3 consecutive failures threshold) eventually trips → container killed
4. Container restarts → grace period → back to step 1

The success-rate Prometheus query measured `rate(http_requests_total[1m])` aggregated across **all pods serving the `backend-svc-canary` endpoint**. During the windows when canary pods were NotReady (removed from Service endpoints), traffic flowed only to the stable revision 4 pods (FAIL_RATE=0). The query's denominator was contaminated by healthy stable-pod responses, pulling the measured success-rate above the 0.95 threshold.

Result: 10/10 analysis measurements "passed". Canary promoted. Stable scaled down.

### Stage 2: Post-Promotion Service Failure (T+~7 to T+~35 min)

Status: ◌ Progressing
Message: updated replicas are still becoming available
Replicas: Desired: 4, Current: 4, Updated: 4, Ready: 0, Available: 0
Pods:

backend-575bdb8ffc-7ddr6  CrashLoopBackOff  28m  restarts: 9
backend-575bdb8ffc-c6dwp  CrashLoopBackOff  25m  restarts: 9
backend-575bdb8ffc-b26c9  CrashLoopBackOff  24m  restarts: 7
backend-575bdb8ffc-vjz4p  CrashLoopBackOff  24m  restarts: 9

**The backend service became entirely unavailable.** Ready: 0/4. Available: 0/4.

#### What `kubectl describe pod` Shows

Warning  Unhealthy  Readiness probe failed: HTTP probe failed with statuscode: 500  (105 times in 30m)
Warning  Unhealthy  Liveness probe failed: HTTP probe failed with statuscode: 500   (59 times in 29m)
Warning  BackOff    Back-off restarting failed container backend                    (47 times in 11m)

Once revision 4 (the previous stable) scaled down completely, there was no healthy fallback. All traffic hit FAIL_RATE=0.5 pods. Probe failures accumulated:
- Readiness probes started failing immediately, removing pods from Service endpoints
- Liveness probes accumulated 3-consecutive-failure thresholds → Kubernetes killed containers
- Each kill incremented the restart counter
- Kubernetes' exponential backoff (CrashLoopBackOff) kicked in
- All 4 pods eventually exhausted their restart budgets

**The service entered an unrecoverable state without manual intervention.** No rollback path existed because the old stable was already gone.

### What This Reveals

This is the **worst-case outcome** in progressive delivery:

1. ❌ Canary analysis incorrectly approved a clearly-broken deployment
2. ❌ The old stable was scaled down before the failure became visible at the deployment level
3. ❌ Liveness probes eventually detected the failure — but only after losing the rollback path
4. ❌ Service is now entirely unavailable with no automatic recovery

The system did exactly what it was told to do at each step. The bug is in **how the test harness was designed**, not in the rollout machinery.

### Root Cause: Liveness Probe And FAIL_RATE Share The Same Endpoint

The atlas-backend pod template configures:

```yaml
livenessProbe:
  httpGet: { path: /, port: 5678 }
  periodSeconds: 10
  failureThreshold: 3
readinessProbe:
  httpGet: { path: /, port: 5678 }
  periodSeconds: 5
  failureThreshold: 3
```

The `/` endpoint is the same endpoint that applies FAIL_RATE. This creates two pathological behaviors:

**During canary:** Probe failures cause pod cycling. Pods drift in and out of Service endpoints. Canary analysis can't measure pure canary success-rate because the denominator includes stable-pod traffic during the canary's NotReady windows.

**Post-promotion:** Probe failures cause CrashLoopBackOff. With stable already scaled down, there's no fallback. The service goes from "passing canary" to "entirely unavailable" within minutes.

### The Fix (Required For Realistic Failure Testing)

Atlas-backend must implement separate endpoints:

- **`/healthz`** — always returns 200 if the process is alive. Used by **both liveness AND readiness probes**. NOT subject to FAIL_RATE.
- **`/`** — serves actual business logic. Subject to FAIL_RATE for testing purposes.

With this separation:
- Liveness probes only catch true process crashes
- Readiness probes only catch startup issues
- FAIL_RATE affects business traffic only
- Canary analysis correctly measures business-level success rate
- A FAIL_RATE=0.5 deployment would be correctly rejected (success-rate ~0.5 < 0.95)

**Captured as P0 TODO** for the next atlas-backend iteration. ADR-011 to document the rationale.

---

## Summary Table

| Phase | Revision | Trigger | Canary Result | Workload Result | What It Reveals |
|---|---|---|---|---|---|
| 1 | 2 | LATENCY_MS=5 | ✔ Successful | ✔ Healthy | Atlas's full canary mechanism works end-to-end |
| 2.1 | 3 | FAIL_RATE=0.5 | ⚠ Error (Prom OOM) | ✗ Aborted | Fail-safe when metrics provider unavailable |
| 2.2 | 5 | FAIL_RATE=0.5 | ✔ Successful* | 🚨 CrashLoopBackOff (0/4 Ready) | Canary analysis can be fooled when probes share endpoints |

*Falsely successful — analysis was contaminated by stable-pod traffic during canary pod cycling.

---

## Interview Talking Points

This session is interview-worthy because each phase teaches a different production-engineering lesson.

### 1. Canary Promotion (Phase 1)

"Atlas runs progressive delivery via Argo Rollouts on EKS. The backend Rollout uses a 6-step canary with a Prometheus-based AnalysisTemplate. When I push a benign change, the canary scales to 25%, runs 5 success-rate measurements over 3.5 minutes, and only progresses if metrics pass a 0.95 threshold. Full automation, no human intervention required."

### 2. Fail-Safe Under Infrastructure Failure (Phase 2.1)

"When Prometheus was OOMKilled during a canary analysis, the AnalysisRun couldn't query metrics. After 3 consecutive errors, Argo Rollouts aborted the canary and preserved stable. This is the correct behavior — when you can't verify a deployment is healthy, you don't promote it. We found the underlying Prometheus memory issue, bumped the limit from 512Mi to 2Gi, and captured the diagnosis in our docs."

### 3. The Most Important Lesson — Phase 2.2

"On the retry with healthy Prometheus, the canary analysis showed all 10 measurements passing. The deployment promoted. About 7 minutes later, the old stable scaled down. About 25 minutes after that, all 4 backend pods were in CrashLoopBackOff and the service was entirely unavailable.

Why? The liveness probe and the failure-injection endpoint were the same endpoint — `/`. During the canary window, FAIL_RATE=0.5 was causing readiness probes to fail, removing pods from the Service. While pods were NotReady, traffic flowed only to the stable pods (which had FAIL_RATE=0). The Prometheus success-rate query measured the aggregate, which looked healthy because stable pods dominated the denominator during canary's NotReady windows.

Once promotion completed and stable scaled down, there was no fallback. Probe failures accumulated until Kubernetes CrashLoopBackOffed all the pods. The service went from 'passing canary' to '0/4 Ready' in about 35 minutes.

The fix is simple: separate `/healthz` (always 200, used by probes) from `/` (business logic, subject to FAIL_RATE). But the lesson is fundamental — progressive delivery requires careful separation between health-check endpoints and business endpoints, because the probes that protect individual pods can blind the analysis that protects the deployment."

### 4. The Engineering Maturity Point

"What I value about this session is that all three outcomes were real, and each one teaches something different about the layered safety mechanisms in Kubernetes progressive delivery — and where they can fail. The interesting thing isn't that the canary 'worked.' It's that I can articulate exactly which safety mechanism activated in each case, why, and what design choice would change the outcome. That's the difference between deploying progressive delivery and understanding it."

---

## Outstanding TODOs From This Session

1. **P0:** Add `/healthz` endpoint to atlas-backend. Point both livenessProbe and readinessProbe at it. Keep `/` for business traffic only.
2. **P1:** Write ADR-011 — "Decouple health-check endpoints from business endpoints in test workloads."
3. **P1:** Consider adding `consecutiveSuccessLimit` to AnalysisTemplate to require more confidence before passing.
4. **P2:** Add ArgoCD sync waves to handle CNPG webhook bootstrap race (see `cnpg-webhook-tls-race.md`).
5. **P2:** Fix `scripts/argocd-bootstrap.sh` to use `127.0.0.1` instead of `localhost` (IPv6 issue on modern macOS).

---

## Related Documents

- `phase-b-status-and-plan.md` — Original Phase B Take 1 portability fixes
- `cnpg-webhook-tls-race.md` — Phase B Take 2 CNPG webhook bootstrap issue
- `phase-b-take-2-todo.md` — Consolidated outstanding work
- `docs/adr/005-progressive-delivery-with-argo-rollouts.md` — Original Rollout design decisions
- ADR-011 (TODO) — Health-check endpoint separation
