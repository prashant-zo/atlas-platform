# ADR-009: Use stefanprodan/podinfo as Backend for Canary Validation

**Status:** Proposed
**Date:** 2026-06-07
**Author:** Prashant
**Context:** Week 6 Phase B Atlas-on-EKS deployment

---

## Context

Atlas's backend was originally a custom image (`localhost:5001/atlas-backend:v1`) built locally and pushed to kind's local registry. This image embeds business-metric emission (`http_requests_total{status, version}`, `http_request_duration_seconds_bucket`) used by Atlas's canary AnalysisTemplate.

Two problems on EKS:

1. **Image not accessible:** EKS workers cannot reach the developer's localhost registry.
2. **No public substitute is straightforward:** Generic public images (nginx, http-echo, httpbin) do not emit the specific business metrics Atlas's canary analysis evaluates.

To demonstrate Atlas's canary mechanism on EKS, we need an image that:

- Is publicly available
- Emits Prometheus-format `http_requests_total{status, ...}` metrics
- Emits `http_request_duration_seconds` histograms
- Allows configurable port (Atlas's manifest expects 5678)
- Supports the "stable vs canary" labeling pattern (we inject version via env var)

---

## Decision

**Use `ghcr.io/stefanprodan/podinfo:6.7.1` as the backend image for Atlas's canary validation on EKS and other non-kind clusters.**

The canonical reference: https://github.com/stefanprodan/podinfo

---

## Why podinfo

### What It Provides

`podinfo` is a CNCF-recognized reference application designed specifically for progressive delivery demonstrations. It is:

- The official demo workload in Flagger's documentation
- Used in countless Argo Rollouts tutorials
- Maintained by an active CNCF community
- Production-quality (handles real traffic in dozens of public demos)

### Metrics Emitted

Out of the box, podinfo exposes:

http_requests_total{method="GET", status="200"}
http_requests_total{method="POST", status="500"}
http_request_duration_seconds_bucket{...}
http_request_duration_seconds_sum
http_request_duration_seconds_count

These map directly to Atlas's AnalysisTemplate queries.

### Configuration That Matters for Atlas

| Need | podinfo provides |
|---|---|
| Listen on port 5678 | `--port=5678` flag |
| Separate metrics port | `--port-metrics=9797` flag |
| Health check endpoints | `/healthz` and `/readyz` |
| Inject version label | Via env var, podinfo reads `PODINFO_UI_MESSAGE` |
| Configurable failure injection | `/status/500` endpoint returns errors on demand |
| Configurable latency | `/delay/{seconds}` endpoint |

The failure injection capability lets Atlas demonstrate the canary's PROTECT case (refuse bad deploys) by deploying podinfo with `--port=5678` plus a fault-injection sidecar in a later session.

### Why Not Other Options

| Option | Why Not |
|---|---|
| **hashicorp/http-echo** | No `http_requests_total` metric |
| **nginxinc/nginx-prometheus-exporter** | Exposes nginx-specific metrics, not the format Atlas expects |
| **kennethreitz/httpbin** | No Prometheus metrics; listens on port 80 |
| **prom/prometheus** | Way too heavyweight; designed as monitoring infrastructure |
| **Build atlas-backend properly** | Adds container-image-build workflow on top of an already 9-hour Phase B. Defer to next session. |

### Open-Source Trust

podinfo:
- Apache 2.0 licensed
- Maintained by Stefan Prodan (FluxCD/Flagger core maintainer)
- ~5,000 stars on GitHub
- Tagged releases via GitHub Releases
- Public image on ghcr.io with SBOM

This is a reasonable trust boundary for a learning/portfolio project.

---

## Implementation

### 1. Update Backend Rollout Manifest

In `gitops/workloads/three-tier-app/base/backend-rollout.yaml`:

```yaml
containers:
  - name: backend
    image: ghcr.io/stefanprodan/podinfo:6.7.1
    args:
      - "--port=5678"
      - "--port-metrics=9797"
      - "--level=info"
    ports:
      - name: http
        containerPort: 5678
        protocol: TCP
      - name: metrics
        containerPort: 9797
        protocol: TCP
    env:
      - name: PODINFO_UI_MESSAGE
        value: "Atlas Backend on EKS"
      - name: VERSION
        value: "v2"
    # ... existing readiness/liveness probes (still target port 5678)
    # ... existing resources, env from configmap/secrets
```

### 2. Update Service Configuration (if Needed)

Atlas's `backend-svc` service should already expose port 5678. No change needed for the data path.

For metrics scraping, the existing ServiceMonitor `backend` should be updated to scrape port 9797 (podinfo's metrics port). If the ServiceMonitor currently uses port 5678 for metrics, we either update the ServiceMonitor or add the `prometheus.io/scrape: "true"` annotation pointing to port 9797.

### 3. Generate Traffic for Canary Analysis

Atlas already includes a `traffic-generator` CronJob that runs every minute, sending requests to the backend Service. This will fan out traffic to canary and stable pods according to their setWeight values. No change needed.

### 4. Observe the Canary

Once deployed, the canary will progress through 6 steps:
- Step 0: setWeight=25 → analysis evaluates with traffic flowing
- Step 1: analysis completes with Successful (≥95% success rate from podinfo)
- Step 2-5: setWeight progresses to 50, pause, 75, pause
- Step 6: Full promotion to stable

---

## Consequences

### Positive

- Demonstrates **successful canary promotion** with real metrics
- No build infrastructure needed
- CNCF-aligned reference implementation
- Reproducible across kind, EKS, GKE, AKS
- Documents the canary protection narrative end-to-end
- Atlas's safety mechanism + happy-path proof in one Rollout

### Negative

- Backend image is no longer "Atlas's own code." It's a placeholder, even if a high-quality one.
- Adds a dependency on `ghcr.io/stefanprodan/podinfo` image being available. If podinfo's repo goes offline, our manifests break.
- For "this is my real backend service" demos, a future ADR-010 could specify building atlas-backend properly with the same metrics signature.

### Neutral

- The original atlas-backend image's port (5678) and metric signature are preserved. If we later build a custom atlas-backend, it can drop in without manifest changes elsewhere in Atlas.

---

## Alternatives Considered

### Alternative 1: Build atlas-backend as a Real Image

Write a small Go service (~100 lines), build with Docker, push to ghcr.io/prashant-zo/atlas-backend.

- **Pros:** Authentic "this is Atlas" implementation. Demonstrates Docker build → GHCR push workflow.
- **Cons:** Adds ~30-60 min of work on top of an already long Phase B. Image build requires Docker daemon running on M1 Mac (already running for Colima). Requires GHCR auth setup.
- **Decision:** Defer to Phase B Take 2. Add as a future ADR-010 if pursued.

### Alternative 2: Skip Canary Analysis (Disable in Manifest)

Remove the `analysis` step from the Rollout's canary strategy.

- **Pros:** Simple. Rollout would complete without metrics.
- **Cons:** Defeats the entire point. Demonstrates nothing about canary protection.
- **Decision:** Rejected. The canary mechanism is the whole reason Atlas exists.

### Alternative 3: Force Promote Past Failed Analysis

Use `kubectl argo rollouts promote backend --full` to bypass the abort.

- **Pros:** Shows all green dashboards.
- **Cons:** Bypasses safety. Hides the canary success story. Wrong lesson.
- **Decision:** Rejected. See `docs/learning/week-6-eks/canary-analysis-correct-abort.md`.

---

## Compliance and Reversibility

This ADR can be reversed by:

1. Reverting the `backend-rollout.yaml` to a different image
2. Updating ServiceMonitor / scrape config back to original port
3. Re-syncing via ArgoCD

No state is locked in; podinfo is purely a runtime container choice.

---

## References

- podinfo source and docs: https://github.com/stefanprodan/podinfo
- Argo Rollouts canary analysis: https://argoproj.github.io/argo-rollouts/features/analysis/
- Atlas canary AnalysisTemplate: `gitops/workloads/three-tier-app/base/analysis-template.yaml`
- Phase B status report: `docs/learning/week-6-eks/phase-b-status-and-plan.md`
- Why we don't bypass canary: `docs/learning/week-6-eks/canary-analysis-correct-abort.md`

