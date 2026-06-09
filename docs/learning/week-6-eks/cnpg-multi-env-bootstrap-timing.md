# CNPG Multi-Env Bootstrap Takes ~10-15min On A Warm Cluster

**Date:** 2026-06-09
**Context:** Day 1 of multi-env EKS sprint, enabling staging alongside an
already-running dev
**Status:** Operational gotcha worth knowing before adding a second env

---

## The Symptom

After committing the staging overlay enable (workloads-non-prod
ApplicationSet adding `- env: staging`), ArgoCD created the
`three-tier-staging` Application within ~30 seconds. But for the
next ~10-12 minutes the Application reported `Degraded` and the
backend pods stayed in `Init:0/1` status.

The diagnostic snapshot:

    backend-644d8cdc67-vdhpw   0/1   Init:0/1    11m
    backend-644d8cdc67-zkmlh   0/1   Init:0/1    11m
    frontend-...               1/1   Running     11m
    minio-0                    1/1   Running     11m
    
    Rollout status:  ✖ Degraded
    Message: ProgressDeadlineExceeded: ReplicaSet has timed out progressing.

CNPG Cluster `pg` was NotFound when checked at ~8min in:

    kubectl get cluster pg -n three-tier-staging
    Error from server (NotFound): clusters.postgresql.cnpg.io "pg" not found

This looked alarming. It was not.

---

## What Was Actually Happening

The CNPG Cluster CR WAS submitted to the API server during ArgoCD's
initial sync. ArgoCD's resource list showed it as "Synced" — meaning
the CR object was created in the API server. But the actual Postgres
cluster (3 pods, EBS volumes, base backup, replicas joining) takes
significant time to materialize, especially when a previous env in
the same cluster has already used the operator.

The CNPG operator logs reveal the bootstrap sequence on the warm
cluster:

| Phase                                          | Time elapsed |
|------------------------------------------------|--------------|
| Cluster CR accepted by webhook                  | T+0          |
| pg-1 pod scheduled, PVC bound                   | ~T+30s       |
| pg-1 initdb running                             | ~T+1m        |
| pg-1 marked primary, readiness probe waiting    | ~T+2m        |
| pg-2-join Job created (waiting for primary)     | ~T+2m        |
| pg-2-join Job completed, pg-2 PVC ready         | ~T+3m        |
| pg-2 pod created, replica streaming begins      | ~T+3.5m      |
| pg-2 marked replica                             | ~T+4m        |
| pg-3-join Job created                           | ~T+4m        |
| pg-3 joined as replica                          | ~T+5m        |
| First scheduled backup runs                     | ~T+5m        |
| Cluster reports "Cluster is healthy"            | ~T+6m        |
| backend pods' initContainer (nc -z pg-pooler-rw)|              |
|   finally succeeds, init completes              | ~T+7m        |
| backend pods Ready                              | ~T+8m        |
| Rollout progresses, ApplicationSet recomputes   | ~T+10m       |
| ArgoCD reports Synced + Healthy                 | ~T+12m       |

Total: ~10-15 minutes from `git push` to all-green on a warm cluster.

---

## Why It's Slower On A Warm Cluster Than On Fresh Bootstrap

Counterintuitively, adding a second env to an existing cluster is
SLOWER than the original fresh bootstrap. Reasons:

1. **Serial join Jobs.** CNPG creates pg-2 and pg-3 via `*-join` Jobs
   that run sequentially. Each job waits for the previous PG instance
   to be ready before starting. On a fresh bootstrap, ArgoCD applies
   everything at once and the Jobs queue from start. On a warm cluster,
   the same serialization applies but it's more visible because dev is
   already running and you're watching staging come up.

2. **EBS volume provisioning.** Each Postgres instance needs its own
   PVC via gp3 StorageClass. AWS EBS provisioning takes ~30-60s per
   volume. Three pods = three sequential volumes.

3. **Init container blocking.** Backend pods have an initContainer
   that does `nc -z pg-pooler-rw 5432`. Until the Pooler Service has
   endpoints (which only happens once pg-1 is fully Ready AND
   pg-pooler-rw Pooler resource has its deployment ready), the init
   container loop continues. Backend reports `Init:0/1` the whole time.

4. **Rollout's ProgressDeadlineExceeded.** Default Argo Rollouts
   `progressDeadlineSeconds` is 600s (10 min). If pods don't become
   Ready in 10 min, the Rollout reports Degraded — even though the
   underlying problem is just slow upstream dependency, not a bug.
   This makes the Application Health flip to Degraded for several
   minutes mid-bootstrap.

---

## What Argo Rollouts' Degraded Status Means In This Context

On a fresh bootstrap (everything starting at once), Argo Rollouts'
10-minute deadline is usually long enough to wait for the Postgres
bootstrap. On a warm cluster (second env), the Postgres bootstrap
on its own can take longer because of operator-side serialization,
so the Rollout flips Degraded BEFORE pods are even close to Ready.

This Degraded status during bootstrap is **expected and recoverable**.
Once the upstream PG cluster is healthy, Argo Rollouts re-reconciles
and the Rollout transitions:

    Degraded → Progressing → Healthy

This took us from concerned ("is the Cluster CR even there?") to
calm ("just wait") in the diagnostic process.

---

## Diagnostic Checks That Confirm It's Bootstrap, Not Failure

If a workload Application is Degraded for >5 minutes after enabling
a new env, run these to distinguish "still bootstrapping" from "real
failure":

1. **Is the Cluster CR created?**

       kubectl get cluster -n <env-namespace>

   If present, the manifest applied successfully. Bootstrap is in
   progress. Don't intervene.

2. **What does the CNPG operator say?**

       kubectl logs -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg --tail=50

   Look for: `Cluster is healthy`, `Creating new Pod`, `Creating new
   Job`. These indicate active progress. Look for: errors,
   `connection refused`, repeated reconcile loops — those indicate
   real failure.

3. **Are PG pods scheduled?**

       kubectl get pods -n <env-namespace> -l cnpg.io/cluster=pg

   You should see pg-1, pg-2, pg-3 in some combination of states
   (Running, ContainerCreating, Init). If 0 pods, the cluster spec
   failed somehow.

4. **Are PVCs binding?**

       kubectl get pvc -n <env-namespace>

   gp3 storage class should be Pending → Bound within 1 min per PVC.

5. **Are Init containers waiting?**

       kubectl get pods -n <env-namespace> -l app=backend
       
       backend-...   0/1   Init:0/1   Xm

   `Init:0/1` for >5 min usually means the postgres dependency isn't
   ready yet. Check pg-pooler-rw Service:

       kubectl get svc pg-pooler-rw -n <env-namespace>
       kubectl get endpoints pg-pooler-rw -n <env-namespace>

   No endpoints = pooler deployment isn't Ready yet = postgres
   isn't fully up yet.

---

## When To Actually Worry

After ~15 minutes:

- Cluster CR still NotFound → the manifest didn't apply. Check ArgoCD
  sync result and CNPG admission webhook logs.
- pg-1 in CrashLoopBackOff → bad image, bad spec, or admission webhook
  issue. Describe the pod.
- PVCs stuck Pending → EBS CSI issue or StorageClass misconfiguration.
  Check storageclass list and CSI driver pods.
- pg-pooler-rw Service has no endpoints AND pg-1 is Running → Pooler
  resource itself failed. Check `kubectl get pooler` and its events.

After ~20 minutes with no progression in any of the above, escalate.
But 10-15 min of "looks Degraded but actually progressing" is
normal for adding a second env to a warm CNPG cluster.

---

## Implication For The Sync-Wave Strategy

This is also why staggered sync waves matter beyond just the CNPG
webhook race. Even with the webhook trusted at wave -1, adding
multiple envs at the SAME sync wave would mean parallel cluster
bootstraps competing for the operator's reconciliation budget.

Staggered waves (dev=1, staging=2, prod=3) make CNPG bootstrap
sequential by env, predictable, and easier to debug. Each env's PG
cluster has the operator's full attention during its bootstrap window.

---

## Action Items

- [x] Document this in the learning corpus (this file)
- [ ] Consider bumping Argo Rollouts `progressDeadlineSeconds` in
      the base Rollout from default 600s to 1200s for warm-cluster
      bootstraps. Lower priority since the system recovers correctly
      on its own.
- [ ] Update `bootstrap-fresh-cluster.md` runbook to note that adding
      additional envs takes 10-15 min EACH after the initial bootstrap.

---

## Interview Talking Point

> "After enabling staging in the ApplicationSet, I watched the new
> Application report Degraded for about 10 minutes. The instinct was
> to think it had failed — Argo Rollouts even flagged
> ProgressDeadlineExceeded because the backend pods couldn't progress
> beyond Init for >10 min. But the actual cause was that the CNPG
> operator serializes replica joins: pg-1 has to be primary before
> pg-2-join runs, then pg-3-join. Each join Job takes ~1-2 min. With
> EBS volume provisioning on top, the staging Postgres cluster took
> ~8 min to be Healthy, then backend pods could start. The system
> recovered itself the moment Postgres was up. The lesson is that
> 'Degraded for 10 min during bootstrap' is structurally different
> from 'Degraded indefinitely after deploy' — you have to read the
> CNPG operator logs and check if it's still doing work before
> intervening."

---

## Related

- `docs/learning/week-6-eks/cnpg-webhook-tls-race.md` — Why sync waves
  are needed in the FIRST place (separate problem from this one)
- `docs/runbooks/bootstrap-fresh-cluster.md` — Reference for fresh
  bootstrap timing
- `gitops/apps/workloads-non-prod.yaml` — Staggered sync waves config
- `gitops/workloads/three-tier-app/base/backend-rollout.yaml` —
  Backend Rollout (the one that goes Degraded during PG bootstrap)
- `gitops/workloads/three-tier-app/database/cluster.yaml` — CNPG
  Cluster CR
