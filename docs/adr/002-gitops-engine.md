# ADR-002: Use ArgoCD as the GitOps Engine

**Status:** Accepted
**Date:** 2026-05-22
**Deciders:** Prashant

## Context

Atlas implements GitOps as a core platform pattern: every cluster change flows through Git, and a controller in the cluster reconciles the cluster's actual state to match Git. This requires choosing a GitOps engine — the in-cluster software that watches Git, renders manifests, applies them, and reverts drift.

The two mainstream choices are ArgoCD (CNCF graduated, originated at Intuit) and Flux v2 (CNCF graduated, originated at Weaveworks). Both implement the GitOps Toolkit specification correctly. Both have large production users. The decision is not "which one works" — both work. The decision is "which one's design philosophy and feature set best fits Atlas's specific needs for the next 5 weeks of work."

The constraints driving this choice:

1. **Multi-environment workloads.** Atlas will deploy a 3-tier application across dev / staging / prod with Kustomize overlays. The GitOps engine needs to fan one source into multiple Applications cleanly.
2. **Progressive delivery integration.** Week 5 introduces Argo Rollouts for canary deployment with metric-based analysis. The GitOps engine should integrate with that without friction.
3. **Solo operator UX.** This is a portfolio project built and demonstrated by one person. A web UI for visualizing the state graph is high-value during interviews, where a screen share is more compelling than terminal output.
4. **CNCF-graduated project status.** Anything we adopt should be technology a real production team would also adopt — not a clever-but-niche tool.

## Decision

We will use **ArgoCD** as the GitOps engine for Atlas. The installation pattern is the App-of-Apps with one manually-applied root Application that watches a directory of child Applications, plus an ApplicationSet (Git directory generator) for fanning components and environments out of single templates.

The Argo project also provides Argo Rollouts (Week 5) and Argo Workflows (out of scope), creating a coherent ecosystem with shared concepts and a single web UI surface.

## Alternatives Considered

### Option A: Flux v2 (Flux CD)

- **Pros:** Cleanly decomposed into separate controllers (source-controller, kustomize-controller, helm-controller, notification-controller) that follow strict Kubernetes operator patterns. Lighter-weight per-component installs. CLI (`flux`) is more idiomatic Kubernetes than ArgoCD's. No long-lived web server component — every interaction is via `kubectl` or `flux`. Strong integration with Helm registries and OCI sources.
- **Cons:** No first-party web UI — observability happens through `kubectl get` and CRD events. Multi-tenant story exists but is less mature than ArgoCD's Projects feature. No native App-of-Apps pattern — the equivalent is Kustomizations referencing Kustomizations, which works but lacks the explicit hierarchical model.
- **Rejected because:** The no-UI tradeoff is wrong for this project specifically. During interviews, demonstrating an ArgoCD app tree visualization is a far stronger signal than walking through `kubectl describe` output. For a real platform team operating Flux daily, the controller modularity is a significant maintainability win — but for a portfolio project, the demo value of the UI outweighs that.

### Option B: Argo CD with ApplicationSet only (no App-of-Apps)

- **Pros:** Fewer concepts to learn. ApplicationSets alone can fan out platform components and environments cleanly via multiple generators.
- **Cons:** Loses the explicit hierarchical "one root application that manages all other applications" model. Disaster recovery becomes "apply N ApplicationSets" rather than "apply 1 root." For a non-trivial platform, the root-first pattern is what large GitOps shops actually run.
- **Rejected because:** The App-of-Apps + ApplicationSet combination is the idiomatic ArgoCD pattern at scale. Picking only ApplicationSet would be premature optimization for a small platform that we already know is going to grow to 8+ Applications by Week 6. The cost of learning the App-of-Apps pattern now is negligible; the cost of refactoring to it later is high.

### Option C: Jenkins / GitHub Actions CI/CD (push-based deploys)

- **Pros:** Familiar to everyone with a CI/CD background. Direct control over deployment sequencing. No additional cluster software to install.
- **Cons:** Push-based, not pull-based — fundamentally not GitOps. The cluster does not reconcile drift; if someone runs `kubectl edit` manually, the change persists silently. Disaster recovery requires re-running the entire CI pipeline. No reconciliation loop means no continuous state verification.
- **Rejected because:** Atlas is explicitly a GitOps platform demonstration. Choosing push-based CI/CD would defeat the purpose of the project and would not address the senior-interview hiring signal Atlas is designed to send. CI/CD remains in scope for *image build* in Week 5, but deployment is owned by ArgoCD.

### Option D: Spinnaker

- **Pros:** Mature, battle-tested at Netflix scale. Powerful pipeline-as-code model. Deep multi-cluster orchestration.
- **Cons:** Operationally heavy — requires Halyard, a dedicated Redis, and significant memory. Not GitOps-first by design (added pipelines reading from Git later). Steeper learning curve than the time budget allows.
- **Rejected because:** Operational weight is incompatible with the M1 / 8GB Colima constraint. Spinnaker is also out of fashion in 2026 platform engineering circles — ArgoCD has become the de facto choice and "I run Spinnaker" no longer carries the same weight in interviews.

## Consequences

### Positive

- Web UI provides immediate visualization of every Application's sync and health state — high demo value.
- App-of-Apps + ApplicationSet pattern handles current 2-Application case and scales to the 8+ Applications planned for Weeks 3-5 without architectural change.
- Argo Rollouts (Week 5) integrates natively — same control plane, shared mental model.
- ApplicationSet's Git directory generator enables filesystem-level platform engineering: add a directory, get an Application.
- ArgoCD's wide adoption means StackOverflow / Slack answers exist for nearly any failure mode, shortening debug time.

### Negative

- ArgoCD's single web server is a long-lived process — more memory than Flux's per-controller model. Tolerable on 8GB Colima but noticeable.
- ArgoCD's CRD set (`Application`, `ApplicationSet`, `AppProject`) is larger than Flux's, increasing the surface area for permission management when we add RBAC in Week 3.
- The web UI introduces an authentication surface (admin password rotation, SSO config) that Flux doesn't have. Local-only deployment sidesteps this for now but it returns on the EKS validation weekend.
- ArgoCD's finalizer-based resource pruning has a known deadlock when a source directory is removed before resources are pruned. We've already encountered this — see [INC-001](../incidents/001-applicationset-finalizer-deadlock.md) — and have a documented mitigation.

### Neutral

- Both engines support OCI Helm registries; AWS ECR Helm push works equivalently from both.
- Both engines support multi-cluster deployments. ArgoCD's `argocd cluster add` is slightly more ergonomic; Flux's GitOps-native cluster bootstrap is slightly cleaner. Neither is a meaningful blocker for the single-cluster Atlas scope.

## References

- ArgoCD architecture: https://argo-cd.readthedocs.io/en/stable/operator-manual/architecture/
- Flux v2 architecture: https://fluxcd.io/flux/components/
- CNCF GitOps Working Group landscape: https://github.com/cncf/tag-app-delivery/blob/main/gitops-wg/README.md
- The App-of-Apps pattern: https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/
- ApplicationSet generators: https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators/
- INC-001 (encountered an ArgoCD-specific failure mode early): [../incidents/001-applicationset-finalizer-deadlock.md](../incidents/001-applicationset-finalizer-deadlock.md)
