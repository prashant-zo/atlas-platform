# Kustomize + CRDs: Three Traps Hit When Converting Deployment → Rollout

**Date:** 2026-05-29
**Context:** Task 5.3 — converted backend from Deployment to Argo Rollout.
Three real bugs surfaced in sequence, all caused by Kustomize's
schema-awareness gap on CRDs.

## Bug 1: Strategic-Merge Patch Silently Corrupts CRD Container Spec

### Symptom
Rollout reports `Degraded`:
spec.template.spec.containers[0].image: Required value

Even though the base manifest clearly defined the image, env, ports,
and probes — the rendered Rollout was missing all of them, keeping only
the fields explicitly named in the overlay patch.

### Cause
Strategic-merge patches rely on Kustomize knowing the target resource's
schema — specifically the `patchStrategicMergeKey` directives that tell
it how to merge lists (e.g., "merge `containers` by `name`"). For
built-in Kubernetes types (Deployment, StatefulSet), Kustomize ships
this knowledge.

For CRDs like `Rollout`, Kustomize has no schema knowledge. A
strategic-merge patch targeting a CRD's container list silently
**replaces** the matched list element rather than merging fields into
it. Every field not named in the patch (image, env, ports, probes) gets
wiped from the rendered output.

The Rollout admission controller then rejects the resource as invalid,
the controller cannot create a ReplicaSet, and zero pods exist. The
error message correctly identifies the missing field but does not hint
at the Kustomize-level cause.

### Fix
Use **JSON 6902 patches** (`op`/`path`/`value` style) for CRDs. JSON 6902
modifies only the explicit path you specify; it is schema-agnostic and
cannot accidentally strip sibling fields.

```yaml
# overlays/dev/backend-resources-patch.yaml
- op: replace
  path: /spec/template/spec/containers/0/resources
  value:
    requests: { memory: "32Mi", cpu: "25m" }
    limits:   { memory: "64Mi", cpu: "100m" }
```

Reference it with an explicit `target:` block:

```yaml
patches:
  - path: backend-resources-patch.yaml
    target:
      group: argoproj.io
      version: v1alpha1
      kind: Rollout
      name: backend
```

## Bug 2: Kustomize `labels:` Block Does Not Inject Into Pod Templates

### Symptom
The Service `backend-svc` selects on three labels:
`app=backend, app.atlas.io/managed-by=argocd, app.atlas.io/workload=three-tier-app`.
After the Rollout was finally creating pods, the Service endpoint stayed
empty — pods existed but were unreachable.

### Cause
Kustomize's `labels:` transformer adds labels to resource `metadata` and
to `spec.selector.matchLabels` for built-in workload types it
understands (Deployment, StatefulSet). It does **not** automatically
inject those labels into a Rollout's `spec.template.metadata.labels`
(the pod template), because Kustomize doesn't have the Rollout schema.

Result: the Rollout's metadata had the labels, but the pods it spawned
didn't, so the Service selector never matched.

### Fix
Declare pod-template labels and selector matchLabels explicitly in the
base Rollout manifest:

```yaml
spec:
  selector:
    matchLabels:
      app: backend
      app.atlas.io/managed-by: argocd
      app.atlas.io/workload: three-tier-app
  template:
    metadata:
      labels:
        app: backend
        tier: api
        app.atlas.io/managed-by: argocd
        app.atlas.io/workload: three-tier-app
```

Do not rely on Kustomize transformers to add labels to CRD pod templates.

## Bug 3: ArgoCD Diff Engine Refuses To Default Port Protocol

### Symptom
ArgoCD shows `Sync Status: Unknown / Health: Healthy` for the Rollout.
Error:

Failed to calculate diff: ... .spec.template.spec.containers[0].ports:
element 0: associative list with keys has an element that omits key
field "protocol" (and doesn't have default value)

### Cause
ArgoCD's structured-merge diff engine treats container `ports` as an
associative list keyed by `protocol` + `containerPort`. For built-in
Kubernetes types, the admission controller defaults `protocol: TCP` if
omitted, so the live resource and the Git manifest converge to the same
shape.

For CRDs like Rollout, ArgoCD reads the CRD's OpenAPI schema. The Argo
Rollouts CRD does not declare a default for `protocol`. The diff engine
refuses to assume a default — it needs the key explicitly declared to
compute the associative-list comparison. Sync Status goes Unknown until
the field is declared.

### Fix
Declare `protocol: TCP` explicitly in the Rollout's port spec:

```yaml
ports:
  - name: http
    containerPort: 5678
    protocol: TCP
```

## Common Thread

Kustomize and ArgoCD both have rich schema awareness for built-in
Kubernetes types. For CRDs they fall back to less-safe defaults:

| Layer            | Built-in behavior                | CRD behavior                          |
|------------------|----------------------------------|---------------------------------------|
| Kustomize merge  | Smart merge by named keys        | Replace whole list element            |
| Kustomize labels | Injected into pod templates      | Only injected into resource metadata  |
| ArgoCD diff      | Defaults applied (e.g. protocol) | Defaults refused, must declare        |

**Rule of thumb:** when working with CRDs, prefer explicit, schema-agnostic
declarations. JSON 6902 patches for overlays. Explicit pod-template
labels in base manifests. Explicit values for fields that have implicit
defaults on built-in types.

## Interview Talking Point

> "When I converted a Deployment to an Argo Rollout, I hit three real
> Kustomize and ArgoCD bugs in sequence. First, a strategic-merge patch
> targeting the Rollout's container list silently wiped the image, env,
> and probes — because Kustomize lacks schema knowledge for CRDs, it
> replaces list elements instead of merging fields. Switched to JSON
> 6902 patches, which are schema-agnostic and only touch explicit paths.
> Second, the Service selector didn't match the Rollout's pods because
> Kustomize's `labels:` transformer adds labels to resource metadata
> but not to a CRD's pod template — declared the labels in the base
> manifest directly. Third, ArgoCD's diff engine showed Sync Status
> Unknown because it refuses to assume a default `protocol: TCP` on
> container ports for CRD types — declared the protocol explicitly. The
> common pattern: tooling has rich schema awareness for built-in types
> and falls back to less-safe defaults for CRDs. When working with CRDs,
> prefer explicit declarations over implicit defaults."
