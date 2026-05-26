# CNPG PgBouncer: Admin Console Inaccessible By Default

**Date:** 2026-05-26
**Component:** CNPG-managed PgBouncer Pooler
**Severity:** Cosmetic — pool functions, only the inspection console is off-limits

## What I Found

CNPG's Pooler CR ships PgBouncer with a restricted admin console:

- `admin_users = pgbouncer` (in pgbouncer.ini)
- `local pgbouncer pgbouncer peer` (in pg_hba.conf — only peer auth)
- No socket files in `/tmp/` (peer auth uses a socket path that's not
  easily discoverable from outside the running pgbouncer process)

Result: there's no obvious way to run `SHOW POOLS` or other admin
queries from kubectl exec.

## Why CNPG Does This

PgBouncer's admin console can issue commands that affect production:
`RECONNECT`, `KILL`, `SHUTDOWN`. CNPG locks it down by default and
expects operators to use the operator's own observability (Prometheus
metrics, kubectl events) rather than direct PgBouncer commands.

This is a sound security default for a managed component.

## How To Actually Observe The Pool

Three production-appropriate alternatives, in order of effort:

1. **Prometheus metrics**. The Pooler CR exposes pgbouncer_exporter
   metrics if `monitoring.enablePodMonitor` is set on the Pooler. After
   we install kube-prometheus-stack in Week 4, we'll wire this up
   and get pool stats in Grafana.

2. **CNPG cluster events**. `kubectl describe pooler pg-pooler-rw -n
   three-tier-dev` shows pool state at a high level.

3. **Pod logs**. PgBouncer logs pool errors and slow queries. Tail with
   `kubectl logs -n three-tier-dev -l cnpg.io/poolerName=pg-pooler-rw -f`.

## What Doesn't Work (And Why I Tried)

Running `psql -h /tmp -U pgbouncer -d pgbouncer -c "SHOW POOLS"`
inside the pgbouncer container — the socket path is non-standard
and not in /tmp. Without locating the actual socket, peer auth can't
connect.

## Interview Talking Point

> "CNPG's Pooler intentionally restricts PgBouncer's admin console
> for security — commands like KILL and SHUTDOWN are powerful
> footguns. Pool state observation happens via Prometheus metrics
> instead. The Pooler CR has an `enablePodMonitor` flag that exposes
> pgbouncer_exporter; combined with kube-prometheus-stack you get
> pool depth, active connections, and wait times in Grafana. That's
> the production-grade approach to pool observability, and it's
> what CNPG nudges you toward by design."
