# Decision: Local Development = Dev Environment Only

**Date:** 2026-05-27
**Hardware:** 8GB M1 MacBook Air, ~4-5GB available for Colima after macOS overhead
**Decision:** Run only the dev environment in local kind cluster

## The Math

Atlas's full 3-environment footprint requires ~6-7GB of cluster memory.
Available memory inside Colima on 8GB Mac: ~5GB realistic. The 1-2GB gap
manifests as OOM kills, swap thrashing, and cluster instability — none of
which are architectural problems, but all of which prevent the cluster
from being useful for learning.

## What This Doesn't Change

- Atlas's full 3-environment architecture lives in Git (overlays, ApplicationSets, manifests)
- The multi-environment GitOps pattern is fully demonstrated in the Git tree
- All ADRs, runbooks, INC postmortems remain valid
- EKS validation weekend (Week 6) will deploy the full 3-env stack at scale

## What This Does Change

- ApplicationSets generate only `three-tier-dev` locally
- Staging and prod namespaces are not created locally
- Memory pressure resolved, cluster stable
- Observability work (Week 4) and progressive delivery (Week 5) target dev only

## Industry Realism

Most platform engineers don't run prod-replica environments on their laptops.
Real workflow:
- Local: one env per developer, fast iteration
- Cloud staging/preview: full-scale, multi-env, ephemeral
- Cloud prod: actual production

Atlas's "3 envs locally" was a learning exercise that doesn't reflect
production practice. Adjusting to industry practice is the lesson.

## To Restore Full Multi-Environment Locally (On Larger Hardware)

\`\`\`bash
nvim gitops/apps/workloads-non-prod.yaml
# Add staging back to the list generator

nvim gitops/apps/workloads-prod.yaml
# Add prod back to the list generator

git add gitops/apps/
git commit -m "ops: restore full multi-environment"
git push
\`\`\`

ArgoCD picks up the change, recreates Applications, full stack runs.

## Interview Talking Point

> "I designed Atlas for 3 environments. On 8GB hardware that exceeds available
> memory, so locally I run dev only. The full 3-environment architecture lives
> in Git and gets instantiated on EKS during the validation weekend. This mirrors
> how real teams operate: laptop-scale for iteration, cloud-scale for validation.
> Hardware constraints are real engineering inputs — the senior move is matching
> scope to capacity, not pushing through OOM kills."
