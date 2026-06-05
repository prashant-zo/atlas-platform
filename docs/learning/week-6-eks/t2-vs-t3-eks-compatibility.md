# T2 vs T3 EKS Instance Compatibility

The EKS module's spot fallback list initially included `t2.large`. This
was caught and removed. The reasoning is worth recording.

## The Initial Mistake

The first draft of `eks/main.tf` had:

```hcl
capacity_type  = "SPOT"
instance_types = ["t3.large", "t3a.large", "t2.large"]
```

The intent was: "give AWS multiple instance type options for spot capacity."

The problem: t2 instances should not be used with current EKS AMIs.

## Why T2 is Problematic for EKS

### 1. Previous-generation hypervisor

T2 instances use Xen-based virtualization. T3 (and all "current generation"
instances) use the AWS Nitro hypervisor.

Nitro provides:
- Better network performance (up to 10 Gbps)
- Direct access to EBS via NVMe
- Hardware-accelerated security features
- Per-instance encryption

EKS AMIs are optimized for Nitro. They still technically run on T2,
but performance and storage behavior degrade.

### 2. CPU credit model differences

T2 has a "credit pool" — burst CPU above baseline depletes credits.
Out of credits = throttled to baseline.

T3 has "unlimited burst" by default — you can burst forever, paying
small additional charges if sustained.

For Kubernetes nodes running daemonsets, this matters:
- kube-proxy, CoreDNS, EKS-CNI add-on, container runtime all need CPU
- A daemonset burst (e.g., during a kubectl apply) can deplete T2 credits
- Once depleted, all pods on the node throttle simultaneously
- Other nodes look healthy; this one is just slow

### 3. EBS attachment via SCSI vs NVMe

T2: EBS volumes appear as SCSI devices (`/dev/sda`, `/dev/sdb`).
T3: EBS volumes appear as NVMe devices (`/dev/nvme0n1`).

EKS-optimized AMIs use udev rules expecting NVMe device names.
On T2, these rules don't match, and the EBS volumes don't get
the expected device mappings. The CSI driver works around this,
but with degraded performance.

### 4. Memory pressure differences

T2.large: 8 GB RAM, but with shared memory architecture
T3.large: 8 GB RAM with dedicated allocation

For pod density, T3 typically supports 10-15% more pods before
memory pressure kicks in.

## The Fix

Changed to:

```hcl
capacity_type  = "SPOT"
instance_types = ["t3.large", "t3a.large"]
```

Two instance types, both Nitro, both current generation:
- `t3.large` — Intel-based, $0.025/hr spot
- `t3a.large` — AMD-based, ~10% cheaper at $0.022/hr spot

Spot capacity is drawn from whichever pool has more availability,
reducing reclamation probability.

## Why This Wasn't Caught by `terraform validate`

`terraform validate` checks HCL syntax. It does not validate that
the instance types you specified will actually work with the AMI
that EKS will provision.

The failure would have happened at `terraform apply`:
- EKS provisions the node group
- AWS launches T2 instances
- Kubelet tries to join the cluster
- Node never becomes Ready, or becomes Ready but pods crash
- Debugging takes 30+ minutes

This is exactly the kind of bug that costs $5 of debugging time
during a $10 validation session.

## How This Was Caught

Manual review during transcription. The eye-test on "T2 alongside T3"
triggered a "wait, is that current?" check.

The lesson: instance types matter. AWS recommends t3+ for any current
EKS deployment. Older guides may still list T2 as an option.

## Prevention

When choosing instance types for EKS:
1. Use current-generation only (t3, m5, c5, r5, etc. — anything t3+)
2. Avoid previous-generation prefixes (t2, m4, c4, r4)
3. Prefer mixed-architecture lists (t3 + t3a) for spot capacity diversity
4. Document the choice in the module's README

## Related

- `infrastructure/terraform/eks/main.tf` — fixed instance_types
- `infrastructure/terraform/eks/README.md` — instance type rationale
- ADR-008: Spot-only node group
