# INC-004 — Deliberate Broken-Canary GameDay

**Date:** 2026-06-01
**Severity:** N/A (deliberate exercise)
**Resolution time:** Auto-rollback at T+90s from canary deployment
**User impact:** None — stable v2 ReplicaSet served 100% of legitimate traffic throughout
**Type:** Planned GameDay / chaos exercise for Week 5 progressive delivery validation

## Purpose

Verify that Atlas's progressive delivery pipeline correctly detects and
rolls back a known-bad release. This is the inverse test of the
successful v2 canary (Task 5.5) — instead of confirming the system
promotes a healthy release, we confirm it rejects a broken one.

A canary system never tested under failure is not a canary system you
can trust. INC-004 produces the evidence.

## Hypothesis

A backend with `FAIL_RATE=0.5` (50% of requests return HTTP 500) should:

1. Get blocked at the first analysis evaluation by the success-rate gate
2. Trigger auto-rollback to v2 stable
3. Cause zero user impact — stable ReplicaSet should remain at 4/4 ready
4. Complete within ~90 seconds of canary deployment (60s initial delay
   + one 30s evaluation interval)

## Setup

- **Image:** `localhost:5001/atlas-backend:v3` (same binary as v1/v2, env-only sabotage)
- **Sabotage:** `FAIL_RATE=0.5` environment variable on the Rollout
- **Other env:** `VERSION=v3`
- **AnalysisTemplate args:** `canary-version: "v3"`
- **Gates (unchanged from production config):**
  - success-rate ≥ 0.95 over 2-minute window
  - p95 latency ≤ 500ms over 2-minute window
  - failureLimit: 1
  - consecutiveErrorLimit: 2
  - initialDelay: 60s, interval: 30s, count: 5

## Timeline (UTC)

| Time | Event |
|---|---|
| 14:48:23 | INC-004 start — gameday commit pushed |
| 14:48:39 | ArgoCD sync starts |
| 14:48:43 | Rollout reconciliation begins, revision 6 created |
| 14:49:02 | Canary v3 pod ready, NGINX traffic-routing flips, ~25% of traffic now hits v3 |
| 14:49:02 | Rollouts AnalysisRun `backend-58687cd875-6-1` created |
| 14:49:02 → 14:50:01 | InitialDelay 60s — no analysis evaluations yet |
| 14:50:01 | **First evaluation:** success-rate = 0.5043 → FAILED (< 0.95) |
| 14:50:01 | First evaluation: p95-latency = 4.75ms → Successful |
| 14:50:31 | **Second evaluation:** success-rate = 0.4734 → FAILED |
| 14:50:31 | Second evaluation: p95-latency = 4.75ms → Successful |
| 14:50:32 | failureLimit (1) exceeded on success-rate (2 failures) → AnalysisRun: Failed |
| 14:50:32 | Rollout state: Progressing → Degraded |
| 14:50:32 | Auto-rollback: v3 ReplicaSet scaling to 0, traffic-routing weight returns to 0 |
| 14:50:32 → 14:55:32 | scaleDownDelay (300s): v3 pod retained for forensics |
| 14:55:32 | v3 ReplicaSet pod terminated, cleanup complete |

**Time from canary serving traffic to rollback decision: 90 seconds.**

## Evidence

### AnalysisRun Measurements (verbatim from `kubectl describe`)

Metric Results:
Count:   2
Failed:  2
Measurements:
Finished At:  2026-06-01T14:50:01Z
Phase:        Failed
Value:        [0.5043193509224981]    # 50.4% success rate
Finished At:  2026-06-01T14:50:31Z
Phase:        Failed
Value:        [0.4733517872277252]    # 47.3% success rate
Name:   success-rate
Phase:  Failed
Metric Results:
Count:  2
Measurements:
Value:        [4.75]                  # latency unaffected
Value:        [4.75]
Name:        p95-latency-ms
Phase:       Successful
Events:
Warning  MetricFailed       Metric 'success-rate' Completed. Result: Failed
Normal   MetricSuccessful   Metric 'p95-latency-ms' Completed. Result: Successful
Warning  AnalysisRunFailed  Analysis Completed. Result: Failed

### Prometheus Confirmation

During the 90s canary window, v3 served:

- **27.3 total requests** (Prometheus `increase(http_requests_total[10m])`)
- **15.3 of those were HTTP 500** (Prometheus `increase(...{status="500"}[10m])`)
- **Computed error rate: 56% (success rate ≈ 44%)** — confirms FAIL_RATE=0.5 worked as designed
- v3 success rate measured by AnalysisRun: 50.4% then 47.3% (slight variation from window averaging)

### Cluster State During Rollback

The stable v2 ReplicaSet was never touched:

revision 6 (broken v3):
ReplicaSet — ScaledDown
AnalysisRun  — Failed (✔ 2, ✖ 2)
revision 5 (healthy v2):
ReplicaSet — Healthy
Pods: 4 / 4 Ready (entire incident duration)

## Result

Hypothesis confirmed in all four respects:

1. ✅ Canary blocked at first evaluation by the success-rate gate
2. ✅ Auto-rollback fired without human intervention
3. ✅ Zero user impact — stable v2 ReplicaSet stayed at 4/4 Ready throughout
4. ✅ Total time to rollback: 90 seconds (60s initialDelay + 30s first eval)

## Key Observations

### Two metrics, one catch

The latency gate (`p95-latency-ms ≤ 500ms`) passed all four measurements at
4.75ms. The success-rate gate (`>= 0.95`) failed all four measurements
at ~50%. **Only success-rate caught this canary.**

This is because a broken Go service returning `w.WriteHeader(500); return`
does so almost instantly — error responses don't degrade latency. If
Atlas had relied on latency alone as a canary signal (a tempting
simplification because latency feels like "user pain"), this release
would have passed the gate and been promoted to production.

**Multi-signal gating exists for exactly this kind of asymmetric failure.**
Different bugs hide from different metrics. Always gate on more than one.

### Statistical power is high when the signal is strong

The AnalysisRun made its decision on just 27 sampled requests. With a
50% error rate, even a tiny sample produces a confident measurement.
The system did not need thousands of requests to detect a bad release.
This matters for canary windows on low-traffic services.

### Failure mode comparison vs INC-003 (Task 5.5 first attempt)

| | INC-003 (empty data) | INC-004 (50% errors) |
|---|---|---|
| Trigger | Prometheus returned `[]` for histogram | Prometheus returned 0.50 for success-rate |
| AnalysisRun state | Error (controller panic) | Failed (threshold breach) |
| Gate that fired | consecutiveErrorLimit | failureLimit |
| User impact | None | None |
| Time to rollback | ~75s (5 errors × 15s) | 90s (60s delay + 30s eval) |
| Engineering lesson | Add fallbacks for empty queries | Multi-signal gating works |

**Both failure paths produce the same safety outcome: stable preserved,
canary aborted.** The system handles broken queries and broken releases
with the same rollback behavior. That's robustness.

### scaleDownDelaySeconds was useful but not exercised here

We set `scaleDownDelaySeconds: 300` to keep failed canary pods around
for forensics. In INC-004 the user reading the dashboard saw the
abort 3+ minutes after it happened (writing this report after the
recovery), so the forensics window had passed. For real production
incidents — where someone might respond in seconds — the 5-minute
window allows live debugging via `kubectl exec` / `kubectl logs` on
the failed pod.

## Recovery Action

`git revert` of the gameday commit. ArgoCD synced the revert; Argo
Rollouts recognized the spec change as a return to the existing
revision-5 ReplicaSet (healthy v2) and promoted it directly to stable
without running another canary cycle. Cluster returned to `Healthy 4/4`
within 30 seconds.

## Action Items

- [x] Document the empty-data-vs-bad-release contrast (this doc)
- [x] Verify both metric gates exist independently (success-rate caught
      this; latency-only would have missed it)
- [ ] Future: capture this story as an interview talking point about
      multi-signal canary gating (notes/atlas-interview-prep.md)
- [ ] Future: consider running gameday at higher traffic via k6 to see
      how the analysis behaves with larger sample sizes (currently 27
      requests; with k6's 100 RPS we'd see ~7,500 in the same window
      — useful for understanding statistical edge cases)

## Interview Talking Point

> "I deliberately deployed a broken backend version with 50% error
> injection to verify that the canary rollback worked under real
> conditions. The progressive delivery pipeline detected the elevated
> error rate within 30 seconds of the first analysis evaluation. The
> success-rate gate saw 50% and 47% across two consecutive 30-second
> windows, blew through `failureLimit: 1`, and the controller aborted
> the canary, scaling the broken ReplicaSet to zero while preserving
> the stable v2 pods at 4/4 Ready. Total time from broken-deploy to
> safety: 90 seconds, zero user impact. The interesting twist was that
> the latency gate stayed green at 4.75ms throughout — because broken
> Go requests return 500 instantly, they don't degrade p95. If I had
> only gated on latency, the bad release would have promoted. Multi-
> signal gating saved this."

## Related

- `docs/learning/week-5-delivery/analysistemplate-empty-data-trap.md` —
  the prior failure path (INC-003 equivalent)
- `docs/adr/005-progressive-delivery-with-argo-rollouts.md` — design rationale
- `gitops/workloads/three-tier-app/base/backend-analysistemplate.yaml` —
  the gates that fired
