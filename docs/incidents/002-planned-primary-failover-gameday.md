# INC-002: Planned Primary Failover GameDay Exercise

**Date:** 2026-05-26
**Author:** Prashant
**Status:** Resolved (planned exercise — no real incident)
**Severity:** N/A (controlled test)
**Duration:** ~15 seconds app-side outage; ~2 minutes to full 3-node steady-state
**Components:** Postgres Cluster `pg` in `three-tier-dev`

## Summary

A controlled GameDay exercise injecting unplanned primary failure on the dev
Postgres cluster to validate the failover runbook and measure real-world
recovery time. CNPG detected the primary loss, promoted standby pg-1 to
primary, and the application path through PgBouncer recovered in approximately
15 seconds. The previously-primary pod (pg-2) was recreated as a new standby
with a fresh IP and rejoined replication within ~2 minutes. Notably, the
continuous query loop recorded **0 failed queries** during the outage — every
query that would have failed against the dead primary was instead held by
PgBouncer until the new primary came online, then forwarded successfully.
The application experienced the failover as a 15-second latency spike, not
as error responses.

## Timeline

All times UTC, recorded in real-time from the continuous query loop and
cluster watch terminal.

- **T=0 (10:04:04)** — Injected failure: `kubectl delete pod pg-2 --grace-period=0 --force`
  against current primary pg-2 (IP 10.244.2.63)
- **T+2s (10:04:06)** — Last successful query against old primary (loop entry
  `success=198`)
- **T+2s to T+17s** — Query loop paused; no FAIL entries recorded (queries
  blocked rather than failed-fast; see "Notable Finding" below)
- **T+~10s (10:04:14)** — pg-2 respawned as new pod with fresh PVC and IP
  10.244.2.67 (observed at age 2m16s when checked at 10:06:30)
- **T+17s (10:04:21)** — First successful query against new primary
  pg-1 (IP 10.244.1.76), loop entry `success=199`
- **T+~2min (~10:06:12)** — Full cluster steady-state: 3/3 pods Running,
  replication restored with 2 streaming standbys (pg-2 and pg-3)

## Root Cause

This was a planned exercise. The "cause" being tested: what happens when a
single Postgres primary pod fails unexpectedly?

## Detection

For this exercise: explicit observation via continuous query loop plus
`kubectl` watches on cluster state.

In a real incident, detection would come from:
- Application 5xx rate alert
- Postgres exporter metrics (Week 4)
- CNPG cluster condition transitions (Week 4)

This exercise confirms a gap: Atlas currently lacks automated alerting on
database failover events. Addressed in Week 4 observability work.

## Resolution

No human intervention was required. The CNPG operator handled the entire
failover automatically:

1. Operator detected pg-2 terminated via kubelet watch
2. Operator examined remaining standbys' WAL replay positions
3. Operator promoted pg-1 (the most up-to-date standby) to primary
4. The `pg-rw` Service endpoint flipped to pg-1's IP (10.244.1.76)
5. PgBouncer reconnected its upstream to the new primary
6. Kubernetes scheduled a replacement pod for pg-2, which CNPG bootstrapped
   as a new standby (new IP 10.244.2.67 — fresh PVC, fresh pod identity)

The failover runbook (`docs/runbooks/postgres-failover.md`) was followed
only for verification. Step 2 ("Watch The Failover Complete") was sufficient.
Steps 3 and 4 (diagnosis and manual promotion) were not needed.

## Measured Outcomes

| Metric | Value | Target | Result |
|---|---|---|---|
| Detection latency (app saw first outage) | ~2s | <30s | PASS |
| Application outage window | ~15s | <30s | PASS |
| Failed queries during outage | 0 | 0 expected via pool | PASS |
| Time-skipped queries during outage | ~30 | N/A | Pool absorbed as latency |
| Successful queries after recovery | 142 (continued loop) | N/A | Pool reconnected cleanly |
| Cluster full recovery | ~2 minutes | <5 min | PASS |
| Replication restored | 2 streaming standbys | 2 | PASS |

## Notable Finding: PgBouncer Held Connections Across Failover

The continuous query loop showed **`failed=0` throughout the entire outage**,
despite a clear 15-second gap with no output between `success=198` and
`success=199`.

This means the `psql` queries did not fail-fast against the dead primary.
Instead, PgBouncer held the client connections open while waiting for the
upstream `pg-rw` Service to point at a healthy backend. When the new primary
(pg-1) came online and `pg-rw` updated, PgBouncer forwarded the queued
queries successfully.

**From the application's perspective, the failover was experienced as a
15-second latency spike, not as a burst of errors.** This is exactly the
production behavior PgBouncer is designed for — turning failures into
latency, which is generally more recoverable for applications than hard
errors.

A real backend with reasonable query timeouts (e.g., 30s) would have seen
its slow queries complete successfully. A backend with aggressive timeouts
(<15s) would have seen a small number of timeout errors. The exact failure
mode depends on application-side configuration, but the pool dramatically
softens the impact in either case.

## What Went Well

- **Automatic failover required zero human intervention.** CNPG handled
  detection, promotion, and reconciliation without manual steps.
- **PgBouncer absorbed the failover invisibly.** No errors observed at the
  client side — only latency.
- **The old primary rejoined automatically.** pg-2 was recreated with a
  fresh PVC, bootstrapped via pg_basebackup from the new primary, and
  joined replication within ~2 minutes. No manual reseed required.
- **Total outage window matched expectations.** 15 seconds is within the
  runbook's documented 10-30 second range for CNPG-managed automatic
  failover with default health-probe intervals.
- **Per-environment isolation held.** This was a destructive test on dev;
  staging and prod were unaffected. The blast radius matched the design.

## What Went Wrong / Could Be Better

- **No alerting on the failover event.** Detection was via manual
  observation. In production, a 15-second outage might escape notice if
  no metrics/alerts are wired up. Addressed in Week 4.
- **Loop classifier missed the "hung connection" case.** The query loop
  was designed to count failed queries, but PgBouncer's connection holding
  meant queries blocked rather than failed. The richer measurement turned
  out to be "queries delayed" rather than "queries failed." Next GameDay's
  loop should also record per-query latency to capture this directly.
- **No baseline latency measurement.** We don't know whether queries
  normally take 50ms vs 200ms, so we can't compute a true "latency tail"
  contribution from the failover. Future tests should capture p50/p99
  baselines before injection.
- **Pod respawn IP changed (10.244.2.63 → 10.244.2.67).** This is normal
  Kubernetes behavior — PVCs persist but Pod IPs don't. Just worth noting
  for monitoring dashboards: don't track Postgres pods by IP, track by
  pod name or label.

## Action Items

- [ ] **Add Prometheus alert on Cluster condition != "Cluster in healthy state"** — Week 4
- [ ] **Add alert on PgBouncer pool upstream failure** — Week 4
- [ ] **Add SLO-burn-rate alert on application 5xx + p99 latency** — Week 4
- [ ] **Enhance GameDay loop to record per-query latency** — next exercise
- [ ] **Document baseline query latency** before next GameDay
- [ ] **Schedule quarterly failover GameDays** once observability is in place
- [ ] **Test other failure modes**: pod eviction, node loss, network partition
  between PgBouncer and Postgres

## Lessons Learned

**The most important lesson: the GameDay revealed something the design
documents implied but I had not verified.** PgBouncer's connection holding
during failover is a documented behavior, but seeing the actual data —
`failed=0` across the gap — turned an architectural assumption into a
confirmed observation. That's the entire point of GameDays.

**The second lesson: build the right measurement before the test.**
The loop I wrote counted failures, but the interesting metric turned out
to be the gap. Next time I design a chaos experiment, I'll record both —
discrete failures AND latency distribution — because the pool behavior I
expected to see as failures showed up as latency instead.

**The third lesson, more general: the operator pattern delivers value
specifically in the recovery path.** The cluster ran for 44 hours of
boring uptime before this test. Those 44 hours don't demonstrate operator
value. The 15-second self-healing window does. The same is true of
PgBouncer, Kubernetes itself, ArgoCD — most platform tooling earns its
existence in the small windows when something goes wrong.

## References

- [Failover runbook](../runbooks/postgres-failover.md) — used during the exercise
- [INC-001](./001-applicationset-finalizer-deadlock.md) — previous documented incident
- CNPG failover documentation: https://cloudnative-pg.io/documentation/current/failover/
- Background: Google SRE Workbook, Ch. 9 on testing reliability:
  https://sre.google/workbook/testing-reliability/
