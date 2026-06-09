# INC-005 — Canary Always Aborted On EKS, Two Cascading Bugs

**Date:** 2026-06-08 (debug + fix), 2026-06-09 (documentation)
**Severity:** N/A (deliberate Phase A debugging — no user-facing impact)
**Resolution time:** ~3 hours active debugging across two sessions
**User impact:** None — stable ReplicaSet served traffic throughout
**Type:** Phase A of EKS Production Parity roadmap — diagnostic incident

## Purpose

Document the debugging journey that turned the Atlas canary on EKS
from "always aborts, looks broken" to "promotes healthy releases,
aborts genuine failures, both observably." This incident covered two
distinct bugs whose symptoms looked identical from the outside but
had independent root causes.

This is the inverse of INC-004 — that one verified the canary aborts
broken releases. This one revealed that the canary on EKS was aborting
EVERY release (including healthy ones) for two reasons that compounded.

## Symptom

On EKS, every canary cycle ended with:

    Status:  ✖ Degraded
    Message: RolloutAborted: Rollout aborted update to revision N:
             Metric "success-rate" assessed Failed due to
             failed (2) > failureLimit (1)

The Rollout's stable ReplicaSet always remained Healthy 4/4. No user
impact. But also no successful canary promotions — every push was
rejected at step 2 of 6.

Initial suspicion (wrong): the AnalysisTemplate threshold was too strict.

Real diagnosis: two independent bugs in how canary traffic was being
measured.

## Hypothesis (Refined Twice)

**Hypothesis 1 (wrong):** The success-rate threshold of 0.95 is too
tight given low traffic on EKS.

**Hypothesis 2 (wrong):** Prometheus is OOMing again (INC-003 echo).

**Hypothesis 3 (correct):** The canary is aborting because
`http_requests_total{version="canary"}` returns 0 — not because the
canary is failing, but because no traffic is reaching the canary pods,
AND the labels on the canary metrics don't match what the query
expects.

## Setup

- **Cluster:** atlas-eks-dev (EKS 1.31, ap-south-1)
- **Workload:** atlas-backend revision 4 healthy stable on
  `ghcr.io/prashant-zo/atlas-backend:6e501b6`
- **Image properties:** FAIL_RATE=0 in Git, /healthz separated from /,
  exports `http_requests_total{version,status}` from /metrics
- **AnalysisTemplate gates (unchanged from INC-004):**
  - success-rate ≥ 0.95
  - p95-latency-ms ≤ 500
  - failureLimit: 1, initialDelay: 60s, interval: 30s, count: 5

## Investigation Timeline

### Phase 1 — First Push, First Abort (Bug #1 Surface)

After bootstrapping EKS, pushed a trivial change to trigger a canary.
Revision 5 created, canary pod Ready, AnalysisRun started 60s later.
Two failed measurements in a row, AnalysisRun: Failed, Rollout:
Degraded.

Initial reading of `kubectl describe analysisrun`:

    Measurements:
      Phase: Failed
      Value: [0]

The query returned literal 0. Not 0.5 (FAIL_RATE behavior), not 0.9
(close-to-threshold), but exactly 0. This pointed at the
`OR on() vector(0)` fallback — the actual query had returned no data
at all.

### Phase 2 — Diagnosing Bug #1 (Traffic Doesn't Reach Canary)

Hit Prometheus directly during a canary window:

    query: sum by (job) (rate(http_requests_total[2m]))

Results:
- `job="backend-svc"`     → rate > 0  (traffic flowing to stable Service)
- `job="backend-svc-canary"` → rate = 0  (canary Service receiving nothing)

Looked at the traffic source — the `traffic-generator` CronJob at
`gitops/workloads/three-tier-app/base/traffic-generator.yaml`:

    TARGET="http://backend-svc:3000/"
    curl -sS -o /dev/null -m 5 "$TARGET" || true

**The CronJob was hitting backend-svc directly.** During a canary,
Argo Rollouts patches `backend-svc`'s selector to point at stable pods
only. The `backend-svc-canary` Service points at canary pods. NGINX
ingress, with the duplicated `backend-canary` Ingress and canary-weight
annotations, is the only thing that splits traffic between them.

Hitting `backend-svc` directly skipped the ingress entirely. Canary
pods received zero requests. The AnalysisRun query
`sum(rate(http_requests_total{version="canary",status=~"2.."}[2m]))`
had no data, the denominator was 0, and the `OR on() vector(0)`
fallback kicked in to return 0. The threshold check `0 >= 0.95`
failed. Canary aborted.

**Fix #1:** Change traffic-generator to hit the ingress with a Host
header:

    TARGET="http://ingress-nginx-controller.ingress-nginx.svc:80/"
    HOST_HEADER="backend.atlas.local"
    curl -sS -o /dev/null -m 5 -H "Host: ${HOST_HEADER}" "$TARGET" || true

This routes traffic through NGINX, which applies the canary-weight
annotations and splits traffic 25%/75% between canary and stable.

Commit: `d8cbae7 fix(traffic-gen): route through ingress so canary
receives traffic split`

### Phase 3 — Retried Rollout, NEW Failure Mode (Bug #2 Surface)

After deploying the traffic-generator fix, retried the stuck rollout:

    kubectl argo rollouts retry rollout backend -n three-tier-dev

Revision 6 created. Canary pod Ready. AnalysisRun started 60s later.
Two failed measurements in a row, AnalysisRun: Failed, Rollout:
Degraded.

Same symptom as before. But this time traffic-generator was demonstrably
hitting ingress (curl test confirmed). What now?

Hit Prometheus again with a more targeted query:

    query: sum by (version, job) (rate(http_requests_total[2m]))

Results:
- `version="v2", job="backend-svc"`       → rate > 0
- `version="v2", job="backend-svc-canary"` → rate > 0 (small)

**There were no metrics with `version="canary"`.** The new pods —
which had downward API VERSION env piped from the
`rollout-pod-template-hash-version` label — should have reported
`version="canary"` during their canary lifecycle. Why weren't they?

### Phase 4 — Diagnosing Bug #2 (Downward API Label Staleness)

The Rollout was configured per ADR-009 to inject the role label into
the pod's container env via Kubernetes Downward API:

    env:
      - name: VERSION
        valueFrom:
          fieldRef:
            fieldPath: metadata.labels['rollout-pod-template-hash-version']

The expectation: when Argo Rollouts creates a canary pod with label
`rollout-pod-template-hash-version: canary`, the downward API reads
that label and sets the env var to `canary`. The Go process then
reports `http_requests_total{version="canary"}`.

This was correct AT POD CREATION TIME. But by the time we queried
Prometheus, the canary pods had already finished their canary cycle,
been promoted to stable, and had their LABELS rewritten to `stable`.
The env var stayed at `canary` (set once at container start), but the
labels said `stable`. The pods were now reporting
`http_requests_total{version="canary"}` while being labeled stable.

Verified directly:

    POD=$(kubectl get pods -n three-tier-dev -l app=backend -o jsonpath='{.items[0].metadata.name}')
    
    # Current label
    kubectl get pod -n three-tier-dev "$POD" \
      -o jsonpath='{.metadata.labels.rollout-pod-template-hash-version}'
    # → "stable"
    
    # Env var spec (still references the label)
    kubectl get pod -n three-tier-dev "$POD" \
      -o jsonpath='{.spec.containers[?(@.name=="backend")].env[?(@.name=="VERSION")]}'
    # → fieldRef to metadata.labels['rollout-pod-template-hash-version']
    
    # What the process actually has (via /healthz)
    kubectl port-forward -n three-tier-dev "$POD" 5678:5678 &
    curl -s http://localhost:5678/healthz
    # → {"status":"ok","version":"canary"}    ← STALE

This is documented Kubernetes behavior. The Downward API for pod
metadata via `fieldRef` is read ONCE at container creation. Subsequent
mutations to the pod's labels do not update the env vars in the
running container.

But what about the previous canary cycle? Why did the OLD stable pods
(revision 4) report `version="v2"`? They were created before the
downward API change — back when VERSION was hardcoded to "v2". They
never went through the canary→stable label transition, because they
were the original stable. Their env var was set from a literal value,
not a fieldRef.

**This meant:** post-promotion, our `version` label in Prometheus was
completely unreliable. We could not use it to filter canary metrics
because:
- Old stable pods (literal VERSION env) reported one value
- New stable pods (downward API set during their canary cycle)
  reported a different stale value

**Fix #2:** Stop relying on the `version` pod label for canary
filtering. Use the `job` label instead, which Prometheus' ServiceMonitor
sets per scrape source. Argo Rollouts dynamically updates the
backing pods of `backend-svc-canary` (canary pods only) and
`backend-svc` (stable pods only) Services via selector patching. The
`job` label reflects which Service the metric came from, NOT a pod
label, and is therefore correct across promotions.

Modified `gitops/workloads/three-tier-app/base/backend-analysistemplate.yaml`:

    query: |
      (
        sum(rate(http_requests_total{
          job="backend-svc-canary",
          status=~"2.."
        }[2m]))
        /
        sum(rate(http_requests_total{
          job="backend-svc-canary"
        }[2m]))
      ) OR on() vector(0)

Removed the now-unnecessary `canary-version` arg from both the
AnalysisTemplate and the Rollout's analysis step.

Commit: `1ce2541 fix(canary): filter AnalysisRun query by job label,
not version`

### Phase 5 — Verification

After both fixes deployed:

**Phase 1 SUCCESS demo (revision 6 promoted):**

    NAME                                 KIND         STATUS        AGE
    └──α backend-d5b565696-6-1.2         AnalysisRun  ✔ Successful  ✔ 10

10/10 measurements passed. All 6 canary steps progressed. Revision 6
promoted to stable.

**Phase 2 ABORT demo (revision 7 aborted with FAIL_RATE=0.5):**

    Status:  ✖ Degraded
    Message: RolloutAborted: Rollout aborted update to revision 7:
             Metric "success-rate" assessed Failed due to
             failed (2) > failureLimit (1)
    
    ├──# revision:7
    │  ├──⧉ backend-5b9bb5787c   ReplicaSet  • ScaledDown  canary,delay:passed
    │  └──α backend-5b9bb5787c-7-1  AnalysisRun ✖ Failed  ✔ 2,✖ 2

Stable preserved at revision 6 (4/4 Healthy). Service uninterrupted.

## Evidence

### Phase 1 SUCCESS — AnalysisRun Output

    Metric Results:
      Count:    5
      Failed:   0
      Successful: 5
      Measurements:
        Phase: Successful, Value: [0.9988...]
        Phase: Successful, Value: [0.9976...]
        Phase: Successful, Value: [0.9991...]
        Phase: Successful, Value: [0.9982...]
        Phase: Successful, Value: [1.0]
      Name: success-rate
      Phase: Successful

### Phase 2 ABORT — AnalysisRun Output

    Metric Results:
      Count:    2
      Failed:   2
      Measurements:
        Phase: Failed, Value: [0.4972...]    # ~50% — FAIL_RATE=0.5 working
        Phase: Failed, Value: [0.5103...]
      Name: success-rate
      Phase: Failed
    Events:
      Warning  MetricFailed       'success-rate' Completed. Result: Failed
      Warning  AnalysisRunFailed  Analysis Completed. Result: Failed

## Result

Both fixes verified end-to-end. The canary on EKS now:

1. ✅ Promotes healthy releases (Phase 1 SUCCESS, measured on real
   ingress-routed traffic)
2. ✅ Aborts genuine failures (Phase 2 ABORT, measured ~50%
   success-rate vs 0.95 threshold)
3. ✅ Uses queries that are robust to pod role transitions (job-label
   filtering vs pod-label filtering)

## Key Observations

### Two Bugs Compounding Looked Like One Bug

From outside, every symptom was "canary aborts." But there were two
independent root causes. The first fix (traffic-generator) was
necessary but not sufficient — without the second fix (job-label
query), the canary STILL would have aborted for a different reason.

This is the "compound failure" pattern. Two non-interacting bugs that
produce the same symptom. Diagnosed one at a time, with each fix
revealing the next.

### Downward API Has A Subtle Time Dimension

The Downward API documentation says fieldRef reads pod metadata
"at container creation." Until you encounter the case where a
controller (Argo Rollouts) mutates pod labels AFTER creation, you
might not appreciate that "at creation" means "and never updated
afterward."

Lesson: for metrics that need to reflect a pod's CURRENT role, derive
the role from a source that updates dynamically — like the Service
that scraped it (the `job` label), not the pod's own labels.

See `docs/learning/week-6-eks/downward-api-label-staleness.md` for
the full pattern.

### Argo Rollouts' `retry` Command Was Critical

After both fixes deployed, the Rollout was stuck in Degraded state
from earlier failed attempts. ArgoCD had synced the new manifest
spec, but Argo Rollouts does not automatically retry Degraded rollouts
when spec changes — that would be unsafe in production (re-trying a
fix that hasn't actually fixed the underlying problem).

The operator must explicitly:

    kubectl argo rollouts retry rollout backend -n three-tier-dev

This creates a new revision from the current spec and starts the
canary process over. Without this command, the cluster would have
stayed Degraded indefinitely despite ArgoCD reporting "Synced."

See updated `docs/runbooks/canary-failure-response.md` for the
retry-vs-revert decision flow.

### Traffic-Generator Is Necessary But Not Sufficient

The traffic-generator CronJob produces ~1 RPS of background traffic.
For Phase A's verification this was enough to drive the AnalysisRun
queries with real signal. But for high-confidence canary demos
(particularly the Phase 2 ABORT case where we want clear
statistical evidence of 50% failure), the in-cluster k6 load test
at `load-tests/k6/` should be used to drive ~100 RPS during the
analysis window.

**Pattern:** background traffic-generator for always-on metrics;
on-demand k6 for strong statistical signal during deliberate
canary tests.

## Action Items

- [x] Fix traffic-generator to hit ingress (commit d8cbae7)
- [x] Fix AnalysisTemplate to filter by job, not version (commit 1ce2541)
- [x] Capture Phase 1 SUCCESS demo on real EKS traffic
- [x] Capture Phase 2 ABORT demo on real EKS traffic
- [x] Document the downward API pattern as a learning doc
- [x] Document the traffic-routing pattern as a learning doc
- [x] Update canary-failure-response runbook with retry vs revert flow
- [ ] ADR-013 (Phase F): Decision record for job-label vs pod-label filtering
- [ ] ADR-014 (Phase F): Decision record for traffic-routing through ingress

## Interview Talking Point

> "Atlas worked on kind in Week 5 but the canary on EKS was aborting
> every single deployment, even healthy ones. The symptom was always
> the same — success-rate evaluated to 0, AnalysisRun marked Failed,
> Rollout went Degraded. But there were two independent root causes.
>
> First, the background traffic-generator was hitting backend-svc
> directly. During a canary, Argo Rollouts patches that Service's
> selector to point at stable pods only. The ingress and its
> duplicated canary-Ingress with weight annotations is what actually
> does the split. So canary pods were receiving zero traffic. The
> AnalysisRun query had no data, fell through to the
> `OR on() vector(0)` fallback, and returned 0.
>
> Second — and this only surfaced after fixing the first bug — we
> were filtering Prometheus by the `version` pod label, which we set
> via the Kubernetes Downward API from
> `metadata.labels['rollout-pod-template-hash-version']`. That label
> changes from 'canary' to 'stable' when Argo Rollouts promotes. But
> the Downward API only reads pod metadata at container creation —
> the env var doesn't update when labels change. So after promotion,
> pods retained their original env vars. Filtering by `version` was
> measuring stale data.
>
> The fix was to filter by the `job` label, which Prometheus sets
> from the ServiceMonitor's scrape source. Argo Rollouts patches the
> Services' selectors dynamically — `backend-svc-canary` always points
> at canary pods, `backend-svc` always points at stable. The `job`
> label inherits that correctness for free.
>
> Two bugs, both subtle, both interview-worthy. The first taught me
> that progressive delivery routing assumes traffic flows through
> the same path users use — direct Service access bypasses it
> entirely. The second taught me that the Downward API is read-once
> at creation, which makes it the wrong primitive for any signal
> that needs to reflect a pod's CURRENT role rather than its
> birth role."

## Related

- INC-004 — Deliberate broken canary GameDay (the inverse test)
- `docs/learning/week-6-eks/traffic-routing-during-canary.md` —
  Bug #1 deep dive
- `docs/learning/week-6-eks/downward-api-label-staleness.md` —
  Bug #2 deep dive
- `docs/runbooks/canary-failure-response.md` — Updated with retry flow
- `gitops/workloads/three-tier-app/base/traffic-generator.yaml` —
  The corrected CronJob
- `gitops/workloads/three-tier-app/base/backend-analysistemplate.yaml` —
  The corrected query
- Commit `d8cbae7` — traffic-generator ingress fix
- Commit `1ce2541` — AnalysisTemplate job-label fix
