# Runbook: ArgoCD Application Stuck In Terminating State

## When to use this runbook

Use this runbook when an ArgoCD Application:

- Shows `Status: Unknown` and `Condition: ComparisonError`
- The error message includes `app path does not exist` or similar
- Cannot be deleted via `argocd app delete` or `kubectl delete application`
- Or the delete command returns success but the Application reappears

This typically happens when an Application's Git source was deleted before its managed resources were pruned.

## Quick fix

```bash
# 1. Identify the stuck Application
APP_NAME=<application-name>
NAMESPACE=argocd

# 2. Confirm it's actually stuck on a finalizer
kubectl get application $APP_NAME -n $NAMESPACE -o jsonpath='{.metadata.deletionTimestamp}'
# A timestamp here = Application IS in Terminating state but stuck

kubectl get application $APP_NAME -n $NAMESPACE -o jsonpath='{.metadata.finalizers}'
# Likely shows: ["resources-finalizer.argocd.argoproj.io"]

# 3. Clear the finalizer
kubectl patch application $APP_NAME -n $NAMESPACE \
  --type=merge \
  -p '{"metadata":{"finalizers":[]}}'

# 4. Verify the Application is gone
kubectl get application $APP_NAME -n $NAMESPACE
# Expected: NotFound

# 5. Identify and clean up orphaned resources
# The Application's finalizer would normally prune managed resources.
# Since we bypassed it, manually delete what the Application was managing.
# Check the Application's manifest history for what to clean:
argocd app history $APP_NAME 2>&1 | head -20
# OR check what labels were applied (Atlas convention):
kubectl get all,configmap,secret -A -l app.atlas.io/component=<component-name>
# Delete each orphan as needed.
```

## What NOT to do

- **Do not restart the ArgoCD application-controller** to "fix" this. The finalizer is correctly waiting for cleanup; restarting controllers doesn't resolve the underlying deadlock.
- **Do not delete the finalizer in the Application template/ApplicationSet** as a permanent workaround unless you've reviewed INC-001 and decided that orphan-prevention is less important than rapid iteration for that workload.

## Why this happens

ArgoCD's `resources-finalizer.argocd.argoproj.io` finalizer ensures that when an Application is deleted, its managed Kubernetes resources get cleaned up. To do this, the finalizer needs to load the Application's source from Git to determine which resources it owns. If the source path no longer exists in Git, the source load fails, the finalizer can't complete, and the Application stays in Terminating forever.

The ApplicationSet controller will keep calling delete in a loop, but each delete call gets stuck on the same finalizer.

See [INC-001](../incidents/001-applicationset-finalizer-deadlock.md) for the full incident postmortem.

## Prevention

When intentionally removing an Application managed by an ApplicationSet:

1. **First** — drain the Application's resources via the ArgoCD UI (uncheck "auto-prune" temporarily, then sync, OR set sync policy to manual)
2. **Then** — delete the Application from the ApplicationSet's source (e.g., remove the Git directory)
3. **Only after** the Application has reached `Synced` with 0 resources should the source be removed

For Atlas specifically: until we automate this delete-order safety, this is a manual discipline.
