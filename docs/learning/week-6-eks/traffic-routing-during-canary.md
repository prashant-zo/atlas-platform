# Canary Traffic Must Flow Through The Ingress, Not The Service

**Date:** 2026-06-08
**Context:** Week 6 Phase A debug session, EKS
**Status:** Production-grade lesson — applies to any Argo Rollouts + NGINX canary

---

## The Bug In One Sentence

The `traffic-generator` CronJob was hitting `backend-svc` directly,
which during a canary points only at stable pods, so canary pods
received zero traffic and the AnalysisRun's success-rate query
evaluated against an empty dataset.

## How Argo Rollouts Splits Traffic With NGINX

When a Rollout has `trafficRouting.nginx` configured:

```yaml
strategy:
  canary:
    stableService: backend-svc
    canaryService: backend-svc-canary
    trafficRouting:
      nginx:
        stableIngress: backend
```

During a canary cycle, Argo Rollouts performs three operations:

1. **Patches Service selectors.** `backend-svc`'s selector is mutated
   to match ONLY stable pods (via the `rollouts-pod-template-hash`
   label). `backend-svc-canary`'s selector matches ONLY canary pods.
   This is dynamic — selectors are patched at each canary step.

2. **Duplicates the Ingress.** The `backend` Ingress is cloned as
   `backend-canary`, with annotations:

       nginx.ingress.kubernetes.io/canary: "true"
       nginx.ingress.kubernetes.io/canary-weight: "25"

   The clone routes to `backend-svc-canary` instead of `backend-svc`.

3. **Lets NGINX do the split.** NGINX ingress-nginx-controller sees
   two Ingress objects with the same host. The canary annotation
   tells NGINX to route N% of matching traffic to the canary Service.

**The split happens at the ingress layer.** The Services themselves
just point at their respective pod sets.

## Why Direct Service Access Breaks This

If a client hits `backend-svc:3000` directly (bypassing the ingress):

- The request goes straight to the Service
- Service routes to its current backing pods
- During canary, those backing pods are STABLE only (selector patched)
- Canary pods receive zero requests from this client

The canary-weight annotations are completely invisible to in-cluster
clients that resolve `backend-svc` via cluster DNS. They only apply
to traffic that traverses the NGINX ingress controller.

## The Symptom Chain

For Atlas's AnalysisTemplate, the chain was:

1. `traffic-generator` CronJob curls `http://backend-svc:3000/`
2. Service routes 100% to stable pods (Argo Rollouts patched selector)
3. Canary pods record zero requests
4. ServiceMonitor scrapes canary pods → no `http_requests_total` series
   with `job="backend-svc-canary"`
5. AnalysisRun query:
   `sum(rate(http_requests_total{job="backend-svc-canary"}[2m]))`
   returns no data
6. The `OR on() vector(0)` fallback in our query returns 0
7. `0 >= 0.95` evaluates false
8. AnalysisRun: Failed, Rollout: Degraded

This happened for every push, including pushes where the canary code
was identical to the stable code. The canary deployment looked broken
when actually nothing was being measured at all.

## The Fix

Hit the ingress, not the Service. From in-cluster clients, that means:

```yaml
- name: curl
  command:
    - sh
    - -c
    - |
        TARGET="http://ingress-nginx-controller.ingress-nginx.svc:80/"
        HOST_HEADER="backend.atlas.local"
        curl -sS -o /dev/null -m 5 -H "Host: ${HOST_HEADER}" "$TARGET" || true
```

The Host header is required because NGINX matches Ingress rules by
hostname. Without it, the request doesn't match the `backend` Ingress
rule and NGINX returns a default 404.

This is also why `load-tests/k6/backend-canary-load.js` already uses
this pattern — k6 has always been correct. The traffic-generator was
written before the canary mechanism existed and was never updated.

## Verification

During a canary cycle, Prometheus should show traffic to BOTH services:

```promql
sum by (job) (rate(http_requests_total[2m]))
```

Expected:
- `{job="backend-svc"}`         > 0  (stable Service traffic)
- `{job="backend-svc-canary"}`  > 0  (canary Service traffic)

If only one job has data, traffic isn't flowing through the canary
split. Diagnose by checking:

1. Is the traffic source hitting the ingress (not the Service)?
2. Does the request carry the correct Host header?
3. Has Argo Rollouts created the `backend-canary` Ingress duplicate?
   `kubectl get ingress -n three-tier-dev` should show both
   `backend` and `backend-canary` during the canary window.

## When You'd Hit The Service Directly (Anti-Pattern)

Almost never, in a production system. The only legitimate cases are:

- **Inter-microservice traffic that explicitly bypasses canary logic.**
  E.g., a batch job that should always hit stable regardless of
  canary state. Document this loudly.
- **Direct debugging via kubectl exec into a pod.** Convenient but
  doesn't test the production traffic path.

For everything else — load tests, integration tests, traffic
generators, monitoring synthetics — hit the ingress with the correct
Host header. This is the path real users take, and the path the
canary mechanism actually controls.

## Mental Model

Treat the ingress as **the only entry point to your application's
traffic plane**. Services are implementation details. The Ingress
(plus the Services it routes to) is the contract.

When you bypass the Ingress, you're not testing your application —
you're testing a part of your application's plumbing that doesn't
correspond to any user request.

## Related

- INC-005 — The debugging journey that revealed this
- `gitops/workloads/three-tier-app/base/traffic-generator.yaml` —
  Current correct configuration
- `load-tests/k6/backend-canary-load.js` — Reference implementation
- Argo Rollouts NGINX docs:
  https://argoproj.github.io/argo-rollouts/features/traffic-management/nginx/
- ADR-005 — Original progressive delivery design rationale
- ADR-014 (TODO, Phase F) — Decision record for this routing pattern
