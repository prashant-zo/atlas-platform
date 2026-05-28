# Three-Tier App — Service Level Objectives

**Owner:** Atlas Platform Team
**Last Reviewed:** 2026-05-28
**Review Cadence:** Quarterly

## Service Description

The three-tier app is Atlas's representative workload — a backend
service backed by HA Postgres (via CNPG) with PgBouncer pooling and
MinIO-backed WAL archiving for disaster recovery.

## SLO Summary

| ID  | Name                  | Target  | Window  | Error Budget |
|-----|-----------------------|---------|---------|--------------|
| 1   | Database Availability | 99.5%   | 28 days | 3h 36m       |
| 2   | Database Latency      | 99.0%   | 28 days | 6h 43m       |
| 3   | Backup Freshness      | 99.9%   | 28 days | 40m 19s      |

---

## SLO 1: Database Availability

**User concern:** Application cannot transact when database is
unreachable.

**SLI:** Boolean composite — Postgres primary `cnpg_collector_up` AND
PgBouncer reporting active server connections `cnpg_pgbouncer_pools_sv_active > 0`.

**SLI Expression (Prometheus):**

\`\`\`promql
(
  max(cnpg_collector_up{namespace="three-tier-dev"}) == bool 1
)
and
(
  max(cnpg_pgbouncer_pools_sv_active{namespace="three-tier-dev"}) > bool 0
)
\`\`\`

**SLO:** 99.5% of time, SLI = 1, measured over 28-day rolling window.

**Error budget:** 0.5% = 3 hours 36 minutes / 28 days.

**Rationale for 99.5%:**
- Dev environment, not customer-facing.
- A single node failure should not exhaust budget within minutes.
- 99.9% (43m/month) would over-promise on local kind infrastructure.
- 99.5% leaves room for one planned maintenance window + recovery
  from one unplanned incident per month.

**Production target:** Would be 99.95% on multi-AZ EKS with
PodDisruptionBudgets and external load balancer.

---

## SLO 2: Database Latency (Connection Pool Wait Time)

**User concern:** Slow queries degrade user-facing response times.

**SLI:** PgBouncer pool acquisition wait time. We measure
`cnpg_pgbouncer_pools_maxwait_us` as the worst-case wait.

**SLI Expression (Prometheus):**

\`\`\`promql
(
  rate(cnpg_pgbouncer_pools_maxwait_us{namespace="three-tier-dev"}[5m]) < bool 50000
)
\`\`\`

**SLO:** 99% of time, max wait < 50ms, measured over 28-day rolling
window.

**Error budget:** 1% = 6 hours 43 minutes / 28 days.

**Rationale for 99% / 50ms:**
- PgBouncer pool acquisition should be sub-millisecond in normal load.
- 50ms means the pool is exhausted (transaction-mode pool size
  reached). Above this, clients queue.
- 1% budget tolerates expected spikes: failover events, large
  transactions, planned scale operations.
- This is a **proxy** for query latency — actual end-user latency
  would require backend application instrumentation (skipped:
  hashicorp/http-echo has no /metrics).

**What this SLO doesn't catch:**
- Slow queries inside Postgres (would need pg_stat_statements scraping).
- Latency from app → PgBouncer (network).

---

## SLO 3: Backup Freshness

**User concern:** If Postgres fails irrecoverably, we need to restore
data with RPO ≤ 26 hours.

**SLI:** Time since most recent successful backup. We allow 26 hours
to give the 02:00 UTC daily backup time to complete and report.

**SLI Expression (Prometheus):**

\`\`\`promql
(
  time() - cnpg_collector_last_available_backup_timestamp{namespace="three-tier-dev"}
) < bool 93600
\`\`\`

**SLO:** 99.9% of time, last backup is < 26 hours old, measured over
28-day rolling window.

**Error budget:** 0.1% = 40 minutes 19 seconds / 28 days.

**Rationale for 99.9%:**
- Backups are the recovery story. Other SLOs describe
  operation under normal conditions; backups describe the worst-case
  recovery floor.
- One missed daily backup ≈ exhausted budget for the month. That's
  the correct framing — missed backups are not "normal."
- The WAL archive continuously protects against data loss between
  base backups (RPO ≈ 5 minutes). This SLO checks the base backup
  chain.

**Related runbooks:**
- `docs/runbooks/postgres-pitr-recovery.md`
- `docs/runbooks/postgres-failover.md`

---

## Burn-Rate Alerting

Each SLO will have multi-window burn-rate alerts (Task 4.5)
following the Google SRE Workbook pattern:

- **Fast burn:** alerting when ≥14.4× normal burn rate over 1 hour
  → would exhaust full month's budget in ≤2 days if sustained.
- **Slow burn:** alerting when ≥1× normal burn rate over 6 hours
  → confirms sustained degradation, not a transient blip.

Combining short-window (1h) and long-window (6h) windows reduces
alert noise while catching real budget exhaustion early.

---

## When SLOs Change

SLOs are reviewed quarterly. Triggers for adjustment:
- Real production traffic patterns differ from assumptions.
- New features change user expectations (e.g., real-time use cases
  demand tighter latency).
- Hardware migration (e.g., local kind → EKS) changes baseline.

Don't tighten SLOs because we're consistently exceeding them —
that's the system performing well. Tighten only when user
expectations actually change.

Don't relax SLOs because we're consistently failing — fix the
underlying problem.
