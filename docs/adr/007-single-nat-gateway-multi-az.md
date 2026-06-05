# ADR-007: Single NAT Gateway with Multi-AZ Subnets

**Date:** 2026-06-03
**Status:** Accepted
**Context:** Week 6 — VPC Module Design

## Context

The VPC module (Task 6.1) creates the network layer for Atlas's EKS cluster.
A key decision is how many NAT gateways to provision.

NAT gateway pricing in ap-south-1:

- **$0.045/hour** per NAT ($32/month, $390/year)
- **$0.045/GB** for outbound data (negligible for Atlas's traffic)

EKS recommends 3 availability zones for high availability:
- Spreads worker nodes across AZ failures
- Control plane ENIs in 3 subnets means API server stays reachable

These are independent decisions: subnet AZ count vs NAT gateway count.

## Options Considered

### Option 1: Per-AZ NAT Gateway (production HA pattern)

One NAT gateway per AZ (3 NATs for 3-AZ deployment). Each AZ's private
subnet routes through its own NAT.

**Pros:**
- AZ failure does not affect outbound internet from surviving AZs
- Standard "production" pattern documented in AWS architecture guides
- Default in most Terraform AWS VPC modules (terraform-aws-modules/vpc/aws)

**Cons:**
- 3 × $32 = $96/month for NATs alone
- Three NAT gateways is overkill for a single-region, single-environment
  validation project

### Option 2: Single NAT Gateway (cost-optimized)

One NAT gateway in one AZ. All private subnets across all AZs route
through this one NAT.

**Pros:**
- $32/month total NAT cost (vs $96)
- 67% cost savings on the dominant ongoing AWS cost (after EKS control plane)
- Atlas's "destroy when done" lifecycle minimizes blast radius

**Cons:**
- If the NAT's AZ fails, private subnets in OTHER AZs lose outbound internet
  (pulls from ECR, calls to AWS APIs, internet-accessible endpoints)
- Cluster API server and inbound LB traffic still work
- Compromises the HA story of multi-AZ subnets

### Option 3: Single-AZ deployment (max cost cut)

Only deploy in one AZ. One NAT, one subnet, no HA pretense.

**Pros:**
- Cheapest possible deployment
- Simplest network topology

**Cons:**
- EKS strongly recommends 3 AZs for the control plane
- Worker nodes in a single AZ have no resilience to AZ failure
- Demonstrates worse engineering judgement than necessary

## Decision

Use **3 AZs for subnets, single NAT gateway** in ap-south-1a.

Layout:

ap-south-1
└── VPC 10.0.0.0/16
├── ap-south-1a
│   ├── Public subnet  10.0.0.0/24
│   ├── Private subnet 10.0.10.0/24
│   └── NAT Gateway (THE one)
├── ap-south-1b
│   ├── Public subnet  10.0.1.0/24
│   └── Private subnet 10.0.11.0/24
└── ap-south-1c
├── Public subnet  10.0.2.0/24
└── Private subnet 10.0.12.0/24

All three private subnets route their `0.0.0.0/0` traffic to the NAT in
ap-south-1a via a single shared route table.

## Consequences

### Positive

- **NAT cost reduced by 67%.** Single $0.045/hr instead of $0.135/hr.
  For a 12-hour validation: $0.54 vs $1.62. Annual rate: $390 vs $1,170.
- **Multi-AZ subnet topology preserved.** EKS still has 3 AZs for worker
  scheduling and control plane HA — the resilience that matters most.
- **One fewer Elastic IP needed.** EIPs are free when attached, but having
  fewer of them is one less thing to track.
- **Single route table for private subnets.** Simpler to reason about.

### Negative

- **Single point of failure for outbound internet.** If ap-south-1a has a
  full AZ outage, workers in 1b and 1c cannot:
  - Pull new images from ECR (cached images still work)
  - Reach AWS APIs that go through the public endpoint (most do)
  - Reach external HTTP services
- **Cluster stays UP, but degraded.** Inbound traffic via ALB works.
  Existing pods keep running. Only outbound from private subnets fails.
- **Not production-ready as-is.** A real production deployment would either
  use per-AZ NATs OR move to a more sophisticated egress design
  (VPC endpoints for AWS services, transit gateway, etc.).

### Neutral

- **Documented as a known tradeoff.** Anyone reading the VPC module's
  `README.md` sees the single-NAT design with cost reasoning. The decision
  is explicit, not accidental.
- **Easy to change.** Converting to per-AZ NAT requires duplicating
  `aws_eip.nat`, `aws_nat_gateway.main`, and the private route table
  to use `count = local.az_count`. ~30 minutes of work if requirements change.

## Risk Acceptance

We accept the single-AZ NAT risk for Atlas because:

1. **Validation environment, not production.** Atlas runs for a focused
   weekend session, then is destroyed. The probability of an AZ outage
   during that window is low.
2. **Cost-optimization is the explicit goal.** Atlas's value as a
   portfolio piece comes from cost discipline as much as from the
   tech stack. Spending $90+/month on NAT alone for a learning project
   demonstrates worse judgment than spending $32.
3. **The risk is bounded and known.** The cluster doesn't disappear
   if NAT-AZ fails. Inbound traffic still works. Worst case is a
   degraded period until Atlas operator (you) responds.

## Related

- `infrastructure/terraform/vpc/main.tf` — the NAT gateway resource
- `infrastructure/terraform/vpc/README.md` — usage docs noting this tradeoff
- ADR-006: Multi-module Terraform structure
