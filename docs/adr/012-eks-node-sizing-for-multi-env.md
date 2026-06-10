# ADR-012: EKS Node Sizing For Multi-Env Coexistence

**Status:** Accepted
**Date:** 2026-06-10
**Author:** Prashant
**Context:** Week 6 multi-env GitOps sprint (Days 1-2)

---

## Context

Atlas runs a non-trivial workload stack on EKS:

- **Platform layer:** ArgoCD, Argo Rollouts, ingress-nginx, CNPG operator, AWS Load Balancer Controller, EBS CSI driver — these run once per cluster, not per env.
- **Observability layer:** kube-prometheus-stack (Prometheus + Alertmanager + Grafana + node-exporters), Loki, Promtail — once per cluster.
- **Workload layer:** the three-tier app — runs THREE times (dev + staging + prod). Each instance includes backend (Argo Rollouts), frontend (Deployment), CNPG cluster (3 instances + connection pooler), MinIO (for backups), traffic-generator (CronJob).

Phase A (single env, Week 5) ran comfortably on 2× t3.medium nodes. Phase B added staging — 2× t3.medium became tight. Day 2 added prod — the cluster would have OOMed on any node group smaller than what we ended up with.

Two questions needed answering:

1. **How big should each node be?**
2. **How many nodes do we need?**

Plus a cost constraint: this is a portfolio project, not production. We don't need on-demand reliability, but we do need to actually fit the workload.

---

## Decision

**Use 4× t3.large spot instances (with t3a.large as fallback) in the EKS node group. Scaling config: min 3 / desired 4 / max 6.**

t3.large = 2 vCPU, 8 GiB memory per node. Total cluster capacity: 8 vCPU / 32 GiB across 4 nodes.

Spot capacity type with t3a.large as a fallback in the instance-types list provides resilience against spot interruption — if t3.large spot capacity is exhausted in an AZ, EKS will try t3a.large.

---

## Why 4 Nodes

### CNPG Cluster Anti-Affinity

CNPG's recommended deployment pattern uses anti-affinity rules so the three postgres instances (primary + 2 replicas) land on different nodes. With three envs, that's 9 postgres pods needing to spread across at least 3 nodes.

We could relax anti-affinity for a demo, but then losing one node loses an env's entire CNPG cluster — which makes the SLO recording rules' "availability" signal meaningless. Better to honor the operator's recommended pattern.

Result: ≥3 nodes for CNPG spread alone.

### Headroom For Canary

During an Argo Rollouts canary cycle, both stable and canary ReplicaSets run simultaneously. For backend with 3 replicas in prod, that's potentially 6 pods (3 stable + 3 canary at setWeight=100% prior to scaledown). Multiply by three envs running canaries: theoretically 18 backend pods, though in practice we only canary one env at a time during demos.

The 4-node cluster gives ~30% headroom on the steady-state pod count, which absorbs canary expansion without scheduling pressure.

### Why Not 3 Nodes

3 nodes works for steady state but breaks during:

- Node failure (workload pods stuck Pending until replacement comes up)
- Canary cycles (canary pods can't schedule)
- Karpenter / Cluster Autoscaler reconciliation delays (not used here, but the same dynamics apply)

Spot interruption probability for t3.large is ~5-10% per month per node. With 3 nodes, that's a meaningful chance of operating in a degraded state at any given time.

### Why Not 5+ Nodes

Diminishing returns. The marginal node adds ~$0.04/hour ($30/month at on-demand prices, ~$10/month at spot). The workload doesn't need it. Cost would creep up for portfolio value that doesn't materially improve.

---

## Why t3.large

### Memory Is The Binding Constraint

Per-node memory usage (observed at end of Day 2 with all 3 envs Healthy):

| Node | CPU% | Memory% |
|---|---|---|
| node-1 | 4% | 8% |
| node-2 | 6% | 22% |
| node-3 | 31% | 34% |
| node-4 | 14% | 27% |

Average: ~14% CPU, ~23% memory. Memory utilization is consistently 2-3× CPU utilization. This is typical for the workload — CNPG + Prometheus + Loki are all memory-heavy, not CPU-heavy.

### Per-Pod Memory Cost (Approximate)

| Component | Memory request | Replicas (per env) | Subtotal per env |
|---|---|---|---|
| backend (Rollout) | 32-128 Mi | 2-4 | ~256 Mi |
| frontend (Deployment) | 16-64 Mi | 1-3 | ~128 Mi |
| pg-1/2/3 (CNPG) | 256 Mi × 3 | 3 | ~768 Mi |
| pg-pooler-rw | 64 Mi × 2 | 2 | ~128 Mi |
| minio-0 (StatefulSet) | 128 Mi | 1 | ~128 Mi |
| traffic-generator | <50 Mi | 1 (cron) | ~50 Mi |
| Total per env | | | ~1.4 GiB |

Three envs × 1.4 GiB = ~4.2 GiB workload-tier memory.

Plus platform tier (~3-4 GiB for Prometheus + Loki + Grafana + operators + sidecars).

Total committed memory: ~8 GiB. With 32 GiB cluster capacity, ~25% utilization — matches observed.

### Why Not t3.medium

t3.medium = 4 GiB memory per node. Four nodes × 4 GiB = 16 GiB. Subtracting kubelet/system overhead (~500 MB/node = 2 GiB), usable capacity is ~14 GiB. The 8 GiB workload + platform footprint fits, but with no headroom for:

- Canary expansion (2× backend pods during rollout)
- Prometheus scrape-target growth (more ServiceMonitors = more series)
- Future env addition

It's the same workload that pushed t3.medium past its limits during the Phase B → multi-env transition.

### Why Not t3.xlarge

t3.xlarge = 16 GiB. Two nodes × 16 GiB = 32 GiB (same total as 4× t3.large). But:

- Fewer nodes means less anti-affinity flexibility for CNPG
- Spot interruption of a single t3.xlarge takes out half the cluster
- No improvement in usable capacity

More nodes with the same total RAM is strictly better for resilience.

---

## Why Spot Capacity

### Cost

| Instance | On-demand (ap-south-1) | Spot (typical discount) | 4× monthly (24/7) |
|---|---|---|---|
| t3.large | $0.0832/hour | ~$0.025/hour | ~$72/month |
| t3a.large | $0.0752/hour | ~$0.022/hour | ~$63/month |

vs on-demand 4× t3.large = ~$240/month.

For a portfolio project that's only running during dev sessions (~2-4 hours per session), the actual cost is much lower than monthly. But the rate matters during sessions, and 3-4× cheaper compute is a real differentiator.

### Interruption Tolerance

Atlas's workloads can tolerate spot interruption:

- ArgoCD reconciles back to desired state automatically
- CNPG promotes a replica to primary if the primary's node is reclaimed
- Argo Rollouts pauses canary progression during node disruption, then resumes
- StatefulSets re-bind their PVCs to the new pods on different nodes
- The traffic-generator CronJob just skips a minute

The cost of one interruption per session is ~30 seconds of degraded service while the new pod boots. Acceptable.

### Multi-Instance-Type Fallback

The node group declares two instance types: `["t3.large", "t3a.large"]`. EKS will provision whichever has spot capacity available, falling back if the preferred type is exhausted in an AZ.

This isn't true diversification (both are still general-purpose, both are still 2 vCPU / 8 GiB) but it materially reduces "unable to schedule" failures during cluster bootstrap.

### When Spot Would Be Wrong

For a production system serving real users, spot-only is too risky:

- Stateful workloads (databases) suffer from involuntary failover
- Costly recovery if multiple nodes interrupt simultaneously
- SLO breaches during unrelenting interruption events

The right pattern there is mixed on-demand + spot (e.g., 50/50 split), which AWS supports via mixed instance policies in ASGs. Atlas doesn't need this.

See ADR-008 for the original spot decision; this ADR extends it to multi-env.

---

## Implementation

### Terraform Config

In `infrastructure/terraform/eks/main.tf`:

```hcl
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "atlas-eks-dev-workers"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.private[*].id

  capacity_type   = "SPOT"
  instance_types  = ["t3.large", "t3a.large"]
  disk_size       = 20

  scaling_config {
    desired_size = 4
    min_size     = 3
    max_size     = 6
  }

  labels = {
    role        = "worker"
    environment = "dev"
  }
}
```

### CNPG Pod Anti-Affinity

CNPG's `Cluster` CR includes `affinity` rules so postgres instances spread across nodes. We use the operator's default `requiredDuringSchedulingIgnoredDuringExecution` with `topologyKey: kubernetes.io/hostname`. This MUST hold across all 3 envs, hence the need for ≥3 nodes.

### Observable Resource Pressure

If average memory utilization across nodes exceeds 60%, that's the signal to scale up. The max_size of 6 gives us 2 nodes of headroom before manual intervention.

---

## Consequences

### Positive

- **Three-env coexistence fits comfortably.** ~25% memory utilization at steady state means clear headroom for canary cycles and the occasional spike.
- **Spot capacity keeps costs low.** ~3× cheaper than on-demand for an interruption-tolerant workload.
- **Multi-instance-type fallback reduces bootstrap failures.** Spot capacity for t3.large vs t3a.large rarely correlate, so the fallback is meaningful.
- **CNPG anti-affinity satisfied.** 4 nodes ≥ 3-replica spread requirement.

### Negative

- **Spot interruption is real.** Demo sessions occasionally see pod disruption. Mitigation is the operators' built-in reconciliation; no user-facing degradation in a portfolio context, but a production deployment would need on-demand mix.
- **Cost is non-zero during operations.** ~$0.20/hour for the EKS control plane + 4 nodes + NAT gateway. Bootstrap → work → teardown discipline keeps monthly cost negligible (we destroy after each session). Without that discipline, ~$150-200/month accumulates.
- **Memory is the bottleneck, not CPU.** Workload growth (more envs, more CNPG instances) would hit memory before CPU. Future scaling decisions should account for this.

### Neutral

- **The node group is a single ASG.** Multi-AZ via subnet_ids list, but no zone awareness in scheduling. CNPG spreads pods across nodes but doesn't actively place them across AZs. This is fine for portfolio; production should add `topology.kubernetes.io/zone` topology spread constraints.

---

## Alternatives Considered

### Alternative 1: 2× t3.medium (Phase A Sizing)

What we started with in Week 5.

- **Pros:** Cheap (~$0.05/hour).
- **Cons:** Doesn't fit three envs of CNPG + monitoring stack. Already proven insufficient.
- **Decision:** Rejected.

### Alternative 2: 3× t3.large

Trim one node.

- **Pros:** Marginally cheaper.
- **Cons:** No headroom for canary expansion or node failure. CNPG anti-affinity is tight (3 nodes for 3 postgres pods means a single failure violates).
- **Decision:** Rejected. The 4th node is worth $10/month of operational margin.

### Alternative 3: 2× t3.xlarge

Same total RAM, fewer nodes.

- **Pros:** Fewer kubelet overhead instances. Simpler scheduling.
- **Cons:** Worse anti-affinity behavior. Spot interruption of one node loses half the cluster.
- **Decision:** Rejected.

### Alternative 4: Managed Node Groups With Multiple Pools

Separate node groups for platform vs workload (e.g., 2 on-demand for platform + 3 spot for workloads).

- **Pros:** Platform stability (Prometheus doesn't churn). Workload cost optimization.
- **Cons:** More complex Terraform. Two node groups to manage. Diminishing returns at Atlas's scale.
- **Decision:** Rejected as overengineering for a single-cluster demo. Worth revisiting if Atlas grew to 10+ envs.

### Alternative 5: Karpenter Instead Of Managed Node Group

Use Karpenter for just-in-time node provisioning based on pending pods.

- **Pros:** No idle nodes. Pay only for what's actually scheduled.
- **Cons:** Adds another controller. Karpenter on EKS requires its own IAM setup, NodePool definitions, and operational learning curve. Doesn't change the per-node sizing math.
- **Decision:** Rejected for this sprint. Worth a future ADR if iterating on cost.

---

## Compliance and Reversibility

This ADR can be reversed by editing one file:

```hcl
# infrastructure/terraform/eks/main.tf
resource "aws_eks_node_group" "main" {
  capacity_type   = "SPOT"           # → "ON_DEMAND" if needed
  instance_types  = ["t3.large", ...] # → ["t3.medium"] or ["t3.xlarge"]
  scaling_config {
    desired_size = 4                  # → any other count
  }
}
```

Then `terraform apply`. EKS handles the node group update (rolling replacement).

Total reversal work: ~10 min plan + ~10 min rolling replacement. Reversibility is high.

---

## References

- AWS EKS managed node groups: https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html
- Spot instance interruption rates: https://aws.amazon.com/ec2/spot/instance-advisor/
- CNPG cluster topology recommendations: https://cloudnative-pg.io/documentation/current/architecture/#deploying-on-a-multi-az-kubernetes-cluster
- Prometheus operator resource requirements: https://github.com/prometheus-operator/prometheus-operator/blob/main/Documentation/user-guides/getting-started.md
- ADR-008 (spot-only node group) — original spot decision
- ADR-001 (cluster runtime) — why EKS at all
- ADR-007 (single NAT gateway) — adjacent cost-optimization decision
- Day 2 final state showing node utilization: `docs/learning/week-6-eks/multi-env-gitops-day-2.md`
