# Multi-Env GitOps — Day 2: Prod Enabled, SLO Multi-Env, Matrix Tests Captured

**Date:** 2026-06-10
**Cluster:** atlas-eks-dev (4× t3.large spot, ap-south-1)
**Session duration:** ~5.5 hours from bootstrap to teardown
**Outcome:** All three envs (dev + staging + prod) running side by
            side on a single EKS cluster, each isolated, each
            independently capable of canary success and abort.
            Multi-env SLO rules live in Prometheus. Production
            safety pattern (manual sync) demonstrated. Fixed
            pre-destroy script verified — zero EBS orphans on
            teardown.

---

## Starting State (After Bootstrap + Day 1 Replay)

Bootstrap took ~22 min (4-node t3.large spot EKS, ap-south-1, EBS
CSI + AWS LBC + ArgoCD + all 6 platform Applications synced via
the app-of-apps pattern). Platform sync wave -1 (CNPG operator)
then 0 (others) completed before workloads-non-prod kicked in at
waves 1 (dev) and 2 (staging). All 8 platform apps + dev + staging
went Synced + Healthy in ~10 min.

State at start of Day 2 work:

    kubectl get applications -n argocd
    platform-argo-rollouts     Synced    Healthy
    platform-cnpg-operator     Synced    Healthy
    platform-ingress-nginx     Synced    Healthy
    platform-kube-prometheus   Synced    Healthy
    platform-loki              Synced    Healthy
    platform-metrics-server    Synced    Healthy
    root-app-of-apps           Synced    Healthy
    three-tier-dev             Synced    Healthy   (4 backend, hash d5b565696)
    three-tier-staging         Synced    Healthy   (2 backend, hash b77fd487d)
    (three-tier-prod not yet present — workloads-prod still disabled)

This is the third clean bootstrap of the EKS cluster from scratch.
Phase B sync waves are now thoroughly validated — no manual
intervention needed.

---

## Block 2A — Prod Overlay Rebuild

Goal: bring prod overlay to the same standard as dev and staging
from Day 1. Prod was last touched in Week 5 with the now-removed
http-echo image and strategic-merge Rollout patches.

Files created/replaced in
`gitops/workloads/three-tier-app/overlays/prod/`:

  - **kustomization.yaml** (replaced)
    Replaced `hashicorp/http-echo:1.0.0` with
    `ghcr.io/prashant-zo/atlas-backend:6e501b6`. Wired 9 patches
    across strategic-merge (frontend Deployment) and JSON 6902
    (backend Rollout, AnalysisTemplate, Ingress, CronJob) targets.

  - **replicas-patch.yaml** (replaced)
    Frontend Deployment only — replicas=3 (HA tier).

  - **resources-patch.yaml** (replaced)
    Frontend Deployment only — 64Mi/128Mi memory, 50m/200m cpu.

  - **backend-replicas-patch.yaml** (NEW)
    JSON 6902 — Rollout replicas=3. Avoids the documented
    strategic-merge CRD trap.

  - **backend-resources-patch.yaml** (NEW)
    JSON 6902 — Rollout container resources 128Mi/256Mi memory,
    100m/500m cpu. Highest-tier sizing for prod.

  - **ingress-host-patch.yaml** (NEW)
    JSON 6902 — Ingress host backend-prod.atlas.local. Prevents
    collision with dev's backend.atlas.local and staging's
    backend-staging.atlas.local on the shared NGINX controller.

  - **traffic-generator-host-patch.yaml** (NEW)
    JSON 6902 — Replaces the CronJob's curl command so traffic
    targets backend-prod.atlas.local (not the base default
    backend.atlas.local).

  - **analysistemplate-namespace-patch.yaml** (NEW)
    JSON 6902 — Injects `namespace="three-tier-prod"` into both
    AnalysisTemplate PromQL queries. Without this, canary metric
    queries match `backend-svc-canary` cluster-wide and prod
    canary failures could be masked by dev/staging healthy metrics.

Tier sizing across all three envs:

| Tier              | dev      | staging  | prod     |
|-------------------|----------|----------|----------|
| backend replicas  | 4        | 2        | 3        |
| backend req mem   | 32Mi     | 64Mi     | 128Mi    |
| backend lim mem   | 64Mi     | 128Mi    | 256Mi    |
| backend req cpu   | 25m      | 50m      | 100m     |
| backend lim cpu   | 100m     | 200m     | 500m     |
| frontend replicas | 1        | 2        | 3        |
| frontend req mem  | 16Mi     | 32Mi     | 64Mi     |
| log level         | debug    | info     | warn     |
| ingress host      | backend  | backend-staging | backend-prod |

Verification: kustomize build passed all 12 local checks
(image, env vars, probes, replicas, resources, ingress host,
HOST_HEADER, analysistemplate namespace filter, ServiceMonitor
namespaceSelector absence, namespace, no http-echo, frontend
replicas). Diff against staging-rendered.yaml showed zero
structural differences (only env-specific values changed).

Commit: `feat(multi-env): rebuild prod overlay for EKS multi-env
deployment` (a8f3d48). Prod overlay was BUILD-VERIFIED at this
point but NOT YET ENABLED in workloads-prod.yaml.

---

## Block 2B — Enable Prod ApplicationSet With Manual Sync

Goal: wire prod into the GitOps tree but require explicit operator
approval to deploy any change.

File updated: `gitops/apps/workloads-prod.yaml`

Changes from previous (disabled) state:

  - Generator elements: `[]` → `[{env: prod, wave: "3"}]`
  - Annotation: parameterized sync-wave via `'{{ .wave }}'`
  - retry.limit: 5 → 20 (matches non-prod)
  - retry.maxDuration: 3m → 5m
  - syncPolicy.automated: section EXPLICITLY OMITTED

  - New ignoreDifferences entries:
      Rollout /spec/replicas (Argo Rollouts mutates during canary)
      Service rollouts-pod-template-hash selector key
      Service argo-rollouts.argoproj.io/managed-by-rollouts
        annotation (both mutated by Argo Rollouts during canary)

  - Existing ignoreDifferences preserved:
      StatefulSet /spec/volumeClaimTemplates (CNPG)
      Cluster /status, /spec/bootstrap/initdb/encoding+localeCType
        +localeCollate (CNPG operator + webhook)
      ScheduledBackup /status, Pooler /status (CNPG operator)

Commit: `feat(multi-env): enable prod ApplicationSet with manual
sync only` (3c1ed7c).

Sync workflow proven:
  1. Push lands → ArgoCD detects within ~30s
  2. three-tier-prod appears: `OutOfSync, Missing` (expected —
     no sync requested)
  3. Operator runs: `acd app sync three-tier-prod`
  4. ArgoCD applies resources at wave 3, behind dev/staging
  5. CNPG cluster bootstraps in ~5 min (3 pg instances + base
     backup), matching documented timing in
     cnpg-multi-env-bootstrap-timing.md
  6. Total sync time: 10m19s from sync start to Synced + Healthy

Final state after sync:
    three-tier-prod: Synced + Healthy, 14 pods
      (3 backend, 3 frontend, 3 pg, 2 pg-pooler, 1 minio,
       traffic-gen, etc.)

This is the production safety pattern: Git is the source of truth,
but a human approves every prod change.

---

## Block 2C — Multi-Env SLO Rules

Goal: SLO recording rules and alerts that work for all three envs
without per-env duplication. CNCF kube-prometheus pattern.

Files updated:
  - `gitops/platform/kube-prometheus/rules/three-tier-slo-rules.yaml`
  - `gitops/platform/kube-prometheus/rules/three-tier-slo-alerts.yaml`

Recording rule changes (4 expressions updated across 3 rules):

  - `namespace="three-tier-dev"` → `namespace=~"three-tier-.*"`
    Regex selector matches all three envs.

  - Added `max by (namespace) (...)` aggregation around each
    metric. Without this, multi-namespace metrics would collapse
    into one number, defeating the purpose. With it, recording
    rules emit ONE series PER env, labeled by source namespace.

  - Removed hardcoded `service: three-tier-dev` label. Alerts
    inject env-specific labels dynamically (see below).

Alert changes (6 alerts × 3 dynamic labels each = 18 label
assignments using Go templating):

  Each alert now has:
    namespace:   '{{ $labels.namespace }}'
    environment: '{{ reReplaceAll "three-tier-" "" $labels.namespace }}'
    service:     'three-tier-{{ ... }}' (preserved for compat)

  Plus summaries/descriptions interpolate `{{ $labels.namespace }}`
  so the operator immediately knows which env breached SLO.

This pattern enables Alertmanager to route on `environment`:
    prod    → on-call rotation (PagerDuty)
    staging → Slack #staging-alerts
    dev     → Slack #dev-alerts (or silenced)

Commit: `feat(slo): multi-env SLO rules with dynamic per-env
labeling` (3c52783).

Verified live in Prometheus after ArgoCD synced
platform-kube-prometheus:
  - 3 rule groups loaded (availability, latency, backup-freshness)
  - Each recording rule emits 3 series, one per namespace
  - All series value: "1" (healthy across all 3 envs)

---

## Block 2E.1 — DEV Success Canary + Isolation Proof

Goal: trigger dev canary, prove staging + prod stay untouched.

Trigger: JSON 6902 overlay patch
`overlays/dev/canary-trigger-latency-patch.yaml` setting
`LATENCY_MS=5` on dev's backend Rollout env[3].

Canary cycle (~5 min from spec change to promotion):

    T+0    rev 1 stable, hash d5b565696
    T+~30s rev 2 canary pod 85f7d85f67 Ready (setWeight 25)
    T+~90s setWeight progresses, AnalysisRun starts
    T+~4m  AnalysisRun ✔ Successful ✔ 10
           (10 measurements all passed — success-rate ≈ 1.0)
    T+~5m  rev 2 promoted to stable, rev 1 entering 5min
           scaledown delay
    Final  Status ✔ Healthy, Step 6/6, image atlas-backend:6e501b6

Isolation snapshots during dev canary (4 timestamps captured):

| Time     | Dev hashes         | Staging hash         | Prod hash          |
|----------|--------------------|-----------------------|---------------------|
| 21:28:34 | 1× canary + 4× rev1 | 2× b77fd487d (Healthy) | 3× 684dd99475 (Healthy) |
| 21:30:35 | 2× canary + 4× rev1 | 2× b77fd487d (Healthy) | 3× 684dd99475 (Healthy) |
| 21:31:16 | 3× canary + 4× rev1 | 2× b77fd487d (Healthy) | 3× 684dd99475 (Healthy) |
| 21:32:12 | 4× canary + 4× rev1 | 2× b77fd487d (Healthy) | 3× 684dd99475 (Healthy) |

Staging and prod pod template hashes did not change at all
during dev's entire canary cycle. Both stayed Healthy, Step 6/6.

Prometheus cross-env verification:
  - Dev's AnalysisRun query returned "1" (success rate scoped
    to namespace="three-tier-dev")
  - All 3 SLO recording rules still at "1" (no env breached SLO)
  - Per-env canary RPS roughly equal across all envs — this is
    the Service-label-quirk documented Day 1 (backend-svc-canary
    Service exists in every env when no canary is running), NOT
    cross-env contamination

Revert: removed trigger patch file + kustomization entry.
Verified `kustomize build` confirmed LATENCY_MS back to "0".
Commit: `demo(matrix): DEV revert — return to baseline for matrix
continuation` (55d4b1a).

---

## Block 2E.2 — STAGING Abort Canary + Isolation Proof

Goal: trigger staging abort with FAIL_RATE injection, prove dev +
prod stay untouched, drive abort with k6 high-load for statistical
strength.

Setup note: staging was already at LATENCY_MS=5 (retained from
Day 1's preserved overlay). Trigger was the SECOND patch
overlapping the existing one — both LATENCY_MS=5 and FAIL_RATE=0.5
in revision 2.

Trigger: JSON 6902 overlay patch
`overlays/staging/canary-trigger-failrate-patch.yaml` setting
`FAIL_RATE=0.5` on staging's backend Rollout env[2].

k6 load in parallel:
    NAMESPACE=three-tier-staging \
    HOST_HEADER=backend-staging.atlas.local \
    ./load-tests/k6/run.sh

k6 sustained ~86 RPS for 2:51 before Ctrl-C (after abort fired).
14,800+ iterations against staging's ingress — strong statistical
signal for the AnalysisRun.

Abort cycle (~3 min from spec change to Degraded):

    T+0     rev 2 (FAIL_RATE=0.5, LATENCY_MS=5) created
    T+~30s  canary pod 676869cc4f Ready (setWeight 25)
            ~50% of canary's 25% traffic share = 500 errors
            (backend's FAIL_RATE simulation)
    T+~90s  AnalysisRun starts
    T+~2m   2nd measurement breaches threshold
            success-rate ≈ 0.5, fails (>= 0.99, failureLimit 1)
            ✔ 2, ✖ 2 → ✖ Failed
    T+~2m10s Auto-abort. revision 2 ReplicaSet → 0 replicas.
             Status: ✖ Degraded, RolloutAborted message
    T+~2m45s revision 2 ScaledDown, revision 1 stable continues

Isolation snapshots during staging abort:

| Time     | Dev state            | Staging state                       | Prod state           |
|----------|----------------------|--------------------------------------|----------------------|
| 21:41:54 | Healthy 6/6, 2 hashes (scaledown delay from prior test) | Progressing 1/6, 1× canary + 2× stable | Healthy 6/6, 3× 684dd99475 |
| 21:43:07 | Healthy 6/6          | ✖ Degraded, RolloutAborted, Step 0/6 | Healthy 6/6, UNCHANGED |
| 21:43:46 | Healthy 6/6          | ✖ Degraded, canary scaled to 0      | Healthy 6/6, UNCHANGED |

Dev and prod pod template hashes did not change at all
during staging's entire abort cycle.

Critical safety property: throughout the abort, staging's stable
ReplicaSet (rev 1, hash b77fd487d, 2 pods) continued serving 100%
of non-canary traffic. The 25% canary share that returned errors
was bounded — no production-equivalent traffic loss.

Revert: removed FAIL_RATE patch file + kustomization entry.
Verified kustomize build shows FAIL_RATE="0", LATENCY_MS="5".
Commit: `demo(matrix): STAGING abort revert — return to baseline`
(0545278). Staging was promoting back to Healthy when teardown
began.

---

## Block 2E.3 — Prod Manual-Sync Gate (Lightweight Demonstration)

Skipped a full canary cycle for prod (isolation already proven
twice via dev success + staging abort) and instead captured the
unique prod behavior: manual sync gate.

Test: push a no-op comment to prod overlay's kustomization.yaml,
observe that ArgoCD requires `acd app sync three-tier-prod` even
for trivial changes.

Output captured the proof in the sync metadata:

    Sync Policy:    Manual
    Sync Status:    Synced to main (2d592d4)
    Phase:          Succeeded
    Duration:       8s
    Operation:      Sync
    Message:        successfully synced (no more tasks)

The "Sync Policy: Manual" line in ArgoCD's view is the gate.
Dev and staging would show "Sync Policy: Automated".

Commit: `demo(matrix): prod manual-sync gate demonstration`
(2d592d4).

Combined with the 10-minute manual sync during Block 2B (when
prod was first enabled and operator ran `acd app sync` to bring
it up), this is sufficient demonstration of the production
safety pattern.

---

## Final State Snapshot — Multi-Env GitOps LIVE

    Date: Wed Jun 10 21:56:21 IST 2026

    kubectl get applications -n argocd
    ──────────────────────────────────────────────
    platform-argo-rollouts     Synced    Healthy
    platform-cnpg-operator     Synced    Healthy
    platform-ingress-nginx     Synced    Healthy
    platform-kube-prometheus   Synced    Healthy
    platform-loki              Synced    Healthy
    platform-metrics-server    Synced    Healthy
    root-app-of-apps           Synced    Healthy
    three-tier-dev             Synced    Healthy
    three-tier-prod            Synced    Healthy
    three-tier-staging         Synced    Healthy

    Backend Rollouts ─────────────────────────────
    three-tier-dev:     Step 6/6, 4 replicas, hash 85f7d85f67
    three-tier-staging: Step 6/6, 2 replicas, hash b77fd487d
    three-tier-prod:    Step 6/6, 3 replicas, hash 684dd99475

    SLO recording rules (3 series per rule, all 1.0):
    sli:three_tier_db_available:ratio
      three-tier-dev:     "1"
      three-tier-staging: "1"
      three-tier-prod:    "1"

    Pod counts ──────────────────────────────────
    Total cluster:   82 pods
    three-tier-dev:  13 pods
    three-tier-staging: 13 pods
    three-tier-prod:    14 pods

    Node usage (4× t3.large) ────────────────────
    node-1: CPU 4%,  Memory 8%
    node-2: CPU 6%,  Memory 22%
    node-3: CPU 31%, Memory 34%
    node-4: CPU 14%, Memory 27%

Three environments, three distinct backend Rollouts, three pod
template hashes, three independent CNPG clusters, three ingress
hosts, three AnalysisTemplate-scoped metric streams, three SLO
series per recording rule — all running on ONE EKS cluster,
managed by ONE ArgoCD, defined by ONE Git repo. Multi-env GitOps
with progressive delivery, production safety, and full SLO
observability. Working.

---

## Block 2H — Teardown (Verifying The EBS Orphan Bug Fix)

This was the high-value verification of yesterday's
pre-destroy-cleanup.sh rewrite.

Sequence:

    ./scripts/pre-destroy-cleanup.sh
    ./infrastructure/terraform/destroy.sh

The new pre-destroy script:
  1. Deleted all LoadBalancer Services + Ingresses (~60s wait
     for ALB controller to release ALBs in AWS)
  2. Deleted all PVCs across all three workload namespaces +
     monitoring (~14 PVCs marked for deletion)
  3. Removed finalizers from any stuck Released PVs
  4. Polled AWS in a 15s-interval loop for up to 5 min waiting
     for EBS CSI to delete underlying volumes
  5. Force-deleted any remaining orphan volumes via aws ec2
     delete-volume — bypassing EBS CSI entirely so the deletion
     works even after IRSA is destroyed in Terraform's next step
  6. Cleaned up any orphan EBS snapshots

destroy.sh then tore down IAM-IRSA, EKS cluster, and VPC in
sequence (matching documented ~12-15 min total).

Final verification:

    aws eks list-clusters --region ap-south-1            → []
    aws ec2 describe-volumes ...tag:...kubernetes.io/cluster/atlas-eks-dev
                                                         → 0 volumes
    aws ec2 describe-snapshots ...                       → 0 snapshots
    aws elbv2 describe-load-balancers ...                → 0 ALBs
    terraform state list (all 3 modules)                 → empty

The script DID detect orphans this time and force-delete them
(this can't be 100% avoided — EBS CSI sometimes hasn't finished
when Terraform wants to tear down IRSA). The fix is verified
working: yesterday left 10 orphans, today left 0. The polling
loop + force-delete pattern is the correct architecture.

---

## Commits Landed Today

    feat(multi-env): rebuild prod overlay for EKS multi-env deployment (a8f3d48)
    feat(multi-env): enable prod ApplicationSet with manual sync only (3c1ed7c)
    feat(slo): multi-env SLO rules with dynamic per-env labeling (3c52783)
    demo(matrix): DEV canary trigger for isolation matrix test (da05081)
    demo(matrix): DEV revert — return to baseline for matrix continuation (55d4b1a)
    demo(matrix): STAGING abort canary for isolation matrix test (10e86fa)
    demo(matrix): STAGING abort revert — return to baseline (0545278)
    demo(matrix): prod manual-sync gate demonstration (2d592d4)
    docs(week-6): capture Day 2 multi-env GitOps wrap-up (this commit)

Plus yesterday's late-night fix:
    fix(scripts): pre-destroy-cleanup leaves no EBS orphans (2b2b169)
                  ↑ verified working during this session's teardown

---

## What Was Proven End-to-End

1. **Phase B sync waves work consistently** — third clean
   bootstrap with zero manual CNPG intervention. cnpg-operator
   at wave -1, others at wave 0, dev at wave 1, staging at
   wave 2, prod at wave 3. Sequential CNPG bootstrap is the
   reliable pattern.

2. **Multi-env Kustomize overlays scale** — three nearly
   identical overlay structures, differing only in env-specific
   values (replicas, resources, host, namespace, log level).
   Kustomize build verification + diff-against-staging catches
   structural regressions before push.

3. **JSON 6902 patches are mandatory for CRDs** — Rollout,
   AnalysisTemplate, Ingress (host field), CronJob (command
   array). Strategic-merge on these silently wipes sibling
   fields. The dev/staging/prod overlay pattern enforces this.

4. **AnalysisTemplate namespace filtering enables true
   multi-env canary** — without `namespace="three-tier-X"`
   in the PromQL query, prod canary failures could be masked
   by dev's healthy metrics or vice versa.

5. **Multi-env SLO recording rules work with regex + by-clause**
   — one rule group covers all envs, emits per-env series,
   alerts inject dynamic labels for Alertmanager routing.

6. **Manual sync gate provides production safety** — same Git,
   same ApplicationSet template generator, different syncPolicy.
   Operator approval required for every prod change.

7. **EBS orphan bug fix works** — pre-destroy polling loop +
   AWS CLI force-delete handles the IRSA-teardown race
   condition correctly.

---

## What's Left (Week 6 Beyond This Sprint)

Not done in this sprint, but identified for follow-up:

  - **ADR-010: Multi-env Kustomize overlay pattern** — write up
    the JSON 6902 + tier sizing + naming convention decisions
    so future contributors can extend to a 4th env without
    re-deriving the rules

  - **ADR-011: Per-env ingress host + AnalysisTemplate filter**
    — the canary-isolation mechanism specifically, since this
    is the non-obvious part of the architecture

  - **ADR-012: EKS node sizing for multi-env coexistence** —
    why 4× t3.large spot (memory bound by CNPG + Prometheus +
    Loki + 3× workload stacks)

  - **kind-dev vs eks-* overlay split** — currently dev/staging/
    prod overlays target EKS. Local dev with kind needs its
    own overlay set (likely as `overlays/kind-dev`, sharing
    the base with the EKS triplet)

  - **Loom recording** — narrate the matrix isolation demo with
    the captured terminal output as the visual

  - **Portfolio README update** — capture the multi-env GitOps
    work as a top-line project showcase

---

## Cluster Status At End Of Session

Destroyed. Zero orphans. Zero ongoing AWS cost from this work.
All commits in github.com/prashant-zo/atlas-platform. Ready to
bootstrap again any time via
`./infrastructure/terraform/bootstrap.sh`.
