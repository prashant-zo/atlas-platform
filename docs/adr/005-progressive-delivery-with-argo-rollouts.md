# ADR-005: Progressive Delivery with Argo Rollouts

**Date:** 2026-06-01
**Status:** Accepted
**Context:** Week 5 — Progressive Delivery

## Context

Atlas's CI/CD model is GitOps: every change to the `gitops/` tree
becomes a sync in ArgoCD, which applies the manifests to the cluster.
At Week 4 we had:

- Argo CD reconciling all workloads from the main branch
- A Postgres-backed three-tier app running in dev/staging/prod overlays
- Full observability: Prometheus + Grafana + Loki + alerts on SLO breach

The deploy mechanism, however, was a standard Kubernetes
`Deployment` with `rollingUpdate`. This means:

- A new revision rolls out across all pods simultaneously
- Failure detection relies on readinessProbe and liveness checks
- There's no concept of "10% of users hit the new version"
- Rollback requires a human noticing and running `kubectl rollout undo`

This is acceptable for non-production. For Atlas to credibly model a
production deploy story, the rollout needed to:

1. Send a fraction of traffic to the new version first
2. Evaluate real metrics on that traffic (success rate, latency)
3. Automatically advance or roll back based on the metrics
4. Keep the stable version serving 100% of users until the gate passes

This is progressive delivery. Three options were considered.

## Options Considered

### Option 1: Native Kubernetes (Deployment + rollingUpdate)

**What it offers:** Built into Kubernetes, no extra controllers, well
understood. `maxSurge`/`maxUnavailable` give some control over pod
replacement rate.

**Why it falls short for Atlas:**
- No traffic-percentage splitting — Kubernetes Services round-robin
  across all ready pods, so 1 of 4 pods being new = ~25% of traffic
  to the new version *only by coincidence of pod count*, not by
  explicit design.
- No metric-based gating. If the new version returns 500s but its
  liveness probe still passes (e.g. the app responds at /healthz but
  errors on the actual endpoint), the rollout completes successfully
  while users see errors.
- No automatic rollback on metric breach. You can hit `kubectl rollout
  undo` manually, but that's a human in the loop.
- No analysis step. The deployment progresses based on pod-readiness
  semantics, not application-level health.

This is what Atlas had through Week 4. For Atlas's portfolio narrative,
this is the baseline we wanted to move past.

### Option 2: Flagger

**What it offers:** Mature progressive delivery controller from
Weaveworks. Supports canary, blue-green, A/B testing. Integrates with
service meshes (Istio, Linkerd, App Mesh) and ingress controllers
(NGINX, Contour, Gloo). Strong analysis story with Prometheus,
Datadog, NewRelic, etc.

**Why it wasn't picked:**
- Flagger requires a service mesh or specific ingress controller
  integration. For ingress-controller-only mode (which is what Atlas
  uses with NGINX), Flagger supports NGINX but the integration is
  less rich than its mesh-based mode.
- Flagger uses a separate `Canary` custom resource alongside the
  existing `Deployment`. The `Deployment` stays the source of truth
  for the pod template, and Flagger creates a secondary deployment
  during canary. This means two resources to reason about per
  workload.
- Flagger's analysis model uses webhooks for pre/post-rollout hooks
  and Prometheus queries for gating. Powerful but adds operational
  complexity.
- The Argo ecosystem (Argo CD, Argo Workflows, Argo Rollouts) is
  designed to interoperate. Atlas already runs Argo CD as the GitOps
  engine. Using Argo Rollouts means one ecosystem, one mental model,
  one set of dashboards.

Flagger is a perfectly good choice and many teams use it successfully.
For Atlas specifically — a portfolio project built on the Argo
ecosystem — it would have added a second control plane to learn and
maintain for no clear benefit.

### Option 3: Argo Rollouts (chosen)

**What it offers:** A replacement `Rollout` CRD that supersedes
`Deployment`. Native integration with Argo CD (same project, same
maintainers). First-class canary and blue-green strategies. Built-in
traffic routing for NGINX, Istio, AWS App Mesh, Traefik, SMI. A
distinct `AnalysisTemplate` resource for metric-gated promotion.

**Why this fits Atlas:**

1. **Single ecosystem.** Argo CD reconciles `Rollout` resources just
   like it reconciles `Deployment` resources. No extra plumbing.

2. **The `Rollout` resource is a drop-in replacement for `Deployment`.**
   Same pod template syntax, same readiness/liveness probes, same
   strategy block — just a different `kind:`. Less to relearn.

3. **`AnalysisTemplate` is a reusable resource.** Define metric gates
   once, reference them from every workload's `Rollout`. Atlas has
   one `backend-canary-analysis` template that gates the backend
   canary on success rate ≥ 95% and p95 latency ≤ 500ms, both
   computed live from Prometheus during the canary window.

4. **NGINX traffic routing works without a service mesh.** Argo
   Rollouts manipulates the NGINX Ingress's `canary-weight` annotation
   to do real percentage-based traffic splitting (not the
   pod-count-coincidence model). 25% means 25% of HTTP requests, not
   "1 of 4 pods". This was important — Atlas wanted the demo to show
   *real* traffic splitting independent of pod count.

5. **Auto-rollback on analysis failure.** When `AnalysisRun` decides
   the canary failed, the controller automatically scales the new
   ReplicaSet to zero and keeps stable serving. No human intervention.

## Decision

Use **Argo Rollouts** with NGINX `trafficRouting` and a Prometheus-based
`AnalysisTemplate` for canary metric gating.

Canary steps for the backend:

\`\`\`
setWeight: 25  →  analysis (5 checks × 30s)  →  setWeight: 50
   →  pause 30s  →  setWeight: 75  →  pause 30s  →  100%
\`\`\`

Analysis evaluates two queries against Prometheus over a 2-minute
window:

1. **Success rate** (`sum(rate(2xx)) / sum(rate(all))`) — gate at ≥ 0.95
2. **P95 latency** (`histogram_quantile(0.95, ...)`) — gate at ≤ 500ms

Both queries filter on `version="{{args.canary-version}}"` so only
canary traffic is evaluated, not the aggregate of stable + canary.

## Consequences

### Positive

- **Real production-pattern deploys in a portfolio project.** Visitors
  can see canary in action, watch the AnalysisRun create itself, see
  the rollout auto-promote or auto-rollback based on real metrics.
- **The analysis story is reusable.** AnalysisTemplate becomes a
  pattern that scales to other workloads in the platform.
- **No service mesh required.** Atlas stays simple — NGINX ingress
  alone provides the traffic-splitting primitive.
- **GitOps-native.** All Rollout/AnalysisTemplate manifests live in
  `gitops/` and reconcile via ArgoCD like everything else.

### Negative

- **`Rollout` is a CRD, not a `Deployment`.** Standard kubectl tooling
  (e.g. `kubectl rollout status`) doesn't know about it. The
  `kubectl-argo-rollouts` plugin provides the equivalent CLI.
- **Strategic-merge patches don't work on Rollout pod templates.**
  Kustomize must use JSON 6902 patches with explicit `target:` blocks
  for any pod-template-level overrides in overlays. This caused real
  bugs during Week 5 — multiple overlay patches initially used
  strategic-merge syntax and silently dropped fields. Documented in
  `docs/learning/week-5-delivery/kustomize-crd-patches.md`.
- **Prometheus queries against empty data return `[]`.** When a
  canary starts with no traffic yet, the controller panics on empty
  vectors. Queries must use `OR on() vector(0)` as a fallback, and
  `initialDelay` should be set on each metric so the histogram has
  time to populate. Documented in
  `docs/learning/week-5-delivery/analysistemplate-empty-data-trap.md`.
- **One more CRD to learn.** `Rollout`, `AnalysisTemplate`,
  `AnalysisRun`, `Experiment`, `ClusterAnalysisTemplate`. The team
  needs to internalize the data model.

### Neutral

- **Argo Rollouts has a dashboard.** Available at `rollouts.atlas.local`
  in dev. Visualizes the canary state in real time. Useful for demos
  and onboarding but not strictly necessary — the CLI shows the same
  state.

## Validation

The chosen approach was validated through three real canary deployments
during Week 5:

1. **Successful auto-promote.** v1 → v2 (env var change only).
   Canary started, traffic split 25%, AnalysisRun queried Prometheus
   5 times over 2.5 minutes, all checks passed (success rate 100%,
   p95 latency 4.75ms), rollout auto-advanced through 50% → 75% →
   100% and marked Healthy. No human intervention.

2. **Auto-rollback on empty-data error.** First attempt of v2 canary
   failed because the p95 query returned an empty vector before
   traffic had accumulated. The controller correctly treated this as
   an Error (not Failed) and exceeded `consecutiveErrorLimit`,
   triggering automatic rollback. Stable v1 ReplicaSet was preserved
   throughout. This was the safety mechanism working — the bug was
   in our query, not the rollback logic.

3. **Load test under canary**. k6 load test sustained 100 RPS for
   5 minutes through the NGINX ingress while the canary was in place.
   p95 latency 6.37ms end-to-end, 0 errors out of 32,555 requests.
   See `docs/learning/week-5-delivery/k6-load-test-results.md`.

## Related Documents

- `gitops/workloads/three-tier-app/base/backend-rollout.yaml` — Rollout spec
- `gitops/workloads/three-tier-app/base/backend-analysistemplate.yaml` — gates
- `docs/learning/week-5-delivery/kustomize-crd-patches.md` — overlay bug
- `docs/learning/week-5-delivery/analysistemplate-empty-data-trap.md` — startup bug
- `docs/learning/week-5-delivery/k6-load-test-results.md` — load benchmark
