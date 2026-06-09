# Runbook — Canary Deployment Failure

When an Argo Rollouts canary fails or stalls during deployment of the
`backend` workload, this runbook gets the system back to a known-good
state without losing the failure forensics.

**Audience:** On-call engineer for the Atlas platform
**Estimated time to recover:** 5 minutes for confirmed failures,
15-20 minutes for diagnosis cases

## Symptom Triage — Which Failure Is This?

Run this first:

```bash
kubectl argo rollouts get rollout backend -n three-tier-dev | head -15
```

Match the `Status:` line to one of the cases below.

### Case A — Status: ✖ Degraded, "RolloutAborted"

The analysis has already failed and rollback has fired. Stable
ReplicaSet should already be serving 100% of traffic. Verify that
first, then move to "Recover from Degraded".

### Case B — Status: ॥ Paused, "CanaryPauseStep"

Mid-canary, waiting at a pause step. This is normal during analysis
evaluation or timed soak steps. Confirm the AnalysisRun is progressing,
not stuck. See "Diagnose Stalled Canary".

### Case C — Status: ◌ Progressing, with running AnalysisRun

Canary in flight, analysis is running. Watch it; intervene only if it
has been running > 5 minutes past expected duration.

### Case D — Status appears healthy but users report errors

Real user impact is happening but the rollout looks fine. This is the
gnarliest case — the gate missed something. Jump to "False Negative
Investigation".

---

## Recover from Degraded (Most Common)

### Step 1 — Confirm Stable Is Serving

```bash
# Stable ReplicaSet should be Healthy
kubectl argo rollouts get rollout backend -n three-tier-dev | grep -A1 "stable"

# Curl through the ingress should return the previous-good version
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8090:80 >/dev/null 2>&1 &
sleep 2
for i in {1..5}; do curl -s -H "Host: backend.atlas.local" http://localhost:8090/; echo; done
pkill -f "port-forward.*ingress-nginx" 2>/dev/null
```

If all curls return the previous version → users are safe.
If any curl returns the broken version → escalate; the canary
ReplicaSet may not have fully scaled down. See "Force Stable".

### Step 2 — Capture Forensics

The failed canary ReplicaSet stays around for `scaleDownDelaySeconds`
(currently 300s = 5 minutes). Get logs and AnalysisRun output before
they vanish.

```bash
# Pod logs from the failed canary
FAILED_POD=$(kubectl get pods -n three-tier-dev -l app=backend \
  -o jsonpath='{range .items[?(@.metadata.labels.rollouts-pod-template-hash)]}{.metadata.name} {.metadata.labels.rollouts-pod-template-hash}\n{end}' \
  | grep -v stable | head -1 | awk '{print $1}')

if [ -n "$FAILED_POD" ]; then
  echo "Failed pod: $FAILED_POD"
  kubectl logs -n three-tier-dev "$FAILED_POD" --tail=200 > /tmp/canary-fail-logs.txt
  kubectl describe pod -n three-tier-dev "$FAILED_POD" > /tmp/canary-fail-describe.txt
  echo "Saved to /tmp/canary-fail-*.txt"
fi

# Get the AnalysisRun decision data
LATEST_RUN=$(kubectl get analysisrun -n three-tier-dev \
  --sort-by=.metadata.creationTimestamp -o name | tail -1)
kubectl describe "$LATEST_RUN" -n three-tier-dev > /tmp/canary-fail-analysis.txt
echo "AnalysisRun saved to /tmp/canary-fail-analysis.txt"
```

Read the AnalysisRun's `Measurements` section. This shows the actual
Prometheus values at each evaluation. Two cases:

- **Phase: Failed** — the gate threshold was breached. Real bad release.
- **Phase: Error** — the query itself failed to evaluate. Could be a
  Prometheus issue, not a release issue. See "Error vs Failed" below.

### Step 3 — Decide: Revert or Forward-Fix

If git HEAD is the broken release:

```bash
# Revert the bad commit, push, sync
git revert HEAD --no-edit
git push
argocd app sync three-tier-dev 2>/dev/null
```

Argo Rollouts treats the revert as a return to the previous-known-good
ReplicaSet and promotes it directly without running another canary
cycle. Recovery to Healthy 4/4 in < 30 seconds.

If you need to forward-fix instead (apply a patch and re-canary), bump
the image tag and the `VERSION` env to a new value (e.g., v4) so
Rollouts treats it as a fresh revision. Don't re-use the broken tag.

### Step 4 — Confirm Recovery

```bash
kubectl argo rollouts get rollout backend -n three-tier-dev | head -10
```

Expected: `Status: ✔ Healthy`, `Step: 6/6`, `SetWeight: 100`,
stable ReplicaSet at 4/4 Ready.

---

## Diagnose Stalled Canary

If the rollout is `Paused` for > 5 minutes past expected duration:

```bash
# Is the AnalysisRun stuck or progressing?
kubectl get analysisrun -n three-tier-dev \
  --sort-by=.metadata.creationTimestamp -o name | tail -1 \
  | xargs -I {} kubectl describe {} -n three-tier-dev | tail -50
```

Common stall causes:

- **Prometheus unreachable** — analysis can't get metrics. Check
  `kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus`
  and any port-forward / network issue. See `slo-breach-response.md`
  for Prometheus recovery.
- **Empty query result** — the metric the gate queries has no data
  yet. Usually means traffic isn't flowing to the canary. Check
  `kubectl get endpoints -n three-tier-dev backend-svc-canary` —
  should have at least one pod IP during canary.
- **Configuration drift** — the analysis-template `job` label or
  `version` filter doesn't match actual Prometheus series. See
  `docs/learning/week-5-delivery/analysistemplate-empty-data-trap.md`.

### Force Promote (last resort)

Only if you've confirmed the canary is genuinely healthy but stuck on
gate evaluation issues:

```bash
kubectl argo rollouts promote backend -n three-tier-dev
```

This bypasses the next pending step. Use carefully.

---

## Force Stable (Emergency)

If the canary ReplicaSet is still serving traffic after a failure:

```bash
kubectl argo rollouts abort backend -n three-tier-dev
```

This force-aborts any in-flight rollout. The canary ReplicaSet scales
to zero, stable serves 100%. Users see only stable from this point.

---

## False Negative Investigation

If users report errors but the rollout looks healthy, the analysis
gate missed something. Don't trust the rollout state — verify directly.

```bash
# What does Prometheus actually say?
kubectl port-forward -n monitoring svc/kps-kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 &
sleep 3

# Current success rate across all backend traffic
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=sum(rate(http_requests_total{job=~"backend-svc.*",status=~"2.."}[5m])) / sum(rate(http_requests_total{job=~"backend-svc.*"}[5m]))' \
  | python3 -m json.tool

# Current p95 latency
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{job=~"backend-svc.*"}[5m])) by (le)) * 1000' \
  | python3 -m json.tool

pkill -f "port-forward.*prometheus" 2>/dev/null
```

If these numbers don't match what users are seeing, the gate metric
isn't capturing the actual user-facing signal. Lessons learned will
need to feed back into the AnalysisTemplate (e.g., add a new metric
or tighten thresholds).

This case is rare but interview-worthy: it's the limit of canary
analysis. Gates check what they check — they don't know about bugs
they weren't told to look for.

---

## Error vs Failed

The AnalysisRun's `Phase` field distinguishes two cases. They have
the same safety outcome (stable preserved, canary aborted) but
different root causes.

| | Failed | Error |
|---|---|---|
| Trigger | Metric breached threshold | Query couldn't evaluate |
| Triggered by | `failureLimit` | `consecutiveErrorLimit` |
| Example | success rate dropped to 50% | Prometheus returned `[]` for histogram |
| Root cause | Bad release | Bad query or unreachable Prometheus |
| Investigation focus | The release | The metric pipeline |

See `004-broken-canary-deliberate-gameday.md` for an example of the
Failed path and `learning/week-5-delivery/analysistemplate-empty-data-trap.md`
for an example of the Error path.

---

## Retry vs Revert After Degraded

If the Rollout is `✖ Degraded` because of a FAILED analysis (Case A),
you have two recovery paths. The right one depends on whether the
ROOT CAUSE is in the deployment or in the measurement plane.

### Decision Tree

Rollout: ✖ Degraded
│
├─ Did the canary code itself misbehave?
│  (50% error rate, latency spike, real bug in the release)
│
│   YES → REVERT
│   No  → continue
│
├─ Did the analysis plane misbehave?
│  (Prometheus down, ServiceMonitor broken, wrong PromQL query)
│
│   YES → FIX THE PLANE, THEN RETRY
│   No  → continue
│
└─ Did the deployment pipeline misbehave?
(ArgoCD didn't sync, image pull failed, manifest changed)

YES → FIX THE PIPELINE, THEN RETRY
No  → escalate (this case is genuinely unusual)

### Path 1: Revert (Most Common)

The release itself is bad. Get back to last-known-good fast.

```bash
git revert HEAD --no-edit
git push
# ArgoCD picks up the revert automatically; Argo Rollouts
# treats the revert as a return to the previous stable
# ReplicaSet and promotes directly (no new canary cycle).
```

Cluster returns to Healthy 4/4 within ~30 seconds. Capture
forensics first (logs, AnalysisRun describe) before reverting if
you need to debug the bad release later.

### Path 2: Retry (After Fixing Underlying Issue)

The Rollout SPEC has been updated in Git (you fixed the root cause:
Prometheus came back, you fixed the query, you fixed the
traffic-generator, etc.). ArgoCD has synced the new spec to the
Rollout CRD. But:

**Argo Rollouts will NOT automatically retry a Degraded rollout.**

This is by design. Automatic retry would be unsafe — it would
re-attempt deploys that hadn't actually been fixed, and would create
churn under repeated failures. The operator must explicitly say
"the root cause is fixed, please try this again":

```bash
kubectl argo rollouts retry rollout <name> -n <namespace>
```

This creates a new revision from the CURRENT Rollout spec and starts
the canary process over.

### When To Use Each

| Situation | Path |
|---|---|
| Bad code in HEAD, fast rollback | Revert |
| Analysis template was wrong, fixed it | Retry |
| Prometheus was OOMing, raised limit | Retry |
| Traffic source was broken, fixed it | Retry |
| Image pull failed, fixed image | Retry |
| Spec change you want to re-attempt | Retry |
| Bad deploy that you DON'T want to repeat | Revert |

### Diagnostic Before Retry

Before running `retry`, verify the new spec is actually different
from what failed:

```bash
# What's in Git
grep -A1 "FAIL_RATE\|VERSION" gitops/workloads/three-tier-app/base/backend-rollout.yaml

# What's in the Rollout CRD
kubectl get rollout backend -n three-tier-dev \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="backend")].env}' | jq .

# What was tried last (the failed ReplicaSet's spec)
kubectl get replicaset <failed-rs-name> -n three-tier-dev \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="backend")].env}' | jq .
```

The first two should match (ArgoCD sync worked). The third should
DIFFER from the first (your fix is genuinely a change). If the first
two don't match, ArgoCD hasn't synced — `argocd app sync` first. If
the first and third match, your "fix" isn't actually a fix — retry
will produce the same failure.

### What Retry Actually Does

Rollout: Degraded
│
│  kubectl argo rollouts retry rollout <name> -n <ns>
│
▼
Rollout: Progressing
│  - Argo Rollouts creates a new revision (N+1)
│  - ReplicaSet built from current spec
│  - Canary pod created, becomes Ready
│  - AnalysisRun starts after initialDelay
│  - If passes: progress through all 6 canary steps
│  - If fails: back to Degraded, capture forensics

Without `retry`, the Rollout stays Degraded indefinitely even if Git
has the fix and ArgoCD has synced. The user-visible bug looks like
"ArgoCD reports Synced but the cluster isn't progressing" — but
that's actually correct behavior from both controllers.

### Common Mistakes

- **Pushing a fix and waiting for things to happen.** ArgoCD will
  sync, but the Rollout won't retry automatically. You MUST run
  `kubectl argo rollouts retry`.

- **Running `retry` before the fix is in the Rollout spec.** Wait for
  ArgoCD to sync first (`kubectl get application -n argocd` showing
  Synced + Healthy, or `sleep 20`), then retry.

- **Confusing `retry` with `promote --full`.** `retry` re-attempts the
  canary cycle with current spec. `promote --full` skips analysis and
  forces the canary to 100% without verification. These are very
  different operations.

- **Treating Degraded as "ArgoCD is broken."** It's not. ArgoCD
  syncs manifests. Argo Rollouts decides whether to retry. Two
  different controllers, two different responsibilities.

---

## Related

- `004-broken-canary-deliberate-gameday.md` — INC-004 GameDay record
- `slo-breach-response.md` — Prometheus / SLO breach procedures
- `docs/learning/week-5-delivery/analysistemplate-empty-data-trap.md` — empty-data bug
- `docs/learning/week-5-delivery/kustomize-crd-patches.md` — overlay patch convention
- `gitops/workloads/three-tier-app/base/backend-analysistemplate.yaml` — gate definitions
