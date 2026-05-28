# Community Dashboard Thresholds vs Your SLOs

**Date:** 2026-05-28
**Context:** CNPG official Grafana dashboard imported into Atlas

## What Happened

After importing CloudNativePG's official Grafana dashboard, two panels
showed warning states:
- "Backups: Degraded" (last scheduled backup 26h old)
- "WAL: Unsynced"

Meanwhile, our own SLO recording rule `sli:three_tier_backup_fresh:ratio`
read 1 (healthy), and the cluster's `ContinuousArchiving` condition
reported `status: True, "Continuous archiving is working"`.

## The Resolution

Both warnings were the community dashboard applying its own built-in
thresholds, which are stricter (or differently-tuned) than the SLOs we
defined for this environment:

- The backup panel flagged 26h as degraded; our backup-freshness SLO
  allows up to 26h (daily 02:00 UTC schedule + 2h grace). A near-miss
  on the dashboard's threshold, well within our SLO.
- The WAL panel flagged a long interval since the last archived segment.
  On a near-idle dev database (TPS ~4), WAL segments fill slowly. With
  archive_timeout=5min, archiving still happens, just with near-empty
  segments. The cluster condition confirmed archiving works.

A manual backup (`kubectl apply` a Backup CR) completed successfully,
confirming the entire chain end-to-end.

## The Lesson

**When a community dashboard's threshold disagrees with your documented
SLO, your SLO is the source of truth.** The dashboard reflects the
dashboard author's opinion of "healthy" for a generic deployment. Your
SLO reflects what *your* service actually needs, with documented
rationale and error budgets.

Don't chase a community dashboard's amber state if your SLI says you're
meeting your committed objective. Either:
1. Accept the dashboard's threshold is conservative (and ignore the panel), or
2. Customize the dashboard's threshold to match your SLO (more work,
   keeps the visual honest).

For Atlas, we accept the conservative default and rely on our own SLO
recording rules + burn-rate alerts as the authoritative signal.

## Interview Talking Point

> "After importing CloudNativePG's Grafana dashboard, it flagged backups
> as degraded. But my own backup-freshness SLI read healthy, and the
> CNPG cluster condition confirmed continuous archiving was working. The
> dashboard's built-in threshold was just stricter than the SLO I'd
> defined for that environment. The lesson: a community dashboard
> encodes someone else's opinion of healthy. Your documented SLO, with
> its rationale and error budget, is the authoritative signal. I verified
> the chain with a manual backup and moved on rather than chasing a
> false positive."
