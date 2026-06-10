# Atlas Platform — Engineering Roadmap

A GitOps Kubernetes platform spanning infrastructure-as-code, progressive
delivery, HA databases, SLO-based observability, and multi-environment
deployment. Built to learn each layer hands-on and document the
architectural decisions along the way.

**Repository:** github.com/prashant-zo/atlas-platform
**Owner:** Prashant
**Status legend:** ⏳ Pending · 🔨 In Progress · ✅ Done

---

## Architecture Overview

Atlas Platform
├── Infrastructure       — kind (local) + EKS (validation)
├── GitOps Engine        — ArgoCD app-of-apps + ApplicationSets + sync waves
├── Workloads            — three-tier app (frontend, backend, HA Postgres)
├── Database HA          — CloudNativePG operator + WAL archive + PITR
├── Observability        — Prometheus + Grafana + Loki + multi-env SLO alerts
├── Progressive Delivery — Argo Rollouts + NGINX traffic split + analysis-gated
├── Multi-Environment    — dev + staging + prod via Kustomize overlays
└── Documentation        — 12 ADRs + 5 incident postmortems + runbooks

---

## Week 1 — Foundation & Local Cluster ✅

Reproducible kind-based development environment.

| ID   | Task                                                    | Status |
|------|---------------------------------------------------------|--------|
| 1.1  | Project README with architecture overview               | ✅     |
| 1.2  | ROADMAP.md (this file)                                  | ✅     |
| 1.3  | Multi-node kind cluster config (1 cp + 2 workers)       | ✅     |
| 1.4  | Bootstrap script: cluster up                            | ✅     |
| 1.5  | Bootstrap script: cluster teardown                      | ✅     |
| 1.6  | Verify-setup script for environment checks              | ✅     |
| 1.7  | ADR-001: Why kind over minikube/k3d                     | ✅     |
| 1.8  | Local registry for fast image push/pull                 | ✅     |
| 1.9  | metrics-server installed via manifest                   | ✅     |
| 1.10 | Makefile for common operations                          | ✅     |

**Deliverable:** `make up` brings up a 3-node kind cluster with metrics-server
and local registry. `make down` tears it down cleanly.

---

## Week 2 — GitOps Engine (ArgoCD) ✅

ArgoCD with App-of-Apps pattern across three Kustomize overlays.

| ID   | Task                                                    | Status |
|------|---------------------------------------------------------|--------|
| 2.1  | ArgoCD installation via Helm values                     | ✅     |
| 2.2  | ArgoCD bootstrap script                                 | ✅     |
| 2.3  | App-of-Apps root application                            | ✅     |
| 2.4  | Application set for platform components                 | ✅     |
| 2.5  | ADR-002: ArgoCD vs Flux                                 | ✅     |
| 2.6  | Kustomize base for three-tier app                       | ✅     |
| 2.7  | Kustomize dev overlay                                   | ✅     |
| 2.8  | Kustomize staging overlay (initial)                     | ✅     |
| 2.9  | Kustomize prod overlay (initial)                        | ✅     |
| 2.10 | Runbook: ArgoCD sync troubleshooting                    | ✅     |

**Deliverable:** Push YAML to GitHub → ArgoCD reconciles cluster
automatically. Three overlays exist; full multi-env coexistence
validated in Week 6.

---

## Week 3 — HA Database with CloudNativePG ✅

Replacing the single-pod Postgres from Project 1 with a 3-replica HA cluster.

| ID   | Task                                                    | Status |
|------|---------------------------------------------------------|--------|
| 3.1  | CloudNativePG operator install                          | ✅     |
| 3.2  | Postgres Cluster CR — 1 primary + 2 replicas            | ✅     |
| 3.3  | MinIO deployment (local S3 for WAL)                     | ✅     |
| 3.4  | WAL archiving configuration                             | ✅     |
| 3.5  | Backup schedule (daily base backup)                     | ✅     |
| 3.6  | Connection pooler (PgBouncer)                           | ✅     |
| 3.7  | ADR-003: CloudNativePG vs Crunchy                       | ✅     |
| 3.8  | Runbook: PITR — point-in-time recovery                  | ✅     |
| 3.9  | Runbook: Manual failover                                | ✅     |
| 3.10 | INC-001 + INC-002: Failover GameDays                    | ✅     |

**Deliverable:** Postgres survives primary pod deletion (~15s recovery).
Restore to any point in time within retention window. Two failover
GameDays documented.

---

## Week 4 — Observability & SLOs ✅

Three pillars + multi-window burn-rate alerts (Google SRE pattern).

| ID   | Task                                                    | Status |
|------|---------------------------------------------------------|--------|
| 4.1  | kube-prometheus-stack Helm install                      | ✅     |
| 4.2  | Loki + Promtail for log aggregation                     | ✅     |
| 4.3  | ServiceMonitors / PodMonitors for workloads             | ✅     |
| 4.4  | SLO definitions + recording rules                       | ✅     |
| 4.5  | Multi-window burn-rate alerts                           | ✅     |
| 4.6  | Grafana dashboards (cluster, CNPG, SLO burn-down)       | ✅     |
| 4.7  | ADR-004: Loki vs ELK                                    | ✅     |
| 4.8  | Runbook: SLO breach response                            | ✅     |
| 4.9  | Monitoring coverage doc                                 | ✅     |
| 4.10 | INC-003: Availability GameDay                           | ✅     |

**Deliverable:** SLOs defined (DB availability 99.5%, latency 99%,
backup freshness 99.9%). Multi-window burn-rate alerts loaded and
inactive when SLOs hold. Grafana dashboards live. INC-003
documented chaos injection vs SLO impact.

---

## Week 5 — Progressive Delivery ✅

Argo Rollouts with NGINX traffic splitting and Prometheus-gated promotion.

| ID   | Task                                                    | Status |
|------|---------------------------------------------------------|--------|
| 5.1  | Argo Rollouts controller install                        | ✅     |
| 5.2  | NGINX ingress controller install                        | ✅     |
| 5.3  | Convert backend Deployment to Rollout                   | ✅     |
| 5.4  | Wire NGINX trafficRouting on Rollout                    | ✅     |
| 5.5  | AnalysisTemplate using Prometheus metrics               | ✅     |
| 5.6  | Automated rollback on SLI breach                        | ✅     |
| 5.7  | k6 load testing for canary traffic                      | ✅     |
| 5.8  | ADR-005: Rollouts vs Flagger vs native Deployment       | ✅     |
| 5.9  | INC-004 GameDay: bad canary auto-rollback               | ✅     |
| 5.10 | Week 5 runbook + ROADMAP wrap                           | ✅     |

**Deliverable:** Canary promotes via Prometheus-gated analysis. A
deliberately broken v3 release (FAIL_RATE=0.5) was rejected in ~90s.
Under k6 load, backend held 100 RPS for 5 minutes with no errors,
6.37ms p95 end-to-end.

---

## Week 6 — EKS + Multi-Env GitOps ✅

EKS validation, then full multi-env coexistence on a single cluster.

### Phase A — EKS Bootstrap (Single-Env)

| ID   | Task                                                    | Status |
|------|---------------------------------------------------------|--------|
| 6.1  | Terraform module for VPC                                | ✅     |
| 6.2  | Terraform module for EKS cluster                        | ✅     |
| 6.3  | Terraform module for IAM/IRSA                           | ✅     |
| 6.4  | EKS bootstrap script                                    | ✅     |
| 6.5  | Deploy Atlas to EKS (single env: dev)                   | ✅     |
| 6.6  | gp3 default StorageClass via Terraform                  | ✅     |
| 6.7  | ADR-006: Multi-module Terraform with bash orchestration | ✅     |
| 6.8  | ADR-007: Single NAT gateway multi-AZ (cost)             | ✅     |
| 6.9  | ADR-008: Spot-only node group                           | ✅     |
| 6.10 | ADR-009: podinfo for canary validation                  | ✅     |

### Phase B — Bootstrap Resilience

| ID   | Task                                                    | Status |
|------|---------------------------------------------------------|--------|
| 6.11 | Sync waves: CNPG operator wave -1, workloads wave 1+    | ✅     |
| 6.12 | Retry policy tuning (limit 20, maxDuration 5m)          | ✅     |
| 6.13 | ignoreDifferences for CNPG operator-mutated fields      | ✅     |
| 6.14 | argocd CLI IPv4 explicit (bypass IPv6 localhost trap)   | ✅     |
| 6.15 | Phase B clean-bootstrap verification across 3 sessions  | ✅     |

### Phase C — Multi-Env Coexistence (3 Envs on One Cluster)

| ID   | Task                                                    | Status |
|------|---------------------------------------------------------|--------|
| 6.16 | Scale node group to 4× t3.large (memory headroom)       | ✅     |
| 6.17 | Base manifest cleanup for multi-env coexistence         | ✅     |
| 6.18 | Rebuild staging overlay (JSON 6902 for CRDs)            | ✅     |
| 6.19 | Rebuild prod overlay (mirrors staging structure)        | ✅     |
| 6.20 | Per-env ingress host (canary isolation)                 | ✅     |
| 6.21 | Per-env AnalysisTemplate namespace filter               | ✅     |
| 6.22 | Per-env traffic-generator Host header                   | ✅     |
| 6.23 | Multi-env SLO rules (regex selector + by-namespace)     | ✅     |
| 6.24 | Enable staging ApplicationSet (auto-sync, wave 2)       | ✅     |
| 6.25 | Enable prod ApplicationSet (manual sync, wave 3)        | ✅     |
| 6.26 | Parameterize k6 for any env (NAMESPACE + HOST_HEADER)   | ✅     |

### Phase D — Matrix Tests + Portfolio Capture

| ID   | Task                                                    | Status |
|------|---------------------------------------------------------|--------|
| 6.27 | DEV success canary + cross-env isolation snapshots      | ✅     |
| 6.28 | STAGING abort canary + k6 88 RPS + isolation snapshots  | ✅     |
| 6.29 | Prod manual-sync gate demonstration                     | ✅     |
| 6.30 | Final state capture (3 envs, 82 pods, 25% mem util)     | ✅     |

### Phase E — Teardown Bug Fix (Real Bug Found + Fixed)

| ID   | Task                                                    | Status |
|------|---------------------------------------------------------|--------|
| 6.31 | Discovered EBS orphan bug after Day 1 teardown          | ✅     |
| 6.32 | Rewrite pre-destroy-cleanup.sh top-down (CNCF pattern)  | ✅     |
| 6.33 | Integrate pre-destroy into destroy.sh (single command)  | ✅     |
| 6.34 | Verify on stuck state (14 PVCs Terminating handled)     | ✅     |

### Phase F — Documentation

| ID   | Task                                                    | Status |
|------|---------------------------------------------------------|--------|
| 6.35 | Day 1 multi-env canary isolation demo doc               | ✅     |
| 6.36 | Day 2 multi-env GitOps sprint wrap-up doc               | ✅     |
| 6.37 | CNPG multi-env bootstrap timing learning doc            | ✅     |
| 6.38 | ADR-010: Multi-env Kustomize overlay pattern            | ✅     |
| 6.39 | ADR-011: Per-env canary isolation                       | ✅     |
| 6.40 | ADR-012: EKS node sizing for multi-env                  | ✅     |

**Deliverable:** Three environments (dev + staging + prod) running side
by side on a single EKS cluster. Each canary cycle is fully isolated:
ingress host per env, namespace-scoped AnalysisRun queries, distinct
pod template hashes. Production safety pattern (manual sync) demonstrated.
Multi-env SLO rules emit one series per namespace via regex selector +
by-clause aggregation. Teardown leaves zero EBS orphans via the CNCF
top-down deletion pattern.

---

## Week 7+ — Polish & Productionization

Atlas's core architecture is complete. Remaining work is about making
it more discoverable, more reproducible, and more production-ready.

### Polish for portfolio

| ID   | Task                                                    | Status |
|------|---------------------------------------------------------|--------|
| 7.1  | Top-level README rewrite (CNCF-style, factual)          | ⏳     |
| 7.2  | Loom video walkthrough (~5-7 min)                       | ⏳     |
| 7.3  | Screenshot pack — bootstrap → multi-env → matrix → teardown | ⏳ |
| 7.4  | Resume bullet drafting                                  | ⏳     |

### Make local dev faster

| ID   | Task                                                    | Status |
|------|---------------------------------------------------------|--------|
| 7.5  | Split dev overlay into `kind-dev/` and `eks-dev/`       | ⏳     |
| 7.6  | Document Colima setup for M1 Mac kind                   | ⏳     |
| 7.7  | Add make target: `make local-up` → kind + Atlas full stack | ⏳  |

### Close the GitOps loop

| ID   | Task                                                    | Status |
|------|---------------------------------------------------------|--------|
| 7.8  | GitHub Actions CI: backend image build + GHCR push      | ⏳     |
| 7.9  | ArgoCD Image Updater for auto-promotion to dev          | ⏳     |
| 7.10 | Document the full developer commit → prod path          | ⏳     |

### Production-grade hardening

| ID   | Task                                                    | Status |
|------|---------------------------------------------------------|--------|
| 7.11 | DR runbook test — actually exercise PITR on EKS         | ⏳     |
| 7.12 | Alertmanager routing to Slack webhook (per-env)         | ⏳     |
| 7.13 | Network policies between namespaces                     | ⏳     |
| 7.14 | Pod Security Admission profiles per env                 | ⏳     |
| 7.15 | Mixed on-demand + spot capacity strategy                | ⏳     |

### Possible Week 8+

These are real features Atlas could grow into. Not committed.

- **External Secrets Operator** wiring (IRSA is already provisioned for it)
- **OPA Gatekeeper** policies (no privileged pods, required labels, etc.)
- **Velero** for cluster-level backup/restore
- **Service mesh** (Linkerd) for mTLS between services
- **Multi-cluster GitOps** — second cluster managed by the same ArgoCD
- **Cost dashboards** via Kubecost
- **Karpenter** instead of managed node groups

---

## Definition of Done

A task is done when:
1. Code uses current/stable syntax (no deprecated APIs)
2. Code is committed with a conventional commit message
3. Code is pushed to GitHub
4. Status updated in this ROADMAP.md
5. If a feature — manually tested and verified working
6. If a non-trivial decision — captured in an ADR

---

## Conventional Commit Convention

Format: `<type>(<scope>): <description>`

**Types:** `feat`, `fix`, `docs`, `refactor`, `perf`, `test`, `chore`, `style`, `demo`

**Scopes:** `kind`, `eks`, `argocd`, `database`, `observability`, `delivery`, `ingress`, `terraform`, `workloads`, `multi-env`, `slo`, `matrix`, `bootstrap`, `scripts`, `readme`, `adr`, `runbook`, `incident`, `load-tests`, `k6`, `learning`

**Examples:**
- `feat(multi-env): rebuild prod overlay for EKS multi-env deployment`
- `feat(slo): multi-env SLO rules with dynamic per-env labeling`
- `fix(scripts): rewrite teardown to follow CNCF ownership chains`
- `demo(matrix): STAGING abort canary for isolation matrix test`
- `docs(adr): ADR-011 per-env canary isolation`
