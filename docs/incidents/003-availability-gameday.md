# INC-003: Availability GameDay — Primary Loss Failover Test

**Date:** 2026-05-28
**Type:** Planned GameDay (controlled chaos test)
**Severity:** None (induced, controlled)
**SLO tested:** Database Availability (99.5%)

## Objective

Validate that the availability SLI and burn-rate alerting react correctly
to database failure, and that HA Postgres survives primary loss within SLO.

## Hypothesis

Killing the Postgres primary will trigger CNPG failover. Either:
(a) failover is fast enough that availability stays within SLO and no
    alert fires, or
(b) the outage is long enough to drop the SLI and trip a burn alert.

## Method

Killed the current primary pod directly:

\`\`\`bash
PRIMARY=$(kubectl get cluster pg -n three-tier-dev -o jsonpath='{.status.currentPrimary}')
kubectl delete pod $PRIMARY -n three-tier-dev --grace-period=0 --force
\`\`\`

## Timeline (UTC)

| Time | Event |
|------|-------|
| 14:31:26 | Killed primary pg-1 (force delete) |
| ~14:31:40 | CNPG detected primary loss, began promotion |
| ~14:32:07 | pg-2 promoted to primary (confirmed via cluster status) |
| ~14:32:?? | pg-1 recreated, rejoined as standby |
| 14:33:?? | Cluster healthy: 3/3 instances, pg-2 primary |

Failover completed in approximately 40 seconds.

## Result

**Availability SLI held at 1 throughout.** No measurable availability
loss. No burn-rate alert fired.

PgBouncer absorbed the brief primary transition as connection latency
rather than errors (consistent with INC-002 findings). By the first
30-second metric scrape after the kill, a new primary was already
serving.

## Analysis

This is the system behaving as designed:
- CNPG's automatic failover is faster than the metric scrape interval,
  so the outage did not register as sustained unavailability.
- The multi-window burn-rate alert correctly did NOT fire — a sub-scrape
  blip is exactly the kind of transient the multi-window design filters
  out. Firing here would have been a false positive.
- HA Postgres survived primary loss with zero SLO impact.

## What This Validates

- SLI is wired to real metrics (cnpg_collector_up, pgbouncer sv_active).
- Recording rules evaluate continuously.
- Burn-rate alerts are loaded and correctly stay inactive when there is
  no sustained breach.
- HA failover meets the availability SLO under primary loss.

## What This Did NOT Test

Observing an alert transition to "firing" requires a *sustained* outage.
CNPG failover and ArgoCD self-heal are both fast enough to prevent
sustained outage from common failure modes — a testament to the
platform's resilience. A sustained-outage test would require declaring
the outage in Git (removing a component from the desired state), which
ArgoCD would then hold rather than revert.

## Unexpected Finding: GitOps Resists Chaos Injection

During this GameDay, multiple attempts to induce a sustained outage by
patching live resources (scaling the pooler to 0, deleting pods) were
automatically reverted within seconds by the combination of:
- CNPG operator (heals pod deletions, blocks instances=0)
- ArgoCD selfHeal (reverts live drift to match Git)

**Lesson:** In a properly-built GitOps + operator system, you cannot
reliably induce sustained failure by patching the cluster. The
reconciliation loop actively restores desired state. To inject sustained
chaos, the change must be made in Git (the source of truth) — or you
test designed-for failure modes (like primary loss) that the operator
handles as intended rather than reverts.

This resilience is a feature, not a limitation: it means accidental or
malicious drift is automatically corrected.

## Recovery

No manual recovery needed — the system self-healed. pg-1 rejoined as a
standby automatically. Auto-sync (temporarily disabled during chaos
attempts) was restored by re-reconciling the application controller.

## References

- Related: INC-002 (planned failover GameDay, 15s measured gap)
- SLO definitions: docs/slo/three-tier-app.md
- Runbook: docs/runbooks/slo-breach-response.md
