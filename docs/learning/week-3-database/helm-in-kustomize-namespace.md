# Helm-in-Kustomize: The Namespace Injection Gap

**Date encountered:** 2026-05-24
**Component:** CloudNativePG operator installation
**Severity:** Blocking — operator could not deploy

## Symptom

After committing the CNPG operator package and ArgoCD reconciling it, the
`platform-cnpg-operator` Application showed:

APP HEALTH: Missing
SYNC STATUS: OutOfSync
ERROR: InvalidSpecError: Namespace for cnpg-cloudnative-pg /v1,
Kind=ServiceAccount is missing.

A round of fixes earlier had also created a wrong-namespace deployment in
`kube-system` because the platform ApplicationSet's template hardcoded
`destination.namespace: kube-system` — but that was a separate prior bug.

After moving the namespace declaration into each component's Kustomization
(the correct architectural pattern), the CNPG package still failed with
the InvalidSpecError above.

## Diagnosis Path

1. Confirmed the operator was missing entirely:
```bash
   kubectl get pods -n cnpg-system
   # No resources found
```

2. Checked what ArgoCD thinks it manages:
```bash
   argocd app resources platform-cnpg-operator
   # All resources showed "Synced" status
   # But the failed sync attempts produced "InvalidSpecError" for each
   # non-cluster-scoped resource
```

3. Rendered the package locally and grep'd for ServiceAccount:
```bash
   kustomize build --enable-helm gitops/platform/cnpg-operator/ \
     | grep -B1 -A4 "kind: ServiceAccount"
```
   Output:
```yaml
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     labels:
       app.atlas.io/component: cnpg-operator
       # ← NO namespace field
```

4. Verified ArgoCD config was correct:
```bash
   kubectl get configmap argocd-cm -n argocd -o yaml | grep kustomize
   # kustomize.buildOptions: --enable-helm    ✓ correct
```

   So ArgoCD's config was right — the problem was in what Kustomize was
   producing for ArgoCD to apply.

## Root Cause

When Kustomize processes a Helm chart via the `helmCharts:` directive,
it inflates the chart's templates and applies subsequent transformations.

The CNPG Helm chart **does not include `namespace:` in the metadata of
namespaced resources** (ServiceAccount, ConfigMap, Service, Deployment).
The chart assumes the Helm CLI will inject the install namespace at apply
time via `helm install -n cnpg-system`.

When Kustomize is the apply path, that Helm-CLI-side injection doesn't
happen. Then Kustomize's top-level `namespace:` field has a subtle
documented behavior: it only modifies resources that **already have** a
namespace field. It does not add the field to resources lacking it
entirely. This is intentional safety to avoid clobbering cluster-scoped
resources accidentally.

Result: namespaced resources came out of Kustomize with no namespace
field, and ArgoCD's apply step rejected them with InvalidSpecError.

## The Fix

Three changes to `gitops/platform/cnpg-operator/kustomization.yaml`:

1. **Set `namespace:` at the Kustomization top level** — catches any
   resources where it can fill in the field.
2. **Set `namespace: cnpg-system` inside the `helmCharts:` block** — this
   makes Helm's own template logic use the namespace where the chart
   already supports it (subjects: in RoleBindings, for example).
3. **Add an explicit `Namespace` resource** to `resources:` — guarantees
   the namespace exists before any namespaced resource lands in it.

Final Kustomization:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: cnpg-system           # 1. Kustomization-level

helmCharts:
  - name: cloudnative-pg
    repo: https://cloudnative-pg.github.io/charts
    version: 0.22.1
    releaseName: cnpg
    namespace: cnpg-system        # 2. Helm-level
    includeCRDs: true
    valuesInline:
      replicaCount: 1
      # ...

resources:
  - namespace.yaml                # 3. Explicit Namespace resource

labels:
  - includeSelectors: false
    pairs:
      app.atlas.io/managed-by: argocd
      app.atlas.io/component: cnpg-operator
```

Plus a separate `namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cnpg-system
  labels:
    app.atlas.io/managed-by: argocd
```

After commit + push + ArgoCD sync: operator pod came up Running in
`cnpg-system`. CRDs registered. `kubectl explain cluster.spec
--api-version=postgresql.cnpg.io/v1` returned the field documentation.

## Why This Happens (The Second Level Of Detail)

Kustomize and Helm have **fundamentally different theories of namespace
ownership**:

- Helm treats the install namespace as a *runtime parameter*. The CLI
  injects it. Chart authors deliberately don't write namespaces into
  templates because that would lock the chart to one install location.

- Kustomize treats the namespace as a *manifest property*. Every namespaced
  resource is expected to declare its own namespace. Kustomize's
  `namespace:` field is a transformer that overrides what's declared.

When you wrap a Helm chart inside Kustomize, you have two systems with
different assumptions about who owns the namespace. The `helmCharts:`
directive doesn't bridge them — it inflates the chart and passes the
output to Kustomize as-is. If the chart omits namespaces, Kustomize sees
namespace-less resources and applies its safety rule of "don't add a
namespace if one wasn't there."

This is a well-known sharp edge in the Kubernetes ecosystem. CNCF
maintainers have discussed deprecating `helmCharts:` in favor of
ArgoCD's native multi-source Application type that handles Helm and
Kustomize as first-class sources without the wrapping.

## Interview Prompt And Ideal Answer

> **Interviewer:** "Tell me about a deployment issue you debugged where the
> tooling itself was the problem, not your code."

**Answer:**

"On Atlas I installed CloudNativePG via its Helm chart, wrapped in a
Kustomize package so it could be managed by my platform ApplicationSet.
The first sync attempt failed with `InvalidSpecError: Namespace for
ServiceAccount is missing` — even though I had set `namespace:
cnpg-system` at the top of the Kustomization.

I rendered the package locally with `kustomize build --enable-helm` and
grep'd for the ServiceAccount. It came out with no namespace field at
all. That told me the bug was in Kustomize's interaction with Helm, not
in ArgoCD.

The root cause: Helm charts don't write namespaces into their templates
because Helm's CLI injects the namespace at install time. When you wrap
a Helm chart in Kustomize, the CLI-side injection doesn't happen, and
Kustomize's `namespace:` field has a safety rule that only modifies
resources where the field already exists — it doesn't add it where
missing.

The fix was to declare the namespace in three places: at the Kustomization
top level, inside the `helmCharts:` block (so Helm templates that reference
the namespace get it), and as an explicit Namespace resource in
`resources:` so it's guaranteed to be created first.

This is a known limitation in the ecosystem — Kustomize and Helm have
different ownership theories for namespaces, and the `helmCharts:`
directive doesn't bridge them. The more robust pattern at scale is
ArgoCD's native multi-source Application type, which handles each
source on its own terms instead of forcing one through the other."

---

The "second-level" probing would then ask things like:

- "Why does Kustomize's `namespace:` field have that safety rule?"
  (To avoid clobbering cluster-scoped resources that legitimately have
  no namespace, like ClusterRoles.)

- "What's the difference between `namespace:` at Kustomization-level
  vs inside `helmCharts:`?"
  (Kustomization-level is post-render Kustomize transformation; inside
  `helmCharts:` is passed to Helm's own templating engine.)

- "Would ArgoCD's native Helm source have hit the same bug?"
  (No, because ArgoCD's native Helm source uses Helm's render path
  end-to-end with proper namespace handling. The bug is specific to
  Kustomize-wrapping-Helm.)

## What I'd Do Differently Next Time

For any operator that ships its own Helm chart and includes CRDs, default
to ArgoCD's native multi-source Application type rather than wrapping the
Helm chart in Kustomize. The Kustomize wrap is fine for components that
don't need Helm — but as soon as Helm enters the picture, native
Application is cleaner.

The reason we used Kustomize-wrapping-Helm: the platform ApplicationSet's
Git directory generator assumes each directory is a Kustomize package.
Mixing native-Helm and Kustomize sources in the same ApplicationSet
needs ApplicationSet template conditionals or two separate
ApplicationSets.
