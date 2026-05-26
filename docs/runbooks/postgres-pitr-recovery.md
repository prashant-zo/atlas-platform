# Runbook: Postgres Point-In-Time Recovery (PITR)

**Audience:** On-call engineer
**Severity context:** Use this when data loss has occurred and you need to recover the Postgres cluster (or a copy of it) to a specific moment in the past.
**Last verified:** 2026-05-26 against CNPG 1.24

## When To Use This Runbook

| Symptom | Use this runbook? |
|---|---|
| Bad migration corrupted data | YES |
| Accidental `DELETE` or `DROP TABLE` | YES |
| Cluster fully deleted, need to rebuild | YES |
| One Postgres pod crashed (others healthy) | NO — see [failover runbook](./postgres-failover.md) |
| All 3 pods crashed but data PVCs intact | TRY POD RESTART FIRST — `kubectl rollout restart` |
| Data corruption in last 5 minutes | YES, but RPO=5min — accept some data loss |

**This procedure recovers to a NEW cluster name (`pg-recovery`).** It does NOT modify the current `pg` cluster. The current cluster stays untouched. After verifying the recovery is correct, you decide whether to:
- Cut over the app to the new cluster
- Copy specific data from new → old via dump/restore
- Delete the recovery cluster (false alarm)

## Prerequisites Checklist

Before starting, confirm:

- [ ] You have `kubectl` access to the cluster
- [ ] You have read access to the MinIO bucket `pg-backups` (or its EKS equivalent)
- [ ] You know the **target recovery time** (e.g., "2026-05-26 14:30:00 UTC" — the moment just BEFORE the destructive event)
- [ ] You know the source cluster name (likely `pg`)
- [ ] You know the namespace (e.g., `three-tier-dev`)

Find the target recovery time if you don't have one yet:

\`\`\`bash
# Inspect when the bad event happened — for example, check app logs
kubectl logs deployment/backend -n <namespace> --since=24h | grep -i "DELETE\|migration\|drop"

# OR check Postgres logs on the primary
PRIMARY=$(kubectl get cluster pg -n <namespace> -o jsonpath='{.status.currentPrimary}')
kubectl logs $PRIMARY -n <namespace> -c postgres | grep -E "DELETE|DROP|ALTER" | tail -30
\`\`\`

Pick a target time at least 1 minute BEFORE the destructive event. WAL is replayed up to but not including this timestamp.

## Step 1: Confirm The Backup Chain Is Intact

The recovery requires (a) a base backup taken before your target time, and (b) all WAL segments between that backup and your target time. Verify both exist.

\`\`\`bash
# Set your context
export NAMESPACE=three-tier-dev
export SOURCE_CLUSTER=pg
export TARGET_TIME="2026-05-26 14:30:00"        # YOUR target time here

# List available backups, newest first
kubectl get backup -n $NAMESPACE \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,STARTED:.status.startedAt,STOPPED:.status.stoppedAt
\`\`\`

You should see one or more `completed` backups. Pick the most recent one that completed BEFORE your target time. This is your **base backup**.

\`\`\`bash
# Verify the backup files are in MinIO
kubectl run -i --rm --tty mc-check \
  --image=quay.io/minio/mc:RELEASE.2024-11-21T17-21-54Z \
  --restart=Never \
  -n $NAMESPACE \
  --command -- sh -c '
    mc alias set local http://minio:9000 minioadmin minioadmin
    mc ls --recursive local/pg-backups/pg/ | grep -E "base/|wals/" | head -20
  '
\`\`\`

You should see:
- Entries under `pg/base/<backup-id>/` (the base backup itself)
- Entries under `pg/wals/...` (the WAL archive)

**Stop here and escalate if:**
- No `completed` backup exists before your target time
- The MinIO bucket is missing or empty
- WAL files are not present in the time range you need

## Step 2: Create The Recovery Cluster Manifest

Create a NEW Cluster CR that bootstraps from the existing backup. This is a separate cluster — does NOT touch the source.

\`\`\`bash
cat <<EOF > /tmp/pg-recovery.yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg-recovery
  namespace: $NAMESPACE
spec:
  instances: 1                              # smaller — we just need to verify data
  imageName: ghcr.io/cloudnative-pg/postgresql:15.6

  storage:
    storageClass: standard
    size: 2Gi

  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 512Mi

  bootstrap:
    recovery:
      source: $SOURCE_CLUSTER-backup
      recoveryTarget:
        targetTime: "$TARGET_TIME"

  # Reference the same backup configuration so we can read from MinIO
  externalClusters:
    - name: $SOURCE_CLUSTER-backup
      barmanObjectStore:
        destinationPath: "s3://pg-backups/"
        endpointURL: "http://minio:9000"
        s3Credentials:
          accessKeyId:
            name: minio-creds
            key: AWS_ACCESS_KEY_ID
          secretAccessKey:
            name: minio-creds
            key: AWS_SECRET_ACCESS_KEY
        wal:
          compression: gzip
        data:
          compression: gzip
        # The serverName MUST match what the original cluster used.
        # CNPG defaults this to the cluster name. So pg-recovery would
        # look in pg-recovery/ — we override to read from pg/.
        serverName: pg

  # No backup config on the recovery cluster — we don't want it shipping
  # its own WAL to the same bucket. Add backup config later if you decide
  # to keep this cluster.
EOF

cat /tmp/pg-recovery.yaml | head -30
\`\`\`

## Step 3: Apply The Recovery Manifest

\`\`\`bash
kubectl apply -f /tmp/pg-recovery.yaml
\`\`\`

Expected output:
\`\`\`
cluster.postgresql.cnpg.io/pg-recovery created
\`\`\`

## Step 4: Monitor The Recovery

This is the longest step. CNPG will:
1. Create a PVC for the recovery pod
2. Spin up an init container that downloads the base backup from MinIO
3. Extract the base backup onto the PVC
4. Replay WAL up to the `targetTime`
5. Promote the recovered instance

\`\`\`bash
# Watch the recovery in real time
watch -n 3 'kubectl get cluster,pod -n '"$NAMESPACE"' | grep -E "pg-recovery|^NAME"'
\`\`\`

Phases you'll see, in order:

| Cluster STATUS                           | Pod STATUS         | Means                                      |
|------------------------------------------|--------------------|--------------------------------------------|
| Setting up primary                       | Init:0/1           | Downloading base backup from MinIO         |
| Setting up primary                       | Init:1/2           | Extracting base backup to PVC              |
| Setting up primary                       | PodInitializing    | Replaying WAL up to target time            |
| Cluster in healthy state                 | 1/1 Running        | Recovery complete                          |

**Time estimate:** 1-5 minutes for a ~1GB database. Larger databases scale roughly linearly with data size + WAL volume to replay.

**Stop here and escalate if:**
- Pod status shows `Init:CrashLoopBackOff` for more than 5 minutes
- Cluster status shows error referencing barman-cloud or S3 access
- Recovery doesn't complete within ~15 minutes for a database under 10GB

Common error pattern:

\`\`\`
Error: Cluster pg-recovery cannot recover backup: cannot download base backup
\`\`\`

This means the `serverName` in the externalClusters block doesn't match where backups are actually stored. Re-check the manifest's `serverName: pg` matches your source cluster name.

## Step 5: Verify The Recovery

Once the recovery cluster is `Cluster in healthy state`, connect to it and verify the data is what you expected.

\`\`\`bash
# Get the recovery cluster's credentials
RECOVERY_PASSWORD=$(kubectl get secret pg-recovery-app -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d)

# Open a psql session against the recovery cluster
kubectl run -it --rm psql-recovery \
  --image=postgres:15-alpine \
  --restart=Never \
  -n $NAMESPACE \
  --env="PGPASSWORD=$RECOVERY_PASSWORD" \
  --command -- psql -h pg-recovery-rw -U appuser -d appdb
\`\`\`

In the psql session, run verification queries. **Examples — adapt to your data model:**

\`\`\`sql
-- Verify the deleted/corrupted records are present
SELECT count(*) FROM orders WHERE customer_id = 'X';

-- Verify the table structure pre-dates a bad migration
SELECT column_name FROM information_schema.columns
  WHERE table_name = 'users' ORDER BY ordinal_position;

-- Confirm the recovery timestamp
SELECT now(), pg_last_xact_replay_timestamp();
\`\`\`

The `pg_last_xact_replay_timestamp()` value should be at or just before your target time. That's proof the recovery landed at the right point.

`\q` to exit psql.

## Step 6: Decide What To Do Next

You now have a recovery cluster with pre-incident data. Choose one path:

### Path A — Promote The Recovery Cluster To Be The New Primary

Use when: the source cluster is unrecoverable, OR cutover to clean state is the right answer.

1. Stop writes to the source cluster (scale backend Deployment to 0)
2. Backup any critical data accumulated since the recovery time
3. Update the backend ConfigMap's `DB_HOST` to point at `pg-recovery-rw`
4. Scale backend back up
5. Add backup configuration to the recovery cluster (it has none yet)
6. Rename/delete the old source cluster
7. Rename the recovery cluster from `pg-recovery` to `pg`

### Path B — Selective Data Restore From Recovery Cluster

Use when: only specific data needs recovery, the rest of the source cluster is fine.

1. From the recovery cluster, dump the specific tables/rows you need:
   \`\`\`bash
   kubectl exec pg-recovery-1 -n $NAMESPACE -c postgres -- \
     pg_dump -U appuser -d appdb -t orders -a > /tmp/orders-restore.sql
   \`\`\`
2. Apply the dump to the source cluster:
   \`\`\`bash
   kubectl cp /tmp/orders-restore.sql $NAMESPACE/pg-1:/tmp/restore.sql
   kubectl exec pg-1 -n $NAMESPACE -c postgres -- \
     psql -U appuser -d appdb -f /tmp/restore.sql
   \`\`\`
3. After verification, delete the recovery cluster (Step 7 below)

### Path C — False Alarm, Discard The Recovery Cluster

Use when: the incident was not actually a data loss event, or the recovery confirmed the source is fine.

Proceed to Step 7.

## Step 7: Clean Up The Recovery Cluster

When you're done with the recovery cluster, delete it cleanly. Its PVC is independent — it won't affect the source.

\`\`\`bash
# Delete the recovery cluster CR
kubectl delete cluster pg-recovery -n $NAMESPACE

# Delete the associated PVC (CNPG doesn't auto-delete PVCs)
kubectl delete pvc -n $NAMESPACE -l cnpg.io/cluster=pg-recovery

# Verify clean state
kubectl get cluster -n $NAMESPACE
# Should show only the original cluster (pg)
\`\`\`

## Step 8: Document The Incident

Open a new incident postmortem under `docs/incidents/` (template at `docs/incidents/000-template.md`). Capture:

- What the destructive event was
- The target recovery time chosen
- Time-to-restore (from "discovered loss" → "verified recovery")
- Whether Path A / B / C was taken
- Lessons for next time (better alerts, faster detection, etc.)

## Time-To-Restore (TTR) Targets

| Database size | Realistic TTR |
|---|---|
| < 1 GB       | 5 minutes     |
| 1-10 GB      | 15 minutes    |
| 10-100 GB    | 1-2 hours     |
| > 100 GB     | Hours — consider parallel recovery via multiple Cluster CRs reading different time ranges |

## Common Failure Modes

### "backup not found"

Likely cause: `serverName` in externalClusters doesn't match the source. Source clusters write to `<serverName>/` in the bucket. The recovery cluster must read from the same prefix.

Fix: edit the manifest, set `serverName: <source-cluster-name>`, re-apply.

### "WAL not found" during replay

Likely cause: WAL was deleted by the retention policy before the recovery could read it. The default Atlas retention is 7d; if your target time is older than that, the WAL is gone.

Fix: pick a target time within retention, or restore from the base backup only without WAL replay (acceptable RPO depending on incident).

### Recovery cluster stuck in `Init` for >15 minutes

Likely cause: pod can't reach MinIO. Check network policy, DNS, service health.

\`\`\`bash
RECOVERY_POD=$(kubectl get pod -n $NAMESPACE -l cnpg.io/cluster=pg-recovery -o jsonpath='{.items[0].metadata.name}')
kubectl logs $RECOVERY_POD -n $NAMESPACE -c bootstrap-controller | tail -30
\`\`\`

The bootstrap-controller logs show exactly where the recovery is hung.

### Recovery cluster reaches healthy state but data is wrong

Likely cause: `targetTime` was in the wrong format, or the WAL didn't extend to your target.

Re-check: `targetTime: "YYYY-MM-DD HH:MM:SS"` format, UTC, with quotes. Delete the recovery cluster, fix the manifest, re-apply.

## References

- CloudNativePG recovery docs: https://cloudnative-pg.io/documentation/current/recovery/
- CNPG externalClusters: https://cloudnative-pg.io/documentation/current/bootstrap/#bootstrap-from-an-external-cluster
- Postgres recovery target options: https://www.postgresql.org/docs/15/recovery-target-settings.html
- Related: [Failover runbook](./postgres-failover.md), [INC-001](../incidents/001-applicationset-finalizer-deadlock.md)
