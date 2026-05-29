# Kustomize Strategic-Merge Patches Silently Corrupt CRD Resources

**Date:** 2026-05-29
**Symptom:** Argo Rollout reports `Degraded` with
`spec.template.spec.containers[0].image: Required value`.
The base manifest clearly defined the image, but it was missing in
the rendered overlay output.

## Root Cause

Strategic-merge patches rely on Kustomize's knowledge of the target
resource's schema — specifically the `patchStrategicMergeKey` directives
that tell it how to merge lists (e.g., merge container list by `name`).
For built-in Kubernetes types (Deployment, StatefulSet), Kustomize ships
this knowledge.

For CRDs like Argo Rollouts' `Rollout`, Kustomize has no schema knowledge.
A strategic-merge patch targeting a CRD's container list will silently
**replace** the matched list element rather than merge fields into it.
Every field not explicitly named in the patch (image, env, ports,
probes) gets wiped from the rendered output.

The Rollout admission controller then rejects the resource as invalid,
the controller can't create a ReplicaSet, and zero pods are produced.
The error message correctly identifies the missing field but does not
hint at the Kustomize-level cause.

## The Fix

Use **JSON 6902 patches** (`op/path/value` style) for CRDs. JSON 6902
modifies only the explicit path you specify; it is schema-agnostic and
cannot accidentally strip sibling fields.

\`\`\`yaml
# overlays/dev/backend-resources-patch.yaml
- op: replace
  path: /spec/template/spec/containers/0/resources
  value:
    requests: { memory: "32Mi", cpu: "25m" }
    limits:   { memory: "64Mi", cpu: "100m" }
\`\`\`

Reference it in kustomization.yaml with an explicit `target:` block:

\`\`\`yaml
patches:
  - path: backend-resources-patch.yaml
    target:
      group: argoproj.io
      version: v1alpha1
      kind: Rollout
      name: backend
\`\`\`

## Secondary Bug: Pod Template Labels Missing

Kustomize's `labels:` block adds labels to resource `metadata` but does
NOT add them to a Rollout's `spec.template.metadata` (pod template).
If a Service selects pods by labels Kustomize injected at the resource
level, the Service will never find the Rollout's pods even after they
exist.

Fix: declare the required pod-template labels and selector matchLabels
directly in the base Rollout manifest, not via Kustomize's transformer.

## Diagnostic Pattern

When a Rollout reports `Degraded: containers[0].image: Required value`,
do not assume the base manifest is wrong. Render the overlay and
inspect what Kustomize produced:

\`\`\`bash
kustomize build overlays/<env>/ | grep -A30 "kind: Rollout"
\`\`\`

If the rendered Rollout is missing fields present in the base, a
strategic-merge patch is corrupting it. Switch that patch to JSON 6902.

## Interview Talking Point

> "When I converted a Deployment to an Argo Rollout, the Rollout came
> up Degraded saying the image field was missing — even though it was
> clearly in the base manifest. The cause was Kustomize: strategic-merge
> patches need schema knowledge to merge container lists correctly. For
> built-in types Kustomize has that schema; for CRDs it doesn't, so it
> falls back to replacing the list element instead of merging fields,
> silently wiping image, env, and probes. The fix was JSON 6902 patches,
> which work on explicit paths and don't need schema awareness. The
> lesson: Kustomize's built-in transformers are schema-aware only for
> standard Kubernetes types — for any CRD, prefer JSON 6902."
