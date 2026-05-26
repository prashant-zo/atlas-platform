# Runbook: Postgres Primary Failover

**Audience:** On-call engineer
**Severity context:** Use this when the Postgres primary is unhealthy or unreachable. Symptoms include backend errors mentioning database connection failures, missing writes, or alerts on `pg_is_in_recovery` flapping.
**Last verified:** 2026-05-26 against CNPG 1.24

## When To Use This Runbook

| Symptom | Use this runbook? |
|---|---|
| Backend writes failing with "connection refused" or "primary unavailable" | YES |
| `kubectl get cluster pg` shows STATUS not "Cluster in healthy state" | YES |
| Specific Postgres pod restarted unexpectedly | YES — verify failover handled it |
| Need to retire/replace the primary intentionally | YES — see Path B (planned switchover) |
| Data is wrong / missing / corrupted | NO — see [PITR runbook](./postgres-pitr-recovery.md) |
| All 3 pods are down | This is not failover — see PITR runbook for full recovery |

## The First 30 Seconds: Don't Panic

CNPG handles unplanned primary failure **automatically**. The expected sequence:

1. Primary pod becomes unreachable (crash, network, eviction)
2. CNPG detects within ~10 seconds via failed health checks
3. CNPG selects the most-up-to-date standby
4. Standby promoted to primary; replication slots reconfigured
5. The `pg-rw` Service endpoint flips to the new primary
6. Writes flow again

**Total expected outage: 10-30 seconds.**

If your alert just fired and you're opening this runbook, the failover is **probably already in progress**. Wait 30 seconds, then verify recovery before taking any action.

## Step 1: Set Context

\`\`\`bash
export NAMESPACE=three-tier-dev          # or three-tier-staging / three-tier-prod
export CLUSTER=pg

# Confirm the cluster exists and grab its current state
kubectl get cluster $CLUSTER -n $NAMESPACE
\`\`\`

What to look for in the STATUS column:

| STATUS                              | Means                                          | Action                              |
|-------------------------------------|------------------------------------------------|-------------------------------------|
| Cluster in healthy state            | Everything is fine                             | Stop here. False alarm.             |
| Failing over                        | Failover in progress, automatic                | Wait, monitor (Step 2)              |
| Setting up primary                  | New primary being promoted, automatic          | Wait, monitor (Step 2)              |
| Waiting for primary to be available | All instances down, no quorum                  | Go to Step 4                        |
| Standby instance is healthy         | Standby fine, primary status unclear           | Go to Step 3                        |
| Error states (varies)               | Check the conditions block (Step 3)            | Go to Step 3                        |

## Step 2: Watch The Failover Complete

If the cluster is in `Failing over` or `Setting up primary`:

\`\`\`bash
watch -n 2 'kubectl get cluster,pods -n '"$NAMESPACE"' | grep -E "'"$CLUSTER"'|^NAME"'
\`\`\`

Within 30 seconds, you should see:
- One pod transition from "down" or "Pending" to "Running"
- The cluster STATUS reach "Cluster in healthy state"
- The "PRIMARY" column show a new pod name (or the same one restarted)

Confirm the new primary is writable:

\`\`\`bash
NEW_PRIMARY=$(kubectl get cluster $CLUSTER -n $NAMESPACE -o jsonpath='{.status.currentPrimary}')
echo "New primary: $NEW_PRIMARY"

kubectl exec $NEW_PRIMARY -n $NAMESPACE -c postgres -- \
  psql -U postgres -c "SELECT pg_is_in_recovery(), inet_server_addr(), now();"

# pg_is_in_recovery() should return 'f' (false — this is the primary)
\`\`\`

If you see `f` and a fresh `now()` timestamp — failover is complete. Skip to **Step 5: Verify Application Recovery**.

## Step 3: Diagnose If Automatic Failover Didn't Happen

If the cluster STATUS hasn't reached healthy after 60 seconds, something is blocking auto-failover.

\`\`\`bash
# Look at conditions on the Cluster — CNPG reports issues here
kubectl describe cluster $CLUSTER -n $NAMESPACE | sed -n '/Conditions:/,/Events:/p'

# Recent events tell you what CNPG tried and what failed
kubectl get events -n $NAMESPACE --sort-by='.lastTimestamp' | tail -20

# Check the operator's own logs
kubectl logs -n cnpg-system deployment/cnpg-cloudnative-pg --tail=50 | grep -iE "$CLUSTER|error|failover|promot"
\`\`\`

Common reasons auto-failover stalls:

### Reason A — No healthy standby available

Cluster condition shows `Cluster cannot be promoted: no eligible target`.

Cause: all standbys are also unhealthy. Likely a cluster-wide issue (storage, network).

\`\`\`bash
# Check pod status for all instances
kubectl get pods -n $NAMESPACE -l cnpg.io/cluster=$CLUSTER

# If standbys are in CrashLoopBackOff:
kubectl describe pod <pod-name> -n $NAMESPACE | tail -30
kubectl logs <pod-name> -n $NAMESPACE -c postgres --tail=50
\`\`\`

→ If standbys are failing on PVC issues, see Step 4 (full recovery path).

### Reason B — Replication lag too high

Cluster condition shows `Cluster has only stale replicas`.

Cause: standbys are lagging far enough that CNPG won't promote them to avoid data loss.

\`\`\`bash
# Check replication lag (must run against a still-functioning instance)
ANY_RUNNING=$(kubectl get pod -n $NAMESPACE -l cnpg.io/cluster=$CLUSTER -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' | awk '{print $1}')

kubectl exec $ANY_RUNNING -n $NAMESPACE -c postgres -- \
  psql -U postgres -c "SELECT client_addr, state, sync_state, replay_lag FROM pg_stat_replication;"
\`\`\`

Decision: accept data loss to restore writes, OR wait for replication to catch up?

- For dev/staging: usually accept data loss, force promote (see "Manual promotion" below).
- For prod: escalate to senior on-call; the answer depends on the business cost of data loss vs. write downtime.

### Reason C — All instances stuck Pending

Cluster condition shows pods stuck at `Pending` or `ContainerCreating`.

Cause: typically a node-level issue (storage class can't provision, no scheduling room, image pull issue).

\`\`\`bash
kubectl describe pod <pod-name> -n $NAMESPACE | grep -A5 "Events:"
\`\`\`

→ This is no longer a failover problem — it's an infrastructure problem. Escalate or restore the node-level capability before continuing.

## Step 4: Last Resort — Manual Promotion

**Only use this if Step 3 confirmed automatic failover is blocked and you've accepted whatever tradeoffs apply.**

\`\`\`bash
# Identify the standby with the LEAST replication lag (= least data loss)
# Run from any healthy instance
HEALTHY=$(kubectl get pod -n $NAMESPACE -l cnpg.io/cluster=$CLUSTER -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' | awk '{print $1}')

kubectl exec $HEALTHY -n $NAMESPACE -c postgres -- \
  psql -U postgres -c "SELECT pod_name, replay_lsn, write_lag FROM pg_stat_replication ORDER BY replay_lsn DESC;"

# Pick the one with the most recent replay_lsn (or shortest write_lag).
# Force promote it via the CNPG plugin:
kubectl cnpg promote $CLUSTER -n $NAMESPACE <chosen-pod-name>
\`\`\`

If `kubectl cnpg` plugin is not installed, the alternative is to edit the Cluster status directly — but this is **dangerous** and should only be done with senior approval:

\`\`\`bash
# DANGER: only with explicit senior approval
kubectl patch cluster $CLUSTER -n $NAMESPACE --type=merge --subresource=status \
  -p '{"status":{"targetPrimary":"<chosen-pod-name>"}}'
\`\`\`

The CNPG operator will see the targetPrimary mismatch and promote.

## Step 5: Verify Application Recovery

Once the cluster reports healthy:

\`\`\`bash
# Confirm the cluster is healthy
kubectl get cluster $CLUSTER -n $NAMESPACE
# STATUS: Cluster in healthy state

# Confirm pg-rw Service points at the new primary
NEW_PRIMARY=$(kubectl get cluster $CLUSTER -n $NAMESPACE -o jsonpath='{.status.currentPrimary}')
kubectl get endpoints pg-rw -n $NAMESPACE
# The IP listed should match the new primary's pod IP
kubectl get pod $NEW_PRIMARY -n $NAMESPACE -o jsonpath='{.status.podIP}'

# Confirm PgBouncer pool is forwarding to the new primary
# (App connects via pg-pooler-rw, not pg-rw directly)
kubectl run -it --rm psql-check \
  --image=postgres:15-alpine \
  --restart=Never \
  -n $NAMESPACE \
  --env="PGPASSWORD=$(kubectl get secret pg-app -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d)" \
  --command -- psql -h pg-pooler-rw -U appuser -d appdb -c "
    SELECT pg_is_in_recovery() AS is_replica, inet_server_addr(), now();
  "

# is_replica = f → talking to a primary
# inet_server_addr() should match $NEW_PRIMARY pod IP
\`\`\`

If both checks pass: **failover is complete. Service restored.**

## Step 6: Verify Replication Resumed

The pod that was the primary before the failover (now restarted) should rejoin as a standby.

\`\`\`bash
# Wait a few minutes for the old primary to recover as standby
sleep 60

# All 3 pods should be Running
kubectl get pods -n $NAMESPACE -l cnpg.io/cluster=$CLUSTER

# Replication status should show 2 streaming standbys (or whatever the
# cluster size is minus 1 for the primary)
kubectl exec $NEW_PRIMARY -n $NAMESPACE -c postgres -- \
  psql -U postgres -c "SELECT client_addr, state, sync_state, replay_lag FROM pg_stat_replication;"
\`\`\`

Expected: 2 rows, both with `state = streaming` and small `replay_lag`.

If a standby is missing or stuck:

\`\`\`bash
# Check the standby pod's logs
kubectl logs <missing-standby-pod> -n $NAMESPACE -c postgres --tail=50
\`\`\`

Standby rebuilds from scratch (re-cloning from the new primary) if it's too far behind. Allow up to 5 minutes for this on small datasets.

## Step 7: Document The Incident

Open an incident postmortem under `docs/incidents/` (template at `docs/incidents/000-template.md`). At minimum capture:

- Timestamp of detection (alert fired, customer reported, etc.)
- Timestamp of full recovery (writes succeeding through PgBouncer)
- Cause of the primary failure (pod eviction? node failure? crashed process?)
- Whether automatic failover handled it (Step 2 path) or required manual intervention (Step 4 path)
- Replication lag at failover time (any data loss?)

This becomes the next INC-NNN. Your future on-call shifts will thank you.

## Time-To-Recover (TTR) Targets

| Scenario | Realistic TTR |
|---|---|
| Pod crashed, automatic failover | 10-30 seconds |
| Node lost, automatic failover after pod reschedule | 60-120 seconds |
| Replication lag blocks auto-promotion, manual promote | 2-5 minutes |
| All instances down, full recovery needed | See PITR runbook — minutes to hours |

## Why PgBouncer Matters Here

The backend doesn't connect directly to `pg-rw`. It connects to `pg-pooler-rw`, which is the PgBouncer pool's Service.

During failover:
- The `pg-rw` Service endpoint flips to the new primary (within seconds)
- PgBouncer detects its upstream connection died
- PgBouncer reconnects to the (new) primary via `pg-rw`
- Queued client requests flush to the new primary

Without PgBouncer, every backend connection has to detect the dead connection, retry, and reconnect — multiplying the perceived outage. PgBouncer absorbs the failover entirely from the application's perspective.

**If your alert shows the backend is throwing connection errors for longer than 30 seconds, suspect PgBouncer.** Check pooler health:

\`\`\`bash
kubectl get pods -n $NAMESPACE -l cnpg.io/poolerName=pg-pooler-rw
kubectl logs -n $NAMESPACE -l cnpg.io/poolerName=pg-pooler-rw --tail=50
\`\`\`

If the pooler pods are unhealthy, restart them:

\`\`\`bash
kubectl rollout restart deployment -n $NAMESPACE -l cnpg.io/poolerName=pg-pooler-rw
\`\`\`

## Known Failure Modes And Workarounds

### Failover happens but writes still fail through the pool

Likely cause: PgBouncer's connection pool has stale connections to the dead primary that haven't been reaped yet.

Workaround: bounce the pool. \`kubectl rollout restart\` on the pooler Deployment. Brief additional outage (~5 seconds) but forces fresh connections to the new primary.

### Old primary won't rejoin as standby

Likely cause: WAL divergence — the old primary had uncommitted transactions that aren't in the new primary's history.

CNPG handles this via pg_rewind automatically. If it fails after multiple retries:

\`\`\`bash
# Delete the old primary's PVC to force re-clone from scratch
kubectl delete pod <old-primary-pod> -n $NAMESPACE --grace-period=0
kubectl delete pvc <old-primary-pvc> -n $NAMESPACE
\`\`\`

CNPG will recreate the pod with a fresh PVC and clone from the new primary. Takes longer (~5 min for small databases) but always works.

### Cluster won't elect a new primary because PDB blocks eviction

The PodDisruptionBudget (auto-managed by CNPG) might block voluntary eviction during cluster operations.

Check:

\`\`\`bash
kubectl get pdb -n $NAMESPACE
\`\`\`

If a PDB blocked the failover, you'd see events mentioning "Cannot evict pod as it would violate the pod's disruption budget."

Workaround: temporarily delete the PDB, complete failover, recreate (CNPG auto-creates it on next reconcile).

## References

- CNPG failover documentation: https://cloudnative-pg.io/documentation/current/failover/
- CNPG promotion via kubectl plugin: https://cloudnative-pg.io/documentation/current/kubectl-plugin/#promote
- Related: [PITR recovery runbook](./postgres-pitr-recovery.md), [INC-001](../incidents/001-applicationset-finalizer-deadlock.md)
- Atlas's own failover test: [INC-002 (Task 3.10)](../incidents/) — once written
