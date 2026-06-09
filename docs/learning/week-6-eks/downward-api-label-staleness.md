# Downward API + Rollout Promotion = Stale Labels In Metrics

**Date:** 2026-06-08
**Context:** Week 6 Phase A, debugging post-traffic-generator-fix
**Status:** Production-grade lesson — applies to any controller that mutates pod labels

---

## The Pattern That Looks Right

A common Argo Rollouts setup uses canaryMetadata and stableMetadata
to label pods by their role:

```yaml
strategy:
  canary:
    canaryMetadata:
      labels:
        rollout-pod-template-hash-version: canary
    stableMetadata:
      labels:
        rollout-pod-template-hash-version: stable
```

You then plumb this into the container env via the Downward API so
your app emits role-tagged metrics:

```yaml
containers:
  - name: backend
    env:
      - name: VERSION
        valueFrom:
          fieldRef:
            fieldPath: metadata.labels['rollout-pod-template-hash-version']
```

The app reads VERSION at startup and uses it as a Prometheus label:

```go
httpRequestsTotal := promauto.NewCounterVec(prometheus.CounterOpts{
    Name: "http_requests_total",
}, []string{"version", "status"})

version := os.Getenv("VERSION") // "canary" or "stable"
httpRequestsTotal.WithLabelValues(version, "200").Inc()
```

This is documented as a valid Argo Rollouts integration pattern.
ADR-009 (Atlas) originally adopted this exact approach.

## Why It Fails After Promotion

The Downward API has a behavior that's easy to miss: **`fieldRef`
reads pod metadata at container creation time only**. After that,
the env var is a normal string in the container's process
environment. Subsequent mutations to the pod's labels do not
propagate.

Argo Rollouts mutates pod labels DURING the canary lifecycle:

- T=0: Canary pod created with label `version: canary`
- T=0: Downward API reads label, sets env `VERSION=canary`
- T=0: Container starts, Go process reads env, caches "canary"
- T=0..5min: Pod serves canary traffic, emits `version="canary"` metrics
- T=5min: Canary analysis passes, Argo Rollouts promotes
- T=5min: Argo Rollouts patches pod's label: `version` → `stable`
- T=5min: **The env var stays "canary"** (Downward API is one-shot)
- T=5min+: Pod serves stable traffic, still emits `version="canary"`

The pod is now stable-by-label but canary-by-metric-emission. There
is no way for the running Go process to know its label was changed.

## How To Verify The Drift Directly

For any pod that has gone through promotion:

```bash
POD=$(kubectl get pods -n three-tier-dev -l app=backend -o jsonpath='{.items[0].metadata.name}')

# Current pod label
kubectl get pod -n three-tier-dev "$POD" \
  -o jsonpath='{.metadata.labels.rollout-pod-template-hash-version}'

# Container env spec (still references the label)
kubectl get pod -n three-tier-dev "$POD" \
  -o jsonpath='{.spec.containers[?(@.name=="backend")].env[?(@.name=="VERSION")]}' | jq .

# What the process actually has (via an endpoint that returns the env)
kubectl port-forward -n three-tier-dev "$POD" 5678:5678 &
curl -s http://localhost:5678/healthz
```

You'll see:
- Label: `stable`
- Env spec: fieldRef to that label
- Process value: `canary` (the original)

## Why This Broke The AnalysisRun

The AnalysisTemplate query was originally:

```promql
sum(rate(http_requests_total{
  version="{{args.canary-version}}",   # "canary"
  status=~"2.."
}[2m]))
```

The query expected `version="canary"` to identify canary pods. But:

- Old stable pods (pre-downward-API) had literal `version="v2"` env
- New stable pods (post-canary, post-promotion) had stale
  `version="canary"` env
- During the active canary window, NEW canary pods correctly had
  `version="canary"` env

So the query DID match active canary pods correctly DURING the
canary cycle. The problem was that it ALSO matched the previous
canary's pods (now stable) — but those pods are no longer in
`backend-svc-canary`'s Service endpoints, so they don't show up in
queries scoped to canary traffic.

Wait — so why did the query fail?

It failed because of the FIRST bug (traffic-generator hitting Service
directly). With no canary traffic, there were no canary-scoped
metrics. The version-label drift would have caused subtle wrongness
in post-promotion ad-hoc queries, but for the AnalysisRun itself,
during the canary window, the version label was correct.

**However:** the version-label drift was waiting to bite us. Once we
fixed Bug #1 (traffic) and the canary went through a successful
promotion, the now-stable pods would have stale `version="canary"`
labels, contaminating any future query that tried to use version
to filter. The right fix was to remove the version-label dependency
entirely.

## The Better Pattern: Filter By `job`

Instead of deriving role from pod labels, derive it from the
Service that scraped the pod. Prometheus' ServiceMonitor convention
sets a `job` label on every scraped metric, named after the
scraping Service.

```promql
sum(rate(http_requests_total{
  job="backend-svc-canary",
  status=~"2.."
}[2m]))
```

This is robust because:

- Argo Rollouts dynamically patches `backend-svc-canary`'s
  selector to match canary pods during the cycle
- Argo Rollouts dynamically patches `backend-svc`'s selector to
  match stable pods
- ServiceMonitor scrapes through both Services
- The `job` label on each metric reflects which Service scraped it
- When Argo Rollouts re-patches selectors on promotion, the next
  scrape will correctly attribute metrics to the right job

The label updates dynamically with each scrape. There is no
"creation time vs runtime" drift because the label isn't sourced
from the pod at all — it's sourced from the scrape target.

## When Downward API IS Still Appropriate

The pattern is fine for metadata that genuinely doesn't change after
pod creation:

- `metadata.name` → POD_NAME env (useful for logs)
- `metadata.namespace` → NAMESPACE env
- `metadata.uid` → POD_UID env
- `spec.nodeName` → NODE_NAME env

These are immutable for the lifetime of the pod. Downward API works
perfectly.

The pattern breaks when used for ANY metadata a controller might
mutate post-creation. Argo Rollouts is one such controller. Others:

- `kubectl label pod ...` (manual relabeling)
- Mutating admission webhooks that add labels
- Operators that retag pods based on cluster state

If your metric depends on the CURRENT value of a label that something
external might change, don't use Downward API. Use a Prometheus
relabeling rule, a ServiceMonitor label injection, or filter by a
label that originates outside the pod (like `job`).

## The Lesson

Downward API has a time dimension that isn't obvious from the
documentation. "fieldRef reads at container creation" is correct, but
the implication for controllers that mutate labels isn't spelled out.

For metrics: derive role/identity labels from the SCRAPE SOURCE
(Service-based), not from the SCRAPED OBJECT's own labels. This
ensures the label updates whenever the topology updates.

## Related

- INC-005 — The debugging journey that surfaced this
- `docs/learning/week-6-eks/traffic-routing-during-canary.md` — Bug #1
- ADR-009 — Original downward API decision (now superseded)
- ADR-013 (TODO, Phase F) — Decision record for job-label filtering
- Kubernetes Downward API docs:
  https://kubernetes.io/docs/concepts/workloads/pods/downward-api/
- Argo Rollouts canaryMetadata/stableMetadata docs:
  https://argoproj.github.io/argo-rollouts/features/canary/
- `gitops/workloads/three-tier-app/base/backend-analysistemplate.yaml` —
  Current correct query
