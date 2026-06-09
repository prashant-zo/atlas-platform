# Multi-Env Canary Isolation Demo — Phase 1 + Phase 2 Captured

**Date:** 2026-06-09
**Cluster:** atlas-eks-dev (4× t3.large spot, ap-south-1)
**Envs live during demo:** three-tier-dev (4 backend pods),
                            three-tier-staging (2 backend pods)
**Status:** Both demos captured. Cluster destroyed at end of session.

---

## What Was Demonstrated

Two independent canary outcomes on staging, while dev remained
completely untouched. This proves multi-env GitOps isolation works
at every layer: namespace, ingress host, metric scoping, and
Rollout state.

### Phase 1 SUCCESS — staging canary promotes

**Trigger:** JSON 6902 overlay patch
`overlays/staging/canary-trigger-latency-patch.yaml` sets
LATENCY_MS=5 on the Rollout's backend container env (index 3).

**Outcome:** Argo Rollouts detected the spec change as revision 2.
The canary cycle ran:

    Step 1: setWeight 25%   → canary pod (rev 2) Ready, gets ~25% traffic
    Step 2: AnalysisRun     → 5 measurements over 90s
                              success-rate query (namespace="three-tier-staging") ≈ 1.0
                              p95-latency query (namespace="three-tier-staging") << 500ms
                              ✔ 10 (10 measurements all passed)
    Step 3: setWeight 50%   → promoted
    Step 4: pause 30s
    Step 5: setWeight 75%   → promoted
    Step 6: pause 30s → setWeight 100% → revision 2 became stable

**Captured state (Phase 1):**

    Name:      backend
    Namespace: three-tier-staging
    Status:    ✔ Healthy
    Strategy:  Canary
      Step:    6/6
      SetWeight:     100
      ActualWeight:  100
    Images:    ghcr.io/prashant-zo/atlas-backend:6e501b6 (stable)
    Replicas:  Desired 2 / Current 4 / Updated 2 / Ready 4 (during scaledown delay)
    
    revision:2 backend-b77fd487d ✔ Healthy   stable
      AnalysisRun ✔ Successful ✔ 10
    revision:1 backend-644d8cdc67 ScaledDown  delay:4m44s

**Time to promote:** ~5 min.

### Phase 2 ABORT — staging canary fails

**Trigger:** Added second JSON 6902 patch
`overlays/staging/canary-trigger-failrate-patch.yaml` setting
FAIL_RATE=0.5 on the Rollout's backend container env (index 2).
Combined with the already-applied LATENCY_MS=5 from Phase 1, this
created revision 3 with FAIL_RATE=0.5, LATENCY_MS=5.

**Load applied during canary:** k6 (parameterized — Block 2D pulled
forward from Day 2):

    NAMESPACE=three-tier-staging \
    HOST_HEADER=backend-staging.atlas.local \
    ./load-tests/k6/run.sh

k6 generated ~88 RPS for ~6 minutes against staging's ingress.

**Outcome:** Argo Rollouts detected revision 3. Canary started:

    Step 1: setWeight 25%   → canary pods (rev 3) Ready, get ~25% traffic
                              ~50% of those responses are 500 errors
                              (backend's FAIL_RATE simulation)
    Step 2: AnalysisRun     → 2 measurements before threshold breach
                              success-rate query ≈ 0.5
                              fails threshold (>= 0.99, failureLimit: 1)
                              ✔ 2, ✖ 2  (4 measurements: 2 passed, 2 failed)
    Auto-abort               → revision 3 ReplicaSet scaled to 0
                              stable (rev 2) continues serving 100% traffic

**Captured state (Phase 2):**

    Name:      backend
    Namespace: three-tier-staging
    Status:    ✖ Degraded
    Message:   RolloutAborted: Rollout aborted update to revision 3:
               Metric "success-rate" assessed Failed due to failed (2)
               > failureLimit (1)
    Step:      0/6
    SetWeight: 0
    Images:    ghcr.io/prashant-zo/atlas-backend:6e501b6 (stable)
    Replicas:  Desired 2 / Current 2 / Updated 0 / Ready 2 / Available 2
    
    revision:3 backend-676869cc4f  ScaledDown   canary,delay:passed
      AnalysisRun ✖ Failed ✔ 2,✖ 2
    revision:2 backend-b77fd487d   ✔ Healthy   stable (still serving)
      AnalysisRun ✔ Successful ✔ 10
    revision:1 backend-644d8cdc67  ScaledDown

**Time to abort:** ~3 min from canary start to Degraded.

---

## Isolation Guarantees Proven

Throughout BOTH phases, dev remained completely untouched. This is
the critical multi-env property the Atlas architecture is built to
demonstrate.

| Layer | Mechanism | Verified by |
|-------|-----------|-------------|
| **Rollout state** | Overlay patch in staging/ only | Dev backend Rollout: Status ✔ Healthy, Step 6/6, 4/4 Ready, image atlas-backend:6e501b6 — unchanged throughout |
| **Pod template hash** | Distinct ReplicaSets per env | Dev pods stayed on `d5b565696`, staging cycled through `b77fd487d` and `676869cc4f` |
| **Namespace** | `namespace: three-tier-staging` in Kustomize | All staging resources confined to three-tier-staging namespace; nothing leaked to three-tier-dev |
| **Ingress host** | Per-env Ingress host patch | Dev: `backend.atlas.local`, Staging: `backend-staging.atlas.local`. NGINX routed by Host header |
| **AnalysisRun metric scope** | `namespace="three-tier-staging"` filter in PromQL via JSON 6902 patch on AnalysisTemplate | Staging's AnalysisRun ONLY measured staging's canary metrics — dev's metrics could not mask staging's failure or success |
| **ServiceMonitor scope** | namespaceSelector REMOVED from base; Prometheus Operator defaults to same-namespace | Each env's ServiceMonitor scrapes only its own backend Service |
| **k6 traffic targeting** | NAMESPACE + HOST_HEADER env vars at apply time | k6 traffic against staging only reached staging's backend; dev's metrics did not show k6's load |

---

## Architecture That Made This Possible

The work delivered today across Blocks 1A-1G + early 2D made the
isolation possible:

- **Block 1C-SCALE:** node group scaled to 4× t3.large so two full
  three-tier stacks could coexist without resource pressure
- **Block 1D-BASE:** removed dev-only namespaceSelector from base
  ServiceMonitor; added dev AnalysisTemplate namespace filter
- **Block 1E-STG-OVERLAY:** rebuilt staging overlay from stale
  Week 5 state to match dev's correct pattern:
    - Replaced hashicorp/http-echo with
      ghcr.io/prashant-zo/atlas-backend:6e501b6
    - Split Rollout patches to JSON 6902 (avoiding the documented
      strategic-merge CRD trap)
    - Added per-env ingress-host patch (backend-staging.atlas.local)
    - Added per-env traffic-generator Host header patch
    - Added per-env AnalysisTemplate namespace filter patch
- **Block 1F-EN-STG:** parameterized sync-wave in non-prod
  ApplicationSet, enabled staging at wave 2 (dev=1, staging=2) so
  CNPG webhook load is staggered
- **Block 2D (pulled forward):** parameterized k6 to accept
  NAMESPACE + HOST_HEADER env vars; backend-canary-load-job.yaml
  no longer hardcoded to dev

---

## Commits Landed Today (Session Snapshot)

    feat(eks): scale node group to 4 nodes for multi-env capacity
    feat(multi-env): prepare base + dev for multi-env coexistence (4d53d14)
    feat(multi-env): rebuild staging overlay for EKS multi-env deployment (9d3c5f3)
    feat(multi-env): enable staging in non-prod ApplicationSet (dc9bc98)
    docs(week-6): capture multi-env CNPG bootstrap timing (9372ae6)
    demo(staging): Phase 1 — trigger canary via LATENCY_MS=5
    feat(k6): parameterize load test for any env (dev/staging/prod)
    demo(staging): Phase 2 — trigger ABORT via FAIL_RATE=0.5 (43bfa16)
    demo(staging): Phase 2 ABORT revert — return staging to Healthy (51cb89c)

---

## State At Session End (Before Teardown)

    kubectl get applications -n argocd
    
    platform-argo-rollouts     Synced  Healthy
    platform-cnpg-operator     Synced  Healthy
    platform-ingress-nginx     Synced  Healthy
    platform-kube-prometheus   Synced  Healthy
    platform-loki              Synced  Healthy
    platform-metrics-server    Synced  Healthy
    root-app-of-apps           Synced  Healthy
    three-tier-dev             Synced  Healthy
    three-tier-staging         Synced  Healthy

    Dev backend Rollout:     ✔ Healthy, Step 6/6, 4/4 Ready
    Staging backend Rollout: ✔ Healthy, Step 6/6, 2/2 Ready
    
    Staging env vars (overlay-patched, retained for tomorrow):
      LATENCY_MS: "5"
      FAIL_RATE:  "0"   (FAIL_RATE overlay patch removed in revert commit)

The LATENCY_MS=5 overlay patch in
`overlays/staging/canary-trigger-latency-patch.yaml` is INTENTIONALLY
RETAINED in Git. When the cluster comes back up tomorrow, staging
will start at this state as its baseline. This is what Argo Rollouts
considers its stable revision.

---

## What's Left For Day 2

| Block | What | Estimated time |
|-------|------|----------------|
| **2A-PRD-OVERLAY** | Rebuild prod overlay (mirror staging structure with prod-tier values: replicas 3, resources 128Mi req / 256Mi limit, host backend-prod.atlas.local, namespace three-tier-prod) | ~2 hours |
| **2B-EN-PRD** | Enable prod ApplicationSet (wave 3, copy ignoreDifferences from non-prod, retry 20, manual sync only — NO automated: section) | ~30 min |
| **2C-SLO** | Multi-env SLO rules — change `namespace="three-tier-dev"` to `namespace=~"three-tier-.*"` in three-tier-slo-rules.yaml and three-tier-slo-alerts.yaml | ~30 min |
| **2E-MATRIX** | Full isolation matrix test: trigger canary in each env, prove other two unaffected each time. Portfolio screenshots. | ~1.5 hours |
| **2H-TEARDOWN** | pre-destroy-cleanup.sh + terraform destroy | ~15 min |

Total: ~5 hours of focused work.

---

## How To Resume Tomorrow

1. `./infrastructure/terraform/bootstrap.sh` — 4-node cluster (~22 min)
2. `aws eks update-kubeconfig --region ap-south-1 --name atlas-eks-dev`
3. `./scripts/platform-install.sh`
4. `make argocd && make bootstrap-gitops`
5. Wait ~10 min for all 8 platform apps + dev + staging to sync
6. **Phase B re-verification:** confirm all apps go Synced + Healthy
   WITHOUT any manual CNPG patch (this is the third proof of Phase B
   working on a fresh cluster — getting valuable)
7. **Staging re-verification:** confirm staging's Rollout comes up
   with LATENCY_MS=5 (the overlay patch is still in Git)
8. Begin Block 2A (prod overlay)

---

## Files To Reference Tomorrow

- `gitops/workloads/three-tier-app/overlays/staging/` — full
  reference for what prod overlay should look like
- `gitops/workloads/three-tier-app/overlays/staging/kustomization.yaml`
  — the patches: section is the template prod's should follow
- `docs/learning/week-5-delivery/kustomize-strategic-merge-crd-trap.md`
  — reminder to use JSON 6902 for Rollout/AnalysisTemplate patches
- `docs/learning/week-6-eks/cnpg-multi-env-bootstrap-timing.md` —
  what to expect when prod's CNPG cluster takes 10-15 min after enable
- `gitops/apps/workloads-prod.yaml` — needs to be edited tomorrow:
  add `- env: prod` to elements, wave: "3", copy ALL ignoreDifferences
  from workloads-non-prod, retry 20, NO automated: section
