# Runbook: SLO Breach Response

**Trigger:** Any burn-rate alert fires
(ThreeTier{Availability,Latency,BackupFreshness}Burn{Fast,Slow})

**Purpose:** Triage which SLO is burning, identify the cause, and route
to the correct remediation.

## Step 0: Acknowledge & Assess Severity

| Alert suffix        | Meaning                    | Response time |
| ------------------- | -------------------------- | ------------- |
| BurnFast (critical) | Budget exhausts in ~2 days | Immediate     |
| BurnSlow (warning)  | Budget exhausts in ~9 days | Within hours  |

Check which SLO fired from the alert's `slo` label: availability,
latency, or backup_freshness.

## Step 1: Confirm It's Real (Not A Blip)

Open the SLO Burn-Down dashboard in Grafana (Atlas — SLO Burn-Down).
Look at the relevant SLI panel:

* If the line is currently at 1 and only briefly dipped → likely a
  transient. Multi-window alerting should have filtered this, but
  verify. If recovered, monitor; alert will auto-resolve.
* If the line is at 0 or oscillating → real ongoing breach. Continue.

Cross-check in Prometheus:

```promql
sli:three_tier_db_available:ratio
sli:three_tier_db_latency:ratio
sli:three_tier_backup_fresh:ratio
```

## Step 2: Route By SLO

### If AVAILABILITY is burning

Likely causes: Postgres primary down, PgBouncer down, or no healthy
replica to promote.

```bash
# Check cluster status
kubectl get cluster pg -n three-tier-dev
kubectl get pods -n three-tier-dev -l cnpg.io/cluster=pg

# Check current primary
kubectl get cluster pg -n three-tier-dev -o jsonpath='{.status.currentPrimary}'; echo

# Check PgBouncer
kubectl get pods -n three-tier-dev -l cnpg.io/poolerName=pg-pooler-rw
```

* If primary is down and a replica is healthy → CNPG should auto-failover.
  If it hasn't, follow **docs/runbooks/postgres-failover.md**.
* If PgBouncer pods are down → check pooler deployment, restart if needed.
* If all Postgres pods are down → this is a major incident; check node
  health, memory pressure, and recent changes.

### If LATENCY is burning

Likely causes: connection pool saturation, slow queries, Postgres
under load.

```bash
# PgBouncer pool stats — are clients waiting?
# Query in Prometheus:
#   cnpg_pgbouncer_pools_cl_waiting
#   cnpg_pgbouncer_pools_maxwait_us
```

> Note: PgBouncer's admin console (`SHOW POOLS`) is not directly
> accessible in the CNPG pooler — `auth_type = hba` locks down
> connections by design. Use the Prometheus pool metrics above
> instead; they expose the same pool state without needing pod
> access. (See
> `docs/learning/week-3-database/cnpg-pgbouncer-admin-console.md`)

```bash
# Check active connections vs pool size
kubectl exec -n three-tier-dev pg-pooler-rw-<pod> -c pgbouncer -- \
  psql -p 5432 pgbouncer -c "SHOW POOLS;" 2>/dev/null
```

* If clients waiting > 0 consistently → pool exhausted. Consider
  increasing `default_pool_size` in `pooler.yaml`, or investigate why
  connections aren't being released (long transactions).
* If Postgres CPU/memory high → check for slow queries via
  `pg_stat_statements`; a runaway query may need termination.

### If BACKUP FRESHNESS is burning

Likely causes: ScheduledBackup not firing, WAL archiving broken, MinIO
unreachable.

```bash
# Check backups
kubectl get scheduledbackup -n three-tier-dev
kubectl get backup -n three-tier-dev

# Check continuous archiving condition
kubectl get cluster pg -n three-tier-dev \
  -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")]}'; echo

# Check MinIO is up
kubectl get pods -n three-tier-dev -l app=minio
```

* If ScheduledBackup hasn't fired → check the schedule and operator logs.
  Trigger a manual backup to restore freshness:

```bash
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: manual-recovery-$(date +%Y%m%d-%H%M%S)
  namespace: three-tier-dev
spec:
  cluster:
    name: pg
EOF
```

* If ContinuousArchiving is False → WAL archiving broken. Check MinIO
  connectivity and the `barmanObjectStore` config. This threatens RPO —
  treat as high priority. See
  **docs/runbooks/postgres-pitr-recovery.md**
  for the recovery context.
* If MinIO is down → restart/recover MinIO; WAL archiving resumes once
  the object store is reachable.

## Step 3: Confirm Recovery

After remediation, watch the SLI return to 1:

```bash
# Watch the relevant SLI recover in Prometheus, or watch the
# SLO Burn-Down dashboard. The burn-rate alert auto-resolves once
# the error rate drops below threshold across both windows.
```

## Step 4: Post-Incident

For any BurnFast (critical) event:

* Record what happened in `docs/incidents/` (use the template).
* Note budget consumed: a sustained fast burn can spend significant
  monthly error budget. Track whether the SLO is still being met for
  the month.
* If the same alert fires repeatedly, the underlying cause needs a
  permanent fix, not just remediation.

## Notes On Error Budget Policy

When a month's error budget is exhausted for an SLO:

* Freeze risky changes to that service until budget recovers.
* Prioritize reliability work over features.

This is the error-budget policy — the alert is the early warning that
budget is burning faster than acceptable.

