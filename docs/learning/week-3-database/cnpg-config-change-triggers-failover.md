# CNPG Config Change Triggers Controlled Failover

**Date encountered:** 2026-05-24
**Component:** Postgres Cluster CR backup configuration

## Symptom (Expected Behavior)

After updating the Cluster CR with `backup:` configuration and syncing
via ArgoCD, all 3 Postgres pods restarted in sequence — standbys first,
then the primary via switchover.

## Why This Is Expected

CNPG enforces a property: **all instances run identical Postgres
configuration**. The backup config gets injected into postgresql.conf
and the WAL archive command. To apply that change safely:

1. CNPG marks the cluster as `Upgrading`
2. Standbys restart one at a time. Each one applies the new config,
   rejoins replication.
3. With all standbys on the new config, CNPG promotes one to become
   primary
4. The old primary restarts as a standby with the new config

The result: rolling config rollout with zero data loss and minimal
write downtime (a few seconds during the switchover).

## What I'd Do Differently In Production

For high-write workloads, the switchover step is brief but not free —
in-flight transactions to the primary fail with "primary went away"
errors. The application needs retry logic for write failures. Real
applications doing this rely on the connection pooler (PgBouncer) to
mask the failover from the app entirely.

PgBouncer is Task 3.6. After installing PgBouncer, the app talks to
PgBouncer instead of Postgres directly, and config-change failovers
become invisible to the app.

## Interview Talking Point

> "When I configured WAL archiving on my Postgres cluster managed by
> CNPG, applying the config triggered a rolling restart across all 3
> instances. CNPG handles this safely: standbys restart first, then
> promotes a clean standby to be the new primary so the old primary
> can restart with the new config without leaving the cluster
> primary-less. This is the operator pattern doing real work — a
> human DBA would have to script that exact same sequence by hand.
>
> The catch: during the switchover, in-flight writes to the old
> primary fail. Production deployments mask this by inserting a
> connection pooler like PgBouncer between the app and Postgres.
> PgBouncer holds connections open across switchovers, so the app
> sees a brief blip instead of an error."
