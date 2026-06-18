# Atlas Platform

A GitOps Kubernetes platform with multi-environment progressive delivery,
HA Postgres, and SLO-based observability. Built end-to-end on AWS EKS with
local development via kind.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

---

## Demo Video

**[▶ Watch the 4-minute demo on Vimeo →](https://vimeo.com/1202527585)**

Multi-environment GitOps on AWS EKS with automated canary deployments, 
cross-environment isolation, k6 load testing, and CNCF-pattern teardown.

---

## What's Here

Atlas runs three environments — dev, staging, prod — side by side on a single
EKS cluster. Each environment is fully isolated: distinct pod template hashes,
per-environment ingress hosts, namespace-scoped canary analysis. A failed canary
in one environment cannot affect the others, and prod requires explicit manual
sync (Git is the source of truth, but humans gate every prod change).

The platform exercises a three-tier reference application — frontend (nginx),
backend (HTTP service with Prometheus metrics), and CloudNativePG Postgres
cluster (3 instances + connection pooler) — plus MinIO for backup storage.
Multi-window burn-rate SLO alerts cover all three environments via a single
rule group with dynamic per-environment label injection.

```
┌──────────────────────────────────────────────────────────────────────┐
│                        AWS EKS (ap-south-1)                          │
│                  4× t3.large spot · 2 vCPU / 8 GiB                   │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │  ArgoCD (app-of-apps + ApplicationSets + sync waves)           │  │
│  │  ↓ reconciles from github.com/prashant-zo/atlas-platform       │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                      │
│  ┌───────────────┐    ┌───────────────┐    ┌───────────────┐         │
│  │ three-tier-   │    │ three-tier-   │    │ three-tier-   │         │
│  │ dev           │    │ staging       │    │ prod          │         │
│  │ wave 1, auto  │    │ wave 2, auto  │    │ wave 3, MANUAL│         │
│  ├───────────────┤    ├───────────────┤    ├───────────────┤         │
│  │ • 4× backend  │    │ • 2× backend  │    │ • 3× backend  │         │
│  │   (Rollout)   │    │   (Rollout)   │    │   (Rollout)   │         │
│  │ • 1× frontend │    │ • 2× frontend │    │ • 3× frontend │         │
│  │ • 3× pg-CNPG  │    │ • 3× pg-CNPG  │    │ • 3× pg-CNPG  │         │
│  │ • MinIO       │    │ • MinIO       │    │ • MinIO       │         │
│  └───────┬───────┘    └───────┬───────┘    └───────┬───────┘         │
│          │                    │                    │                 │
│          │     backend.       │   backend-         │   backend-      │
│          │     atlas.local    │   staging.         │   prod.         │
│          │                    │   atlas.local      │   atlas.local   │
│          └────────────────────┴────────────────────┘                 │
│                            │                                         │
│                  ┌─────────┴──────────┐                              │
│                  │  ingress-nginx     │                              │
│                  │  (per-env hosts)   │                              │
│                  └────────────────────┘                              │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │  Observability                                                 │  │
│  │  • Prometheus (kube-prometheus-stack)                          │  │
│  │  • Loki + Promtail                                             │  │
│  │  • Multi-env SLO rules: namespace=~"three-tier-.*"             │  │
│  │  • Per-env burn-rate alerts (Google SRE multi-window pattern)  │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │  Progressive Delivery (per env)                                │  │
│  │  Argo Rollouts canary: 25% → analysis → 50/75/100              │  │
│  │  AnalysisTemplate queries Prometheus, scoped per namespace     │  │
│  │  Auto-aborts on success-rate < 0.99 (2 failed measurements)    │  │
│  └────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Core Capabilities

| Capability | Implementation |
|---|---|
| GitOps engine | ArgoCD with app-of-apps + ApplicationSets |
| Sync ordering | Wave -1 (operators) → 0 (platform) → 1 (dev) → 2 (staging) → 3 (prod manual) |
| Configuration | Kustomize base + overlays; JSON 6902 patches for CRDs |
| HA database | CloudNativePG operator, 3 instances, PgBouncer pooling, daily backups + WAL archive |
| Backup storage | MinIO (S3-compatible) per environment |
| Progressive delivery | Argo Rollouts canary, NGINX traffic split, Prometheus-gated promotion |
| Canary analysis | Per-env namespace-scoped queries; auto-abort on threshold breach |
| Observability | Prometheus + Loki + Grafana; ServiceMonitors per env |
| SLO alerting | Multi-window burn-rate (Google SRE pattern); dynamic per-env labels |
| Infrastructure | Terraform — VPC + EKS + IAM/IRSA modules |
| Node strategy | 4× t3.large spot with t3a.large fallback |
| Teardown | One-command `destroy.sh` with CNCF top-down K8s cleanup; zero EBS orphans |

---

## What's Deployed (Measured)

End of Day 2 sprint (2026-06-10) on a fresh 4-node cluster:

```
kubectl get applications -n argocd
─────────────────────────────────────────────────
platform-argo-rollouts     Synced    Healthy
platform-cnpg-operator     Synced    Healthy
platform-ingress-nginx     Synced    Healthy
platform-kube-prometheus   Synced    Healthy
platform-loki              Synced    Healthy
platform-metrics-server    Synced    Healthy
root-app-of-apps           Synced    Healthy
three-tier-dev             Synced    Healthy   (13 pods)
three-tier-staging         Synced    Healthy   (13 pods)
three-tier-prod            Synced    Healthy   (14 pods)
```

Total cluster: 82 pods across 4 nodes (~21% memory utilization).
SLO recording rules emit one series per env, all at 1.0 (healthy).

---

## Quick Start

### Local (kind, M1 Mac via Colima)

```bash
# Prereqs: Docker (via Colima), kind, kubectl, helm, kustomize
make verify

# Bring up 3-node kind cluster + platform stack + dev environment
make up && make platform && make bootstrap-gitops

# Cluster status
make status

# Tear down
make down
```

### AWS EKS

```bash
# Prereqs: AWS CLI configured with atlas-admin IAM user, Terraform >= 1.5
./infrastructure/terraform/bootstrap.sh

# After ~22 min: 4-node cluster live, kubeconfig configured
./scripts/platform-install.sh
make argocd && make bootstrap-gitops

# After ~10 min: all platform Apps + dev + staging Synced + Healthy
# Prod requires manual sync (production safety pattern):
acd app sync three-tier-prod

# Single-command teardown when done (~$0.20/hour while running)
./infrastructure/terraform/destroy.sh
```

The EKS teardown handles top-down Kubernetes cleanup (ArgoCD → CNPG →
StatefulSets → pods → PVCs → EBS volumes) before running Terraform destroy.
Leaves zero EBS orphans. See [ADR-012](./docs/adr/012-eks-node-sizing-for-multi-env.md)
for cost discussion.

---

## Repository Layout

```
atlas/
├── infrastructure/terraform/    VPC, EKS, IAM/IRSA modules + bootstrap/destroy
├── platform/                    kind config, Helm values
├── gitops/
│   ├── apps/                    ApplicationSets (workloads-non-prod, workloads-prod)
│   ├── platform/                Platform Application sources (Prometheus rules, etc.)
│   └── workloads/three-tier-app/
│       ├── base/                Env-neutral manifests
│       ├── database/            CNPG Cluster + MinIO
│       └── overlays/
│           ├── dev/             4 replicas, debug logging
│           ├── staging/         2 replicas, info logging
│           └── prod/            3 replicas, warn logging, manual sync
├── load-tests/k6/               Parameterized k6 (NAMESPACE + HOST_HEADER)
├── scripts/                     pre-destroy-cleanup, platform-install, helpers
├── docs/
│   ├── adr/                     12 Architecture Decision Records (see below)
│   ├── incidents/               5 incident postmortems
│   ├── runbooks/                Operational procedures
│   └── learning/                Sprint capture docs
├── Makefile                     make verify | up | platform | argocd | status | down
└── ROADMAP.md                   Per-week task tracking
```

---

## Architecture Decisions

Atlas documents non-trivial decisions as ADRs. Each captures context, the
decision, alternatives considered, and reversibility.

| ADR | Topic |
|---|---|
| [001](./docs/adr/001-cluster-runtime.md) | Why kind for local development |
| [002](./docs/adr/002-gitops-engine.md) | ArgoCD over Flux |
| [003](./docs/adr/003-postgres-operator.md) | CloudNativePG over Crunchy |
| [004](./docs/adr/004-log-aggregation.md) | Loki over ELK |
| [005](./docs/adr/005-progressive-delivery-with-argo-rollouts.md) | Argo Rollouts over Flagger |
| [006](./docs/adr/006-multi-module-terraform-with-bash-orchestration.md) | Multi-module Terraform + bash orchestration |
| [007](./docs/adr/007-single-nat-gateway-multi-az.md) | Single NAT gateway across AZs (cost) |
| [008](./docs/adr/008-spot-only-node-group.md) | Spot-only node group |
| [009](./docs/adr/009-podinfo-for-canary-validation.md) | podinfo backend for canary metrics |
| [010](./docs/adr/010-multi-env-kustomize-overlay-pattern.md) | Multi-env Kustomize + JSON 6902 for CRDs |
| [011](./docs/adr/011-per-env-canary-isolation.md) | Per-env canary isolation mechanism |
| [012](./docs/adr/012-eks-node-sizing-for-multi-env.md) | EKS node sizing for multi-env coexistence |

---

## Selected Learning Notes

Real bugs and discoveries documented along the way:

- [Kustomize strategic-merge CRD trap](./docs/learning/week-5-delivery/kustomize-strategic-merge-crd-trap.md)
  — Why JSON 6902 is mandatory for Rollout / AnalysisTemplate / Cluster patches
- [CNPG multi-env bootstrap timing](./docs/learning/week-6-eks/cnpg-multi-env-bootstrap-timing.md)
  — Sequential sync waves prevent webhook race conditions
- [Multi-env canary isolation demo](./docs/learning/week-6-eks/multi-env-canary-isolation-demo.md)
  — Phase 1 success + Phase 2 abort, captured cross-env state at each step
- [Day 2 multi-env GitOps sprint wrap-up](./docs/learning/week-6-eks/multi-env-gitops-day-2.md)
  — Prod overlay, multi-env SLO, matrix tests, EBS orphan bug fix

---

## Tech Stack

| Layer | Technology |
|---|---|
| Cluster (local) | kind 0.24.x (3-node) on Colima |
| Cluster (cloud) | AWS EKS 1.31, ap-south-1 |
| Infrastructure-as-code | Terraform 1.5+ |
| GitOps | ArgoCD 7.6.x (Helm) |
| Configuration | Kustomize 5.x |
| Database | CloudNativePG operator 1.24.x |
| Object storage | MinIO (S3-compatible) |
| Metrics | Prometheus + kube-state-metrics + node-exporter (kube-prometheus-stack 65.x) |
| Logs | Loki + Promtail |
| Dashboards | Grafana |
| Alerts | Alertmanager (multi-window burn-rate) |
| Progressive delivery | Argo Rollouts 1.7.x |
| Ingress | ingress-nginx |
| Load testing | k6 0.x (parameterized for any env) |
| Container runtime | Docker via Colima (M1 native) |

---

## Documentation Index

- [ROADMAP.md](./ROADMAP.md) — Per-week task status, Week 7+ follow-ups
- [docs/adr/](./docs/adr/) — 12 Architecture Decision Records
- [docs/incidents/](./docs/incidents/) — 5 incident postmortems including
  failover GameDays and canary auto-rollback
- [docs/runbooks/](./docs/runbooks/) — Operational procedures (PITR, failover,
  ArgoCD sync troubleshooting, etc.)
- [docs/learning/](./docs/learning/) — Sprint capture docs and lessons learned

---

## Operational Notes

### Removing an ArgoCD Application managed by an ApplicationSet

When removing a component managed by the platform ApplicationSet, follow this
delete order to avoid finalizer deadlocks:

1. Set the Application's sync policy to manual (or disable auto-prune) via the
   ArgoCD UI
2. Manually sync once with prune enabled to clean up all managed resources
3. Only after the Application shows 0 resources, remove its source directory
   from Git

If you delete the directory first, the Application can get stuck in
`Terminating` state because its finalizer cannot load the source to determine
what to prune. See [INC-001](./docs/incidents/001-applicationset-finalizer-deadlock.md)
and the corresponding
[runbook](./docs/runbooks/argocd-application-stuck-terminating.md).

---

## License

[MIT](./LICENSE)
