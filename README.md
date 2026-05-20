# Atlas Platform

Production-grade GitOps platform on Kubernetes — built to demonstrate senior-level depth across GitOps, HA databases, SLO-based observability, and progressive delivery.

> **Status:** 🔨 Week 1 in progress · See [ROADMAP.md](./ROADMAP.md) for full plan.

---

## What This Is

Atlas is a single-cluster Kubernetes platform implementing the patterns real platform engineering teams use in production:

- **GitOps-driven** — every cluster change goes through Git via ArgoCD
- **HA database** — CloudNativePG operator with streaming replication and WAL archiving
- **SLO-based alerting** — multi-window burn-rate alerts per Google SRE patterns
- **Progressive delivery** — Argo Rollouts canary with automated metric-based analysis
- **Observable** — Prometheus + Grafana + Loki with curated dashboards

The platform deploys a three-tier reference application (frontend, API, Postgres) that exercises every capability of the platform.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      External Traffic                       │
│                            │                                │
│                    nginx-ingress + TLS                      │
│                            │                                │
├────────────────────────────┴────────────────────────────────┤
│                                                             │
│   ┌────────────┐    ┌────────────┐    ┌──────────────┐      │
│   │  Frontend  │    │  Backend   │    │  CloudNative │      │
│   │  (Nginx)   │───▶│  (Node.js) │───▶│  PG Cluster  │      │
│   │  Rollout   │    │  Rollout   │    │  1pri + 2rep │      │
│   └────────────┘    └────────────┘    └──────┬───────┘      │
│         ▲                  ▲                  │              │
│         │                  │                  ▼              │
│   ┌─────┴──────────────────┴─────┐    ┌────────────┐         │
│   │  ArgoCD (App of Apps)        │    │   MinIO    │         │
│   │  ↑ syncs from Git            │    │  WAL + PIT │         │
│   └──────────────────────────────┘    └────────────┘         │
│                                                              │
│   ┌──────────────────────────────────────────────────┐       │
│   │  Observability: Prometheus + Grafana + Loki      │       │
│   │  SLO burn-rate alerts → AlertManager             │       │
│   └──────────────────────────────────────────────────┘       │
│                                                              │
│              3-node kind cluster (local dev)                 │
│           validated on EKS ap-south-1 (weekend run)          │
└──────────────────────────────────────────────────────────────┘
```

---

## Repository Layout

```
atlas/
├── bootstrap/         Cluster + ArgoCD provisioning scripts
├── infrastructure/
│   ├── kind/          kind multi-node cluster config
│   └── terraform/     EKS validation infrastructure
├── platform/          Platform components (Helm values, manifests)
│   ├── argocd/
│   ├── prometheus/
│   ├── grafana/
│   ├── loki/
│   ├── cert-manager/
│   └── ingress-nginx/
├── workloads/         Application workloads
│   ├── app-of-apps/   Root ArgoCD application
│   └── three-tier-app/
│       ├── base/      Kustomize base
│       └── overlays/  Environment overlays (dev/staging/prod)
├── load-tests/        k6 performance tests
├── docs/
│   ├── adr/           Architecture Decision Records
│   ├── incidents/     Incident postmortems
│   └── runbooks/      Operational procedures
└── scripts/           Utility scripts
```

---

## Quick Start

## Quick Start

```bash
# 1. Verify environment is ready
make verify

# 2. Bring cluster online + install platform
make up && make platform

# 3. Check cluster status
make status

# Tear down when done
make down

# See all available operations
make help
```

Requires: Docker (Colima recommended), kind, kubectl, helm. Run `make verify` to check.

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Container runtime | Docker via Colima (M1 native) |
| Cluster (local) | kind (3-node) |
| Cluster (validated) | AWS EKS ap-south-1 |
| GitOps | ArgoCD + App-of-Apps |
| Config management | Kustomize overlays + Helm |
| Database | CloudNativePG operator |
| Object storage | MinIO (S3-compatible, local) / AWS S3 (EKS) |
| Metrics | Prometheus + kube-state-metrics + node-exporter |
| Dashboards | Grafana |
| Logs | Loki + Promtail |
| Alerts | AlertManager |
| Progressive delivery | Argo Rollouts |
| Load testing | k6 |
| TLS (local) | mkcert |
| TLS (cloud) | cert-manager + Let's Encrypt |
| Infrastructure as Code | Terraform |

---

## Documentation

- [ROADMAP.md](./ROADMAP.md) — Engineering plan and status tracking
- [docs/adr/](./docs/adr/) — Architecture Decision Records
- [docs/incidents/](./docs/incidents/) — Incident postmortems
- [docs/runbooks/](./docs/runbooks/) — Operational procedures

---

## License

MIT
