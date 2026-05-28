# Atlas — Monitoring Coverage

**Last reviewed:** 2026-05-28

## What Is Monitored

| Component | Method | Key Metrics |
|---|---|---|
| Postgres (CNPG) | PodMonitor (auto) | replication lag, backends, WAL, backup timestamp |
| PgBouncer | PodMonitor (auto) | pool waiting/active, maxwait |
| ArgoCD | ServiceMonitor | app health, sync status, sync counts |
| Kubernetes nodes | node-exporter | CPU, memory, disk, network |
| Kubernetes objects | kube-state-metrics | pod/deployment/PVC state |
| Kubelet/cAdvisor | KPS built-in | container CPU/memory, probes |
| Prometheus/Alertmanager/Grafana | self-scrape | stack health |
| All pod logs | Promtail → Loki | stdout/stderr, label-indexed |

## SLOs Tracked

| SLO | Target | Recording Rule |
|---|---|---|
| DB Availability | 99.5% | sli:three_tier_db_available:ratio |
| DB Latency | 99% | sli:three_tier_db_latency:ratio |
| Backup Freshness | 99.9% | sli:three_tier_backup_fresh:ratio |

## Dashboards

- Kubernetes / Compute Resources / Cluster (KPS built-in)
- CloudNativePG (imported)
- Atlas — SLO Burn-Down (custom)

## Alerts

Multi-window burn-rate alerts (fast + slow) per SLO. Route to
docs/runbooks/slo-breach-response.md.

## Known Gaps

1. **No application-level metrics.** The backend is hashicorp/http-echo,
   which exposes no /metrics endpoint. We have no HTTP request rate,
   error rate, or end-user latency. A real backend would add a
   ServiceMonitor and SLOs would include application-level signals.

2. **Latency SLO is a proxy.** We measure PgBouncer pool wait, not
   actual query or request latency. Strong proxy for DB saturation,
   but not true user-facing latency.

3. **No availability replica-count SLI.** We track "primary up" not
   "N healthy replicas." True HA availability would include replica health.

4. **Alertmanager has no real receiver.** Alerts fire into Alertmanager
   but receiver is "null" — no Slack/email/PagerDuty wired. Demonstrable
   in UI; real paging is a production/EKS concern.

5. **Local = dev only.** Staging and prod monitoring exists in Git but
   isn't running locally (8GB constraint). Validated on EKS weekend.

## Why Gaps Are Acceptable

Atlas demonstrates the observability *architecture and patterns* —
ServiceMonitors, SLOs, recording rules, burn-rate alerts, dashboards,
runbooks. The gaps are instrumentation depth, not architectural. Adding
a real backend with /metrics would extend the same patterns, not change
them.
