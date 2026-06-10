# ADR-010: Multi-Env Kustomize Overlay Pattern With JSON 6902 For CRDs

**Status:** Accepted
**Date:** 2026-06-10
**Author:** Prashant
**Context:** Week 6 multi-env GitOps sprint (Days 1-2)

---

## Context

Atlas needs to run the same three-tier application across three environments — dev, staging, prod — on a single EKS cluster. Each env needs different replica counts, resource limits, log levels, and ingress hosts. The application code and base manifests should not be duplicated per environment.

Two related requirements drove this ADR:

1. **Environment-specific configuration without manifest forks.** Each env needs its own values for ~10 parameters (replicas, CPU/memory, log level, ingress host, etc.) but the underlying Deployment / Rollout / ConfigMap / Service / Ingress specs are identical in shape.

2. **CRD patches without silent field loss.** Atlas uses Argo Rollouts and CNPG. Both define CRDs (Rollout, AnalysisTemplate, Cluster). Kustomize's default strategic-merge patching does not have schema awareness for CRDs and will silently drop sibling fields. This failure mode was discovered the hard way in Week 5 — captured in `docs/learning/week-5-delivery/kustomize-strategic-merge-crd-trap.md`.

The existing base manifests in `gitops/workloads/three-tier-app/base/` are environment-neutral. The question was how to layer per-env config on top.

---

## Decision

**Use Kustomize overlays with the bases-and-patches pattern. Use JSON 6902 (RFC 6902) patches for all CRD modifications. Use strategic-merge patches only for built-in Kubernetes types (Deployment, Service, ConfigMap, Ingress when not editing arrays).**

Layout:

itops/workloads/three-tier-app/
├── base/                              # shared, env-neutral manifests
│   ├── kustomization.yaml
│   ├── backend-rollout.yaml           # CRD: argoproj.io/v1alpha1/Rollout
│   ├── analysis-template.yaml         # CRD: AnalysisTemplate
│   ├── frontend-deployment.yaml       # built-in Deployment
│   ├── ingress.yaml                   # built-in Ingress
│   └── ... (15+ resources)
├── database/                          # CNPG Cluster + MinIO (env-neutral shape)
│   └── ...
└── overlays/
├── dev/
├── staging/
└── prod/
├── kustomization.yaml
├── replicas-patch.yaml                  # strategic-merge: Deployment.replicas
├── resources-patch.yaml                 # strategic-merge: Deployment containers[]
├── loglevel-patch.yaml                  # strategic-merge: ConfigMap
├── backend-replicas-patch.yaml          # JSON 6902: Rollout.spec.replicas
├── backend-resources-patch.yaml         # JSON 6902: Rollout container resources
├── ingress-host-patch.yaml              # JSON 6902: Ingress.spec.rules[0].host
├── traffic-generator-host-patch.yaml    # JSON 6902: CronJob command
└── analysistemplate-namespace-patch.yaml # JSON 6902: AnalysisTemplate query

Each overlay's `kustomization.yaml` references the base, sets the env-specific namespace, and lists patches with explicit `target:` blocks for JSON 6902 patches.

---

## Why JSON 6902 For CRDs

Strategic merge patching uses Go struct tag annotations (`patchStrategy`, `patchMergeKey`) on the target type's schema. The Kubernetes API server has this metadata built in for native types like `Deployment`. For CRDs, the metadata doesn't exist — Kustomize falls back to a "best guess" merge that treats arrays as replaceable rather than mergeable on a key.

The failure mode is subtle and dangerous:

```yaml
# Strategic-merge patch on a Rollout (a CRD) — WRONG
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: backend
spec:
  template:
    spec:
      containers:
        - name: backend
          resources:                    # ← what you intend to change
            requests:
              memory: "128Mi"
```

Kustomize sees `containers[]` as an array, doesn't know to use `name` as the merge key (it does for Deployment, not for Rollout), and **replaces the entire container** — silently wiping `image`, `env`, `ports`, `livenessProbe`, `readinessProbe`, etc. The Rollout deploys with a broken pod spec. The operator may not surface the error until pods crashloop.

JSON 6902 patches are explicit operations on JSON pointers:

```yaml
# JSON 6902 patch on the same Rollout — CORRECT
- op: replace
  path: /spec/template/spec/containers/0/resources
  value:
    requests:
      memory: "128Mi"
    limits:
      memory: "256Mi"
```

This says "replace exactly this field." No array surgery. No schema guessing. No silent drops. The patch either applies or fails loudly.

The cost: JSON 6902 paths are index-based (`containers/0`, `env/3`) instead of name-based. Refactoring the base (reordering containers, reordering env vars) can break overlays. We mitigate this by:

- Documenting the env array order in `backend-rollout.yaml` as a comment
- Running `kustomize build` on every overlay before commit
- A 12-check verification suite that catches structural regressions

---

## Why Strategic Merge For Built-In Types

For Deployment / Service / ConfigMap / Ingress (when not editing arrays), strategic merge is more readable and easier to maintain. The schema knowledge is built into kube-apiserver, so there are no surprises:

```yaml
# Strategic-merge patch on Deployment — fine
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
spec:
  replicas: 3
```

Mixing both strategies in one overlay is supported by Kustomize and is the canonical pattern in `kubernetes-sigs/kustomize/examples`.

---

## Tier Sizing Across Envs

A separate question is what values each env actually uses. We chose tiers that reflect realistic production patterns:

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
| ingress host      | backend.atlas.local | backend-staging.atlas.local | backend-prod.atlas.local |

Reasoning:

- **Dev has MORE backend replicas than staging** because dev is the active workspace where multiple canary cycles may run in parallel. Throughput matters more than per-replica resources.
- **Prod has higher resource limits** for headroom during traffic spikes and during canary rollouts (when stable + canary pods run concurrently).
- **Log level decreases prod → dev** (verbose at the bottom, quiet at the top) — standard production pattern.

These tiers are sensible defaults that demonstrate the multi-env pattern, not load-tested SLOs. A real production environment would derive these from observed traffic and latency targets.

---

## Implementation Notes

### Kustomize Version

We use the `kustomize` standalone binary (v5.x) not `kubectl apply -k`. The standalone binary supports the modern `patches:` syntax with `target:` blocks. `kubectl apply -k` historically lagged on Kustomize features; the gap has narrowed but standalone is still preferred for CI.

### Patch Targets

JSON 6902 patches require an explicit target since the patch file is just a list of operations (it doesn't carry full object identity):

```yaml
patches:
  - path: backend-replicas-patch.yaml
    target:
      group: argoproj.io
      version: v1alpha1
      kind: Rollout
      name: backend
```

Without `target`, Kustomize can't determine which resource to patch.

### Local Verification

Every overlay change is verified before commit:

```bash
kustomize build overlays/prod/ > /tmp/prod-rendered.yaml
# 12 checks: image, env vars, probes, replicas, resources,
# ingress host, HOST_HEADER, AnalysisTemplate namespace,
# ServiceMonitor selector, namespace, no http-echo, frontend replicas
```

Plus a diff against another overlay (e.g., staging-rendered.yaml) to confirm only env-specific differences exist. The procedure is documented in `docs/learning/week-6-eks/multi-env-gitops-day-2.md`.

### ArgoCD Integration

Each overlay corresponds to one ArgoCD Application generated by an ApplicationSet:

- `gitops/apps/workloads-non-prod.yaml` — generates `three-tier-dev` (sync-wave 1) and `three-tier-staging` (wave 2)
- `gitops/apps/workloads-prod.yaml` — generates `three-tier-prod` (wave 3, manual sync only)

Sync waves stagger CNPG cluster bootstrap (see ADR-003).

---

## Consequences

### Positive

- **Single source of truth.** One base, three overlays. Adding a fourth env (e.g., `staging-eu`) takes ~30 min: copy `staging/`, change values, add to ApplicationSet generator.
- **Type-safe CRD patches.** JSON 6902 fails loudly on invalid paths instead of silently corrupting CRD specs.
- **Local verification is fast.** `kustomize build` runs in under 1s. Diff against another overlay catches structural regressions.
- **Standard CNCF pattern.** Anyone familiar with FluxCD / ArgoCD / Cluster API repos will recognize the layout.

### Negative

- **JSON 6902 paths are fragile to base refactoring.** Reordering env vars breaks overlays that reference `env/3`. Mitigation: documented env array order; planned CI step running `kustomize build` on every PR.
- **Two patch styles in one overlay.** Mental overhead is real for someone new to the repo. The `kustomization.yaml` acts as the manifest of which is which (lines without `target:` are strategic-merge; lines with `target:` are JSON 6902).
- **Implicit coupling between overlays.** Adding a field to the base means reviewing all overlays. The 12-check verification catches most misses but not all.

### Neutral

- **Switching templating systems would be a significant refactor.** Once invested in Kustomize, moving to Helm or ytt is a 1-2 day project. Atlas isn't likely to switch.

---

## Alternatives Considered

### Alternative 1: Per-Env Manifest Forks

Copy `base/` to `dev/`, `staging/`, `prod/` and edit each fully.

- **Pros:** No patching complexity. Each env's manifests are self-contained.
- **Cons:** Shared changes (probes, labels, ServiceMonitor selectors) must be made 3 times. Drift between envs becomes invisible. GitOps reviews triple in size.
- **Decision:** Rejected. The whole point of Kustomize is to avoid this.

### Alternative 2: Helm Charts With Per-Env Values Files

Convert manifests to a Helm chart with `values.dev.yaml`, `values.staging.yaml`, `values.prod.yaml`.

- **Pros:** Helm is widely understood. Values files are clean.
- **Cons:** Atlas doesn't release charts (no external consumers). Helm's templating produces less readable diffs in ArgoCD's UI. CRDs with nested arrays still need careful `_helpers.tpl` handling — the strategic-merge trap exists in Helm too if you use `lookup` + `merge` patterns.
- **Decision:** Rejected. Kustomize is simpler for our scale.

### Alternative 3: cdk8s / Pulumi / Programmatic Manifests

Generate manifests from TypeScript or Python.

- **Pros:** Full programming power. Type safety from the source.
- **Cons:** Adds a build step. Diffs harder to review in GitHub. Most engineers don't know cdk8s. Operator-managed CRDs still need careful handling.
- **Decision:** Rejected. Overkill for a small set of overlays.

### Alternative 4: Strategic Merge Everywhere

Use strategic-merge for CRDs too, accept the silent-field-loss risk.

- **Pros:** Single mental model.
- **Cons:** Already burned on this in Week 5. The exact bug is documented. Reverting means re-discovering it.
- **Decision:** Rejected.

---

## Compliance and Reversibility

This ADR can be reversed by:

1. Choose one overlay (e.g., `prod`), copy all rendered manifests into a per-env fork
2. Repeat for `dev` and `staging`
3. Remove `overlays/` and point ApplicationSets at the per-env directories

Total work: ~1-2 hours. We are not locked in.

---

## References

- Kustomize JSON 6902 patches: https://kubectl.docs.kubernetes.io/references/kustomize/builtins/#_patchjson6902_
- RFC 6902 (JSON Patch): https://datatracker.ietf.org/doc/html/rfc6902
- The CRD strategic-merge trap (lessons learned): `docs/learning/week-5-delivery/kustomize-strategic-merge-crd-trap.md`
- Day 1 multi-env demo capture: `docs/learning/week-6-eks/multi-env-canary-isolation-demo.md`
- Day 2 sprint wrap-up: `docs/learning/week-6-eks/multi-env-gitops-day-2.md`
- ADR-005 (Argo Rollouts) — context for why Rollout is a CRD
- ADR-003 (Postgres operator) — context for why CNPG Cluster is a CRD
