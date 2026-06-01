# Atlas Platform — Engineering Roadmap

> **Goal:** Build a production-grade GitOps platform on Kubernetes that demonstrates senior-level depth across GitOps, HA databases, SLO-based observability, and progressive delivery.

**Owner:** Prashant
**Timeline:** 6 weeks
**Status legend:** ⏳ Pending · 🔨 In Progress · ✅ Done

---

## Architecture Overview

```
Atlas Platform
├── Infrastructure       — kind (local) + EKS (validation weekend)
├── GitOps Engine        — ArgoCD with App-of-Apps + ApplicationSets
├── Workloads            — 3-tier app (frontend, API, HA Postgres)
├── Database HA          — CloudNativePG operator + WAL archiving + PITR
├── Observability        — Prometheus + Grafana + Loki + SLO burn-rate alerts
├── Progressive Delivery — Argo Rollouts + NGINX traffic routing + analysis
└── Documentation        — ADRs + Incident postmortems + Runbooks
```

---

## Week 1 — Foundation & Local Cluster ✅

Establishing the development environment and reproducible cluster bootstrap.

| ID   | Task                                                    | Commit Message                                              | Status |
|------|---------------------------------------------------------|-------------------------------------------------------------|--------|
| 1.1  | Project README with architecture overview               | `docs(readme): add project overview and architecture`       | ✅     |
| 1.2  | ROADMAP.md (this file)                                  | `docs(roadmap): add 6-week engineering roadmap`             | ✅     |
| 1.3  | Multi-node kind cluster config (1 cp + 2 workers)       | `feat(kind): add multi-node cluster configuration`          | ✅     |
| 1.4  | Bootstrap script: cluster up                            | `feat(bootstrap): add cluster provisioning script`          | ✅     |
| 1.5  | Bootstrap script: cluster teardown                      | `feat(bootstrap): add cluster teardown script`              | ✅     |
| 1.6  | Verify-setup script for environment checks              | `feat(scripts): add environment verification script`        | ✅     |
| 1.7  | ADR-001: Why kind over minikube/k3d                     | `docs(adr): add ADR-001 cluster runtime decision`           | ✅     |
| 1.8  | Local registry for fast image push/pull                 | `feat(kind): add local container registry`                  | ✅     |
| 1.9  | metrics-server installed via manifest                   | `feat(platform): add metrics-server`                        | ✅     |
| 1.10 | Makefile for common operations                          | `feat(scripts): add Makefile for project operations`        | ✅     |

**Week 1 deliverable:** `make up` brings up a 3-node kind cluster with metrics-server and local registry. `make down` tears it down cleanly.

---

## Week 2 — GitOps Engine (ArgoCD) ✅

Installing ArgoCD and establishing the App-of-Apps pattern.

| ID   | Task                                                    | Commit Message                                              | Status |
|------|---------------------------------------------------------|-------------------------------------------------------------|--------|
| 2.1  | ArgoCD installation via Helm values                     | `feat(argocd): add ArgoCD helm installation`                | ✅     |
| 2.2  | ArgoCD bootstrap script                                 | `feat(bootstrap): add ArgoCD bootstrap automation`          | ✅     |
| 2.3  | App-of-Apps root application                            | `feat(argocd): add root app-of-apps application`            | ✅     |
| 2.4  | Application set for platform components                 | `feat(argocd): add platform applicationset`                 | ✅     |
| 2.5  | ADR-002: ArgoCD vs Flux decision                        | `docs(adr): add ADR-002 gitops engine choice`               | ✅     |
| 2.6  | Kustomize base for three-tier app                       | `feat(workloads): add kustomize base for three-tier app`    | ✅     |
| 2.7  | Kustomize dev overlay                                   | `feat(workloads): add dev environment overlay`              | ✅     |
| 2.8  | Kustomize staging overlay                               | `feat(workloads): add staging environment overlay`          | ✅     |
| 2.9  | Kustomize prod overlay                                  | `feat(workloads): add prod environment overlay`             | ✅     |
| 2.10 | Runbook: ArgoCD sync troubleshooting                    | `docs(runbook): add ArgoCD sync troubleshooting guide`      | ✅     |

**Week 2 deliverable:** Push a YAML change to GitHub → ArgoCD detects → cluster reconciles automatically. Three environments (dev/staging/prod) demonstrably different via Kustomize overlays. **Note:** staging/prod exist in Git but run dev-only locally — full multi-env validated on EKS weekend.

---

## Week 3 — HA Database with CloudNativePG ✅

Real HA Postgres replacing the single-pod database from Project 1.

| ID   | Task                                                    | Commit Message                                              | Status |
|------|---------------------------------------------------------|-------------------------------------------------------------|--------|
| 3.1  | CloudNativePG operator install                          | `feat(database): add cloudnative-pg operator`               | ✅     |
| 3.2  | Postgres Cluster CR — 1 primary + 2 replicas            | `feat(database): add HA postgres cluster manifest`          | ✅     |
| 3.3  | MinIO deployment (local S3 for WAL)                     | `feat(database): add minio for WAL archive storage`         | ✅     |
| 3.4  | WAL archiving configuration                             | `feat(database): configure WAL archiving to minio`          | ✅     |
| 3.5  | Backup schedule (daily base backup)                     | `feat(database): add scheduled base backup`                 | ✅     |
| 3.6  | Connection pooler (PgBouncer)                           | `feat(database): add pgbouncer connection pooling`          | ✅     |
| 3.7  | ADR-003: CloudNativePG vs Crunchy Operator              | `docs(adr): add ADR-003 postgres operator choice`           | ✅     |
| 3.8  | Runbook: PITR — point in time recovery                  | `docs(runbook): add PITR procedure with verification`       | ✅     |
| 3.9  | Runbook: Manual failover                                | `docs(runbook): add manual failover procedure`              | ✅     |
| 3.10 | INC-001 + INC-002: Failover GameDays                    | `docs(incident): add INC-001/002 failover postmortems`      | ✅     |

**Week 3 deliverable:** Postgres survives primary pod deletion. Can restore to any point in time within retention window. PITR procedure verified and documented. Two failover GameDays documented with measured ~15s recovery.

---

## Week 4 — Observability & SLOs ✅

Three pillars of observability with SLO-based alerting (Google SRE pattern).

| ID   | Task                                                    | Commit Message                                              | Status |
|------|---------------------------------------------------------|-------------------------------------------------------------|--------|
| 4.1  | kube-prometheus-stack Helm install                      | `feat(observability): add prometheus stack`                 | ✅     |
| 4.2  | Loki + Promtail for log aggregation                     | `feat(observability): add loki and promtail`                | ✅     |
| 4.3  | ServiceMonitors / PodMonitors for workloads             | `feat(observability): add servicemonitors for workloads`    | ✅     |
| 4.4  | SLO definitions + recording rules                       | `feat(observability): define SLOs and SLIs`                 | ✅     |
| 4.5  | Multi-window burn-rate alerts                           | `feat(observability): add multi-burn-rate alerts`           | ✅     |
| 4.6  | Grafana dashboards (cluster, CNPG, SLO burn-down)       | `feat(observability): add grafana dashboards`               | ✅     |
| 4.7  | ADR-004: Loki vs ELK decision                           | `docs(adr): add ADR-004 log aggregation choice`             | ✅     |
| 4.8  | Runbook: SLO breach response                            | `docs(runbook): add SLO breach response playbook`           | ✅     |
| 4.9  | Monitoring coverage doc                                 | `docs: add monitoring coverage and known gaps`              | ✅     |
| 4.10 | INC-003 Availability GameDay                            | `docs(incident): add INC-003 availability gameday`          | ✅     |

**Week 4 deliverable:** Defined SLOs (DB availability 99.5%, latency 99%, backup freshness 99.9%). Multi-window burn-rate alerts loaded and correctly inactive when SLOs are met. Three Grafana dashboards live. INC-003 documented HA primary failover with no measurable SLO impact + the "GitOps resists chaos injection" finding.

---

## Week 5 — Progressive Delivery 🔨

Argo Rollouts with NGINX traffic routing, automated metric-gated promotion, and rollback.

| ID   | Task                                                    | Commit Message                                              | Status |
|------|---------------------------------------------------------|-------------------------------------------------------------|--------|
| 5.1  | Argo Rollouts controller install                        | `feat(delivery): install argo rollouts controller`          | ✅     |
| 5.2  | NGINX ingress controller install                        | `feat(ingress): install nginx ingress controller`           | ✅     |
| 5.3  | Convert backend Deployment to Rollout                   | `feat(delivery): convert backend to rollout`                | ✅     |
| 5.4  | Wire NGINX trafficRouting on Rollout                    | `feat(delivery): wire nginx canary traffic split`           | ✅     |
| 5.5  | AnalysisTemplate using Prometheus metrics               | `feat(delivery): add prometheus analysis template`          | ✅     |
| 5.6  | Automated rollback on SLI breach                        | `feat(delivery): wire automated canary rollback`            | ✅     |
| 5.7  | k6 load testing for canary traffic                      | `feat(load-tests): add k6 baseline load tests`              | ✅     |
| 5.8  | ADR-005: Rollouts vs Flagger vs native Deployment       | `docs(adr): ADR-005 progressive delivery choice`            | ✅     |
| 5.9  | INC-004 GameDay: bad canary auto-rollback               | `docs(incident): INC-004 canary auto-rollback`              | ✅     |
| 5.10 | Week 5 runbook + ROADMAP wrap                           | `docs(runbook): canary rollback procedures`                 | ✅     |

**Week 5 outcome:** Atlas now ships releases through a metric-gated canary. A v2 release auto-promoted successfully (5.5) — success rate at 100%, p95 latency at 4.75ms, no human in the loop. A deliberately broken v3 release (FAIL_RATE=0.5) was rejected within 90 seconds (5.9) — the success-rate gate caught it at 50.4%, triggered auto-rollback, stable ReplicaSet stayed at 4/4 Ready throughout. Under sustained k6 load (5.7), the backend held 100 RPS for 5 minutes with zero errors and 6.37ms end-to-end p95 latency. NGINX traffic splitting works by exact HTTP weight, independent of pod ratio.

---

## Week 6 — Production Validation & Documentation

EKS validation weekend + final documentation polish for resume/interview readiness.

| ID   | Task                                                    | Commit Message                                              | Status |
|------|---------------------------------------------------------|-------------------------------------------------------------|--------|
| 6.1  | Terraform module for VPC                                | `feat(terraform): add vpc module`                           | ⏳     |
| 6.2  | Terraform module for EKS cluster                        | `feat(terraform): add eks cluster module`                   | ⏳     |
| 6.3  | Terraform module for IAM/IRSA                           | `feat(terraform): add iam and irsa module`                  | ⏳     |
| 6.4  | EKS bootstrap script                                    | `feat(bootstrap): add eks deployment automation`            | ⏳     |
| 6.5  | Deploy Atlas to EKS (weekend run)                       | `docs(eks): add eks deployment validation`                  | ⏳     |
| 6.6  | Capture EKS screenshots + walkthrough                   | `docs(eks): add eks validation evidence`                    | ⏳     |
| 6.7  | Tear down EKS cleanly                                   | `feat(bootstrap): add eks teardown automation`              | ⏳     |
| 6.8  | INC-005: Real incident postmortem from EKS run          | `docs(incident): add INC-005 postmortem`                    | ⏳     |
| 6.9  | Project demo video (5 min)                              | `docs(readme): add demo video link`                         | ⏳     |
| 6.10 | Final README polish + resume snippet                    | `docs(readme): finalize project documentation`              | ⏳     |

**Week 6 deliverable:** Atlas validated on real EKS (with screenshots + video). 5 ADRs, 5 incident docs, comprehensive runbooks. README that closes interviews.

---

## Definition of Done

A task is done when:
1. Code is written using current/stable syntax (no deprecated APIs)
2. Code is committed with a conventional commit message
3. Code is pushed to GitHub (green dot earned)
4. Status updated in this ROADMAP.md
5. If a feature — manually tested and verified working

---

## Conventional Commit Convention

Format: `<type>(<scope>): <description>`

**Types:** `feat`, `fix`, `docs`, `refactor`, `perf`, `test`, `chore`, `style`

**Scopes:** `kind`, `argocd`, `database`, `observability`, `delivery`, `ingress`, `terraform`, `workloads`, `bootstrap`, `scripts`, `readme`, `adr`, `runbook`, `incident`, `load-tests`, `learning`

**Examples:**
- `feat(kind): add multi-node cluster configuration`
- `feat(argocd): add root app-of-apps application`
- `fix(database): correct PVC storage class reference`
- `docs(adr): add ADR-001 cluster runtime decision`
- `feat(delivery): wire nginx canary traffic split`
