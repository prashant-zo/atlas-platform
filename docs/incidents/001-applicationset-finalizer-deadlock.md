# INC-001: ApplicationSet Finalizer Deadlock On Directory Deletion

**Date:** 2026-05-22
**Author:** Prashant
**Status:** Resolved
**Severity:** P2 (orphan resources in cluster, no user impact)
**Duration:** ~45 minutes
**Components affected:** ArgoCD ApplicationSet, root App-of-Apps

## Summary

While validating the ApplicationSet's auto-discovery behavior, an Application got stuck in a delete loop after its source directory was removed from Git. The ArgoCD ApplicationSet controller called `delete` on the Application every 15 seconds for ~45 minutes, but the Application's finalizer could not complete pre-delete cleanup because the source path no longer existed in Git, creating a deadlock. The ConfigMap managed by the orphaned Application remained in the cluster. Resolved by manually clearing the finalizer and deleting the orphaned ConfigMap.

## Timeline

All times in IST.

- **18:53** — Created `gitops/platform/example-config/` containing a no-op ConfigMap to validate ApplicationSet auto-discovery
- **18:54** — Pushed to GitHub
- **18:55** — ApplicationSet generator detected the new directory and created `platform-example-config` Application. ConfigMap `atlas-example` appeared in `kube-system`. ✓
- **19:05** — Deleted `gitops/platform/example-config/` to validate the reverse flow
- **19:06** — Pushed deletion to GitHub. Expected: ApplicationSet removes the Application, finalizer prunes the ConfigMap
- **19:08** — `argocd app list` shows `platform-example-config` in `Unknown / ComparisonError` state. ConfigMap still present in cluster
- **19:18** — Status unchanged after 12 minutes. Investigated.
- **19:18** — `argocd app get platform-example-config` revealed: `ComparisonError: gitops/platform/example-config: app path does not exist`
- **19:20** — Inspected ApplicationSet controller logs: `Deleted application platform-example-config` log line appearing every 15 seconds in a loop
- **19:26** — Hypothesis formed: finalizer needs to load source to determine what to prune, but source doesn't exist, so finalizer is stuck
- **19:27** — Confirmed hypothesis: `kubectl get application platform-example-config -n argocd -o jsonpath='{.metadata.deletionTimestamp}'` returned a timestamp, proving the Application was in Terminating but stuck
- **19:28** — Applied fix: patched Application to clear finalizers, manually deleted the orphaned ConfigMap
- **19:30** — Verified clean state. Incident resolved.

## Root cause

The ApplicationSet controller and the Application's finalizer were in a deadlock.

The Application carried the `resources-finalizer.argocd.argoproj.io` finalizer (set in our ApplicationSet template). When the ApplicationSet's generator stopped generating this Application (because its source directory was removed from Git), the controller correctly issued a delete on the Application. However, before the Application can actually be deleted, Kubernetes runs each finalizer. The `resources-finalizer.argocd.argoproj.io` finalizer prunes the Application's managed resources from the cluster — but to know *what* to prune, ArgoCD must load and render the Application's source. The source path (`gitops/platform/example-config/`) no longer existed in Git, so the source load failed with a ComparisonError. The finalizer could not complete, the Application stayed in Terminating state, and the ApplicationSet controller kept issuing delete in a loop.

This is a known operational footgun when using ApplicationSets with `resources-finalizer.argocd.argoproj.io` enabled in the template: deleting a generator source before its child Application's resources are cleaned up creates an unrecoverable state without manual intervention.

## Detection

Self-noticed during validation testing. Specifically: after pushing the directory deletion, the engineer was watching `argocd app list` to verify the reverse-flow demonstration in Task 2.4. The expected state transition (Application removed, ConfigMap pruned) did not occur. The persistent `Unknown / ComparisonError` status against `platform-example-config` after 12+ minutes was the trigger to investigate.

In a production setting without active monitoring, this incident might have gone undetected for hours or days — there was no health alert, no user impact, and the orphaned ConfigMap was harmless. This argues for an alert on Applications in non-terminal `Unknown` state for more than 5 minutes (see Action Items).

## Resolution

```bash
# Step 1 — clear the finalizer so the Application can actually be deleted
kubectl patch application platform-example-config -n argocd \
  --type=merge \
  -p '{"metadata":{"finalizers":[]}}'

# Step 2 — verify the Application disappeared
kubectl get application platform-example-config -n argocd
# Error from server (NotFound) — confirmed

# Step 3 — manually delete the orphaned ConfigMap that the finalizer
# was unable to prune
kubectl delete configmap atlas-example -n kube-system

# Step 4 — verify clean state
argocd app list                  # only root-app-of-apps and platform-metrics-server
kubectl get cm atlas-example -n kube-system 2>&1  # NotFound — clean
```

## What went well

- **The diagnostic process was clean.** Hypothesis was formed from log analysis ("Deleted application" appearing in a loop), verified with a targeted kubectl query (`deletionTimestamp`), and fixed once confirmed.
- **The ApplicationSet logs were specific enough to be useful.** The "Deleted application" line repeating every 15 seconds was the unambiguous signal that something downstream of the controller's delete call was failing.
- **Self-heal and reconciliation worked as designed.** No part of ArgoCD silently swallowed an error — the ComparisonError condition was clearly visible on the Application throughout.

## What went wrong

- **The finalizer + ApplicationSet interaction is a known footgun, and our template included the finalizer without considering the deletion-order implications.** The `resources-finalizer.argocd.argoproj.io` finalizer protects against accidental orphan resources in steady state, but creates an irrecoverable deadlock if the source is removed before resources are cleaned up.
- **There was no runbook for this scenario.** A platform that captures known operational gotchas in runbooks would have shortened resolution time from ~45 minutes to ~5 minutes (the time to find and follow the runbook).
- **No alert fires on `Unknown / ComparisonError` Applications.** A production system needs to notify on this state — silent orphan resources are easy to accumulate.

## Action items

- [ ] **Add runbook for "Application stuck in Terminating"** with the exact commands to diagnose and fix — Prashant, by end of Week 4
- [ ] **Document the "delete order matters" pattern in the platform README** (delete via UI / sync policy first, then remove Git source) — Prashant, by end of Week 2
- [ ] **Evaluate removing `resources-finalizer.argocd.argoproj.io` from the ApplicationSet template** for non-stateful workloads where rapid iteration outweighs orphan-prevention — Prashant, decision in Week 3
- [ ] **Add alert in Week 4 observability stack** when any Application stays in `Unknown` or `OutOfSync` state for >5 minutes — Prashant, Week 4

## Lessons learned

GitOps finalizers protect you from one class of problem (accidental orphan resources) and create another (deletion-order deadlocks). Default to enabling them, but write a runbook for the inevitable stuck-state recovery, and consider monitoring for stale `Unknown` Application status. The general principle: **every safety mechanism in a distributed system has a failure mode of its own** — your job as a platform engineer is to design for the failure modes, not just the happy path.
