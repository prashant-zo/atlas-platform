# ArgoCD Permanent Drift on StatefulSet volumeClaimTemplates

**Date encountered:** 2026-05-24
**Component:** MinIO StatefulSet (and any other StatefulSet with PVC templates)
**Severity:** Cosmetic — apps healthy, dashboard showed permanent OutOfSync

## Symptom

After installing MinIO as a StatefulSet, all three three-tier apps showed
permanent `OutOfSync` even after sync, prune, and refresh. `argocd app
diff` showed exactly two extra lines in the live spec vs Git:

\`\`\`
LIVE:                              DESIRED:
- apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:                        - metadata:
    creationTimestamp: null            creationTimestamp: null
    name: data                         name: data
\`\`\`

## Root Cause

The Kubernetes API server, when storing a StatefulSet, **auto-populates
defaults** on every entry in `spec.volumeClaimTemplates`. Specifically
it adds `apiVersion: v1` and `kind: PersistentVolumeClaim` because the
PVC type is implicit in this context — the schema knows what kind these
templates are.

These fields are not in our Git YAML (no reason for us to write them
since they're inferred from context). But ArgoCD does a literal
comparison between Git and live state, so it sees the cluster has two
fields that Git doesn't. The diff will never close on its own because:

1. We re-sync → ArgoCD applies our YAML (without the fields)
2. API server stores it → fills in the defaults
3. ArgoCD compares → sees the difference again
4. Loop forever

## Fix

Tell ArgoCD to ignore the API-server-added defaults via
`ignoreDifferences`:

\`\`\`yaml
ignoreDifferences:
  - group: apps
    kind: StatefulSet
    jsonPointers:
      - /spec/volumeClaimTemplates
\`\`\`

This goes in the Application spec — or for our case, in the
ApplicationSet template so it applies to all generated Applications.

## Why This Matters (Second Level)

**Declarative GitOps tools assume Git represents the full intent.** But
the Kubernetes API server is itself a participant in defining the
"actual state" — it normalizes manifests, fills in defaults, computes
hashes, generates names for sub-resources. Any field the API server
adds that Git doesn't declare becomes permanent drift.

The general solution categories:
1. **Ignore the field via `ignoreDifferences`** — accept that the API
   server owns this field, not us
2. **Explicitly declare the field in Git** — fight the noise by being
   verbose
3. **Use server-side apply with proper field ownership** — declare
   which fields you own; the API server tracks the rest

Option 1 is what ArgoCD recommends for ecosystem-known cases like this.
Option 3 is the long-term direction but requires SSA-aware tooling.

## Resources Commonly Affected

Add `ignoreDifferences` rules for these when you hit them:
- **StatefulSets** — `/spec/volumeClaimTemplates` (this case)
- **Deployments** — `/spec/template/metadata/annotations` (rollout
  controllers like Flagger add annotations)
- **HorizontalPodAutoscalers** — `/spec/metrics` (controller adds
  `target.averageUtilization` defaults)
- **Certificates** (cert-manager) — entire `/status` block
- **HelmReleases** — `/spec/values` if Helm controller normalizes them

## Interview Talking Point

> "After installing MinIO as a StatefulSet, my ArgoCD apps showed
> permanent OutOfSync — but the apps were healthy and the diff showed
> only two API-server-added fields on the volumeClaimTemplates. The
> Kubernetes API server fills in `apiVersion: v1` and `kind:
> PersistentVolumeClaim` on PVC templates because the schema knows
> what kind they are — but those fields aren't in my Git YAML. ArgoCD
> sees the cluster has extra fields and reports drift forever.
> 
> The fix is `ignoreDifferences` in the Application spec, pointing
> ArgoCD at the JSON path it should ignore. This is a known
> ArgoCD-vs-API-server mismatch with several common offenders:
> StatefulSet PVC templates, HPA metrics defaults, cert-manager
> Certificate status blocks. The deeper lesson is that GitOps tools
> need to know the API server is also a participant in defining state
> — fields the server adds need explicit ignore rules or full-server-
> side-apply ownership tracking."
