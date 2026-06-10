# ADR-011: Per-Env Canary Isolation Via Ingress Hosts + AnalysisTemplate Scoping

**Status:** Accepted
**Date:** 2026-06-10
**Author:** Prashant
**Context:** Week 6 multi-env GitOps sprint (Day 1 canary isolation demos)

---

## Context

With three envs (dev / staging / prod) running side-by-side on a single EKS cluster, Atlas's canary mechanism needs to operate independently in each env. A canary triggered in staging must not:

- Receive traffic intended for dev or prod
- Be evaluated against dev or prod's metrics
- Cause an abort signal that propagates to other envs
- Have its failure masked by another env's healthy metrics

This isolation is the core multi-env safety property. Without it, "three envs on one cluster" is just three workloads sharing a control plane — no real separation.

Three risks needed to be addressed:

1. **Traffic routing collision.** Argo Rollouts uses an Ingress + canary Service split. If every env's Ingress declares the same Host (`backend.atlas.local`), NGINX picks one arbitrarily and traffic mixes across envs.

2. **Metric query bleed.** AnalysisTemplate queries Prometheus for `http_requests_total{job="backend-svc-canary"}`. The `backend-svc-canary` Service exists in every env's namespace, so without a namespace filter, the query aggregates across all three envs.

3. **Service-label observability quirk.** Even with namespace filters in queries, Prometheus still scrapes `backend-svc-canary` in every env. A naive dashboard that shows "canary RPS by env" will look like all three envs have traffic at all times (because the Services exist) when in reality only one canary is active.

These risks were latent before multi-env. With only dev running, no one noticed. Adding staging and prod exposed them.

---

## Decision

**Implement three isolation mechanisms per env, layered:**

1. **Per-env Ingress host.** Each env declares a unique Host:
   - dev: `backend.atlas.local`
   - staging: `backend-staging.atlas.local`
   - prod: `backend-prod.atlas.local`

2. **Per-env AnalysisTemplate namespace filter.** Inject `namespace="three-tier-{env}"` into both PromQL queries (success-rate and p95-latency) via a JSON 6902 overlay patch.

3. **Per-env traffic generator Host header.** The `traffic-generator` CronJob's curl command sets the Host header to the env-specific Ingress host, ensuring synthetic baseline traffic stays in its lane.

All three are applied via Kustomize overlay patches (see ADR-010). The base manifests remain env-neutral.

---

## Mechanism Details

### 1. Per-Env Ingress Host

Base `ingress.yaml`:

```yaml
spec:
  rules:
    - host: backend.atlas.local           # placeholder, base uses dev's value
      http:
        paths:
          - path: /
            ...
```

Overlay patch (JSON 6902, prod example):

```yaml
- op: replace
  path: /spec/rules/0/host
  value: backend-prod.atlas.local
```

NGINX's name-based virtual hosting then routes by `Host:` header. Three distinct Ingress objects, three distinct hosts, no collision.

For local testing without DNS:

```bash
curl -H "Host: backend-staging.atlas.local" http://<ingress-controller-ip>/
```

In a real production setup, these would be proper DNS records pointing at the same ALB. The "Host header switching" is the same mechanism either way; only the resolution layer differs.

### 2. Per-Env AnalysisTemplate Namespace Filter

Base `analysis-template.yaml` query (success-rate):

```yaml
- name: success-rate
  provider:
    prometheus:
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
```

Overlay patch (JSON 6902, prod example):

```yaml
- op: replace
  path: /spec/metrics/0/provider/prometheus/query
  value: |
    (
      sum(rate(http_requests_total{
        job="backend-svc-canary",
        namespace="three-tier-prod",          # ← injected here
        status=~"2.."
      }[2m]))
      /
      sum(rate(http_requests_total{
        job="backend-svc-canary",
        namespace="three-tier-prod"
      }[2m]))
    ) OR on() vector(0)
```

Same pattern for the p95-latency query (metric index 1).

Without this patch, prod's canary AnalysisRun would evaluate against ALL three envs' canary traffic. If dev's canary is healthy and prod's is failing, the aggregate success rate could still cross the 0.99 threshold, and prod's bad deploy would auto-promote despite returning 50% errors in its own namespace. Critical safety failure.

### 3. Per-Env Traffic Generator Host Header

The `traffic-generator` CronJob sends 1 RPS for 55 seconds per minute to the ingress, providing baseline traffic for AnalysisRun queries. Without a Host header, NGINX returns 404 (no default backend matches). With the wrong Host header, traffic lands on the wrong env's Ingress.

Base CronJob:

```yaml
command: ["sh", "-c"]
args:
  - |
    HOST_HEADER="backend.atlas.local"
    end=$(($(date +%s) + 55))
    while [ "$(date +%s)" -lt "$end" ]; do
      curl -sS -o /dev/null -m 5 -H "Host: ${HOST_HEADER}" "$TARGET" || true
      sleep 1
    done
```

Overlay patch (JSON 6902, prod example):

```yaml
- op: replace
  path: /spec/jobTemplate/spec/template/spec/containers/0/command/2
  value: |
    HOST_HEADER="backend-prod.atlas.local"
    ...
```

The path `/spec/jobTemplate/.../command/2` targets the shell-script body in the CronJob's command array. Index 2 because the command is `["sh", "-c", "<script>"]`.

---

## The Service-Label Quirk (Documented, Not Fixed)

Prometheus scrapes `backend-svc-canary` in every namespace, regardless of whether a canary is active. The Service object exists permanently as part of the Rollout's traffic-splitting mechanism. So:

```promql
sum by (namespace) (rate(http_requests_total{job="backend-svc-canary"}[2m]))
```

Returns three series — one per env — even when only one env has an active canary. This makes naive dashboards look like all three envs always have canary traffic.

The underlying mechanism:

- `backend-svc-canary` Service is created by the Rollout controller in every env
- The Service has a selector that matches the canary ReplicaSet's pod template hash
- When no canary is active, the selector matches zero pods, so the Service has no endpoints
- But Prometheus still scrapes the Service (the ServiceMonitor selects it by label, not by endpoint count)
- The scrape job returns metrics for any pod that ever served traffic on that port (the stable ReplicaSet pods, since they have the right port and metrics scrape annotation)

Result: metric `http_requests_total{job="backend-svc-canary", namespace="three-tier-dev"}` returns non-zero numbers from stable pods, not canary pods, even when no canary is running.

This does not affect correctness:

- The AnalysisTemplate query SUMS rate over the 2-minute window. Stable's contribution is steady-state baseline.
- During a real canary, the canary pods contribute additional samples that change the success-rate ratio.
- If canary returns 50% errors, that's reflected in the ratio regardless of stable's contribution.

It does affect observability:

- Dashboards need to interpret "canary RPS by env" as "RPS to backend-svc-canary Service by env" — which is the same number as backend-svc RPS minus the proportion routed to stable's direct service entries.

We document this in `docs/learning/week-6-eks/multi-env-canary-isolation-demo.md`. It's a known quirk, not a bug.

---

## Verification

The isolation was empirically demonstrated by the matrix tests in Day 2:

| Test | Trigger | Other envs' state |
|---|---|---|
| Dev success canary | LATENCY_MS=5 in dev overlay | Staging + prod pod template hashes unchanged across 4 snapshots over ~5 min |
| Staging abort canary | FAIL_RATE=0.5 + k6 88 RPS | Dev + prod pod template hashes unchanged across 3 snapshots over ~3 min |

In both cases:

- Dev's AnalysisRun query returned correct env-scoped success rate
- All 3 SLO recording rules remained at 1.0 (no cross-env contamination)
- The aborting env's canary failed and was Degraded; the other two envs remained ✔ Healthy

Full details: `docs/learning/week-6-eks/multi-env-canary-isolation-demo.md` and `multi-env-gitops-day-2.md`.

---

## Consequences

### Positive

- **True per-env canary independence.** A bad deploy in prod cannot be masked by healthy dev metrics, and a dev experiment cannot trigger alerts in prod.
- **Standard CNCF pattern.** Per-env Ingress hosts + namespace-scoped metric queries are how every multi-env Prometheus + ingress-controller setup works in production.
- **Reusable for future envs.** Adding a fourth env requires only an overlay change with the same three patches.
- **Documented failure modes.** The Service-label quirk is captured so future operators don't misread dashboards.

### Negative

- **Three patches per env.** Anyone adding a new env must remember all three (host, AnalysisTemplate, traffic-gen). Mitigation: the 12-check verification suite confirms all three are present.
- **The Service-label quirk is real.** Without context, the "all envs have canary traffic" appearance can confuse a new reviewer. Documentation is the only fix.
- **JSON 6902 array indexes again.** The traffic-generator patch references `command/2`. Reordering the command array in the base would break overlays.

### Neutral

- **DNS not required for the demo.** Ingress hosts can be tested via curl `-H Host:` header. Production deployment would add proper DNS, but the isolation mechanism doesn't change.

---

## Alternatives Considered

### Alternative 1: One Ingress, One Host, Path-Based Routing

Use `/dev/`, `/staging/`, `/prod/` prefixes on the same host.

- **Pros:** Single Ingress object across envs (less duplication).
- **Cons:** Argo Rollouts canary splitting uses an entire Service per Ingress rule. Path-based routing breaks the Service mapping. Plus, prod traffic on the same host as dev makes accidental cross-contamination easier ("oh, I forgot the /prod/ prefix").
- **Decision:** Rejected.

### Alternative 2: Service Selectors With `env` Label

Add `env: dev/staging/prod` labels and use ServiceMonitor's `namespaceSelector` + `selector.matchLabels` to scope metrics.

- **Pros:** Pulls scoping out of the AnalysisTemplate (less per-env patching).
- **Cons:** Requires labeling every Service in every env consistently. ServiceMonitor's `namespaceSelector` doesn't help if metrics flow through Prometheus's job label (which depends on the ServiceMonitor's name, not the Service's labels). Still ends up requiring some form of namespace filter in the PromQL.
- **Decision:** Rejected as too implicit. The explicit `namespace="three-tier-X"` filter in the AnalysisTemplate query is the clearest expression of intent.

### Alternative 3: Per-Env Prometheus Instances

Run a separate Prometheus per env, each scraping only its own namespace.

- **Pros:** Hard physical isolation. No cross-env metric query possible.
- **Cons:** Three Prometheus instances. Three sets of ServiceMonitors. Federated query if you want cross-env dashboards. Resource overhead (~1GB memory × 3). Doesn't change the AnalysisTemplate problem because each env's Prometheus still needs to be addressed.
- **Decision:** Rejected. Overkill for a single-cluster demo.

### Alternative 4: No Isolation, Trust Naming Conventions

Hope that operators always use the right env in their tooling.

- **Pros:** Less YAML.
- **Cons:** Bugs in dev metrics would mask prod canary failures. The whole point of canary is automated safety. "Hoping" undermines it.
- **Decision:** Rejected.

---

## Compliance and Reversibility

This ADR can be reversed by:

1. Remove the three per-env patches from each overlay's `kustomization.yaml`
2. Revert each overlay's patch files
3. Re-sync ArgoCD

The base manifests remain env-neutral, so reverting just removes the env-specific overrides. dev would still work with the base defaults; staging and prod would inherit dev's host and metric scope (which is the unsafe state we're escaping from).

Total reversal work: ~30 min. We're not locked in.

---

## References

- Argo Rollouts canary with Ingress: https://argoproj.github.io/argo-rollouts/features/traffic-management/nginx/
- Argo Rollouts AnalysisTemplate: https://argoproj.github.io/argo-rollouts/features/analysis/
- Prometheus operator ServiceMonitor: https://github.com/prometheus-operator/prometheus-operator/blob/main/Documentation/api.md#monitoring.coreos.com/v1.ServiceMonitor
- Day 1 isolation demo: `docs/learning/week-6-eks/multi-env-canary-isolation-demo.md`
- Day 2 matrix tests: `docs/learning/week-6-eks/multi-env-gitops-day-2.md`
- ADR-005 (Argo Rollouts) — base canary design
- ADR-010 (Kustomize overlays) — how these patches are applied
