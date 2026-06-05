# ADR-008: Spot-Only Node Group for EKS Workers

**Date:** 2026-06-04
**Status:** Accepted
**Context:** Week 6 — EKS Module Design

## Context

The EKS module (Task 6.2) creates a managed node group of EC2 instances
to run Atlas's workloads. EKS managed node groups support two capacity
types: **ON_DEMAND** and **SPOT**.

Pricing in ap-south-1 for t3.large (the chosen instance type):

| Capacity Type | Hourly Cost | Notes |
|---------------|-------------|-------|
| On-Demand     | $0.090/hr   | Guaranteed availability |
| Spot          | ~$0.025/hr  | ~72% discount; can be reclaimed with 2-min warning |

For 2 nodes running 12 hours: On-Demand = $2.16, Spot = $0.60. Difference: $1.56.

Spot economics shift dramatically at scale or for long-running clusters,
but Atlas's lifecycle is short.

## Options Considered

### Option 1: Pure On-Demand

Both worker nodes are On-Demand instances. AWS won't reclaim them.

**Pros:**
- Guaranteed availability — no risk of reclamation during demo
- No need to handle pod rescheduling on capacity loss
- Simpler operational story

**Cons:**
- 3-4× more expensive per hour
- Doesn't demonstrate any Kubernetes self-healing under capacity changes
- "I picked the safe expensive option" is a weaker engineering story

### Option 2: Pure Spot (with multiple instance type fallbacks)

Both nodes are Spot. Specify multiple instance types (t3.large, t3a.large)
so AWS can pull capacity from the largest available pool.

**Pros:**
- 72% cost savings (~$36/month at running rate vs ~$130/month for on-demand)
- Demonstrates production-grade resilience patterns
- Multiple instance types reduce reclamation probability
- Atlas's stateless workloads tolerate pod rescheduling well

**Cons:**
- AWS can reclaim nodes with 2-minute warning
- If both Spot nodes are reclaimed simultaneously, brief outage until
  replacement nodes come up
- Stateful workloads (Postgres) need to handle pod rescheduling carefully

### Option 3: Mixed Capacity (1 On-Demand + 1 Spot)

Two separate node groups: one ON_DEMAND with 1 node (for stateful),
one SPOT with 1 node (for stateless).

**Pros:**
- Stateful workloads (Postgres) get guaranteed nodes
- Demonstrates cost-vs-availability tradeoff explicitly
- Best-of-both story for interviews

**Cons:**
- Two node groups = double the Terraform complexity
- EKS managed node groups don't support mixed capacity within a group
  (a known limitation)
- Pod scheduling requires careful taint/toleration setup to direct
  workloads to the right capacity pool
- For Atlas's scale (2 nodes), the complexity outweighs the value

### Option 4: Karpenter (advanced)

Use Karpenter for capacity provisioning instead of managed node groups.
Karpenter supports mixed Spot + On-Demand within a single provisioner.

**Pros:**
- True mixed capacity in one unit
- Faster scale-up than EKS managed node groups
- Bin-packs pods more efficiently

**Cons:**
- Karpenter requires its own setup (Helm chart, IAM roles, etc.)
- New tool for Atlas's narrative — adds learning surface area
- Atlas's static 2-node workload doesn't benefit from Karpenter's
  dynamic provisioning advantages

## Decision

Use **pure Spot capacity** with multiple instance type fallbacks.

```hcl
capacity_type  = "SPOT"
instance_types = ["t3.large", "t3a.large"]
```

The fallback list lets AWS pull from whichever pool has the most spare
capacity at the moment, reducing reclamation probability.

## Consequences

### Positive

- **~72% cost reduction on worker nodes.** Hourly: $0.025 vs $0.090.
  For Atlas's $60 monthly budget, this difference matters.
- **Demonstrates real-world cost optimization.** Spot-by-default is
  the pattern adopted by AI/ML companies, data pipelines, and cost-conscious
  production teams. Putting it in Atlas signals familiarity with
  industry-standard practices.
- **Multiple instance types reduce reclamation risk.** Spot interruption
  rate for t3 family in ap-south-1 is typically < 5% across a day.
  With t3a fallback, effective rate is lower.
- **Interview story is stronger.** "I chose Spot because Atlas's workloads
  are stateless or have automated failover (CNPG handles Postgres
  reclamation correctly). Mixed capacity would have doubled the
  Terraform complexity for negligible benefit at this scale."

### Negative

- **Reclamation risk during demo recording.** If both Spot nodes are
  reclaimed mid-demo, there's a 2-3 minute window where pods are
  rescheduling. Mitigated by:
  - Multiple instance types (t3, t3a) so reclamation hits one type at a time
  - Atlas's workloads are designed to recover from node loss (Week 3 GameDay
    proved this for the CNPG cluster)
- **Postgres pods may move under load.** CNPG handles this correctly via
  StatefulSet + persistent volume claim semantics. Tested in INC-002.
- **Loom recording risk.** A reclamation mid-recording would force a
  re-take. Acceptable risk for the cost savings.

### Neutral

- **Documented as deliberate choice.** Anyone reviewing Atlas's
  Terraform code sees the explicit `capacity_type = "SPOT"` and
  understands this was a conscious decision, not a default.
- **Reversible in one line.** Change `capacity_type = "SPOT"` to
  `capacity_type = "ON_DEMAND"` and `terraform apply` switches the
  pool. Cost goes up $0.065/hour but availability is guaranteed.

## Mitigation Strategies

If Spot reclamation becomes a real problem (e.g., demo day):

1. **Switch to On-Demand for the demo window** by editing the EKS
   tfvars and re-applying. ~15 min downtime to recreate node group.
2. **Use Spot but with `update_config.max_unavailable: 1`** (already set)
   to ensure node-by-node draining.
3. **Increase `node_max_size` to 4** before demo so EKS can pre-provision
   replacements faster.

## Validation

To be validated in Phase B:

1. Confirm both nodes come up Spot in EKS console (capacity-type label)
2. Observe reclamation behavior over 12-hour validation window
3. Document any actual reclamation events as an incident

## Related

- `infrastructure/terraform/eks/main.tf` — the node group definition
- `infrastructure/terraform/eks/README.md` — usage docs
- ADR-006: Multi-module Terraform structure
- ADR-007: Single NAT gateway (the other cost-optimization decision)
