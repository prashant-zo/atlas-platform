# Cost Discipline for EKS Validation

EKS validation could easily cost $100+ if done casually. Atlas's
approach kept Week 6's writing phase at $0 and the apply phase under $10.
This document captures the discipline.

## The Cost Hierarchy

EKS costs from largest to smallest:

| Resource | Hourly | Monthly | Notes |
|----------|--------|---------|-------|
| EKS control plane | $0.10 | $73 | Fixed; runs even with zero workloads |
| NAT Gateway (×1) | $0.045 | $32 | Per gateway |
| t3.large worker (on-demand) | $0.090 | $66 | Per node |
| t3.large worker (spot) | $0.025 | $18 | Per node |
| EBS gp3 20GB | $0.005 | $4 | Per volume |
| Elastic IP (in use) | $0 | $0 | Free while attached |
| ALB (when created) | $0.025 | $18 | Per ALB; created by Ingresses |

Atlas's planned configuration:
- 1 control plane
- 1 NAT gateway
- 2 Spot t3.large nodes
- 2 EBS volumes
- ~$0.20/hour while running, ~$144/month if forgotten

## The Five Rules

### Rule 1: `terraform plan` is free. `terraform apply` is not.

This is the most important rule. Plan computes what would be created
without contacting AWS billing. It can be run hundreds of times for $0.

Apply creates real resources. Each minute of EKS uptime costs $0.0017
(at $0.10/hour for control plane alone).

Therefore: every Terraform change is plan'd dozens of times before
ever being applied. Bugs are caught at plan time, not apply time.

### Rule 2: `terraform destroy` at the end of every work session.

When you stop for the day, AWS resources are still costing money.
EKS control plane runs 24/7 even when no workloads exist. NAT gateway
runs 24/7 even with zero traffic.

If you stop work at 6pm and don't return until 10am the next day:
that's 16 hours × $0.20 = $3.20 burned on nothing.

The destroy script is one command. The bootstrap script recreates
everything in 20 minutes. **Always destroy.**

### Rule 3: Spot instances for non-stateful workloads.

Worker nodes can be Spot at 72% discount. Atlas's workloads tolerate
node reclamation:
- Stateless apps (backend, frontend) reschedule in seconds
- CNPG handles Postgres pod rescheduling correctly (tested in INC-002)

The savings: $0.05/hr vs $0.18/hr for two nodes. Over a 12-hour validation,
that's $0.55 vs $2.16. Small absolute, large percentage.

### Rule 4: Single NAT gateway, multi-AZ subnets.

Per-AZ NATs are the "best practice" pattern but cost 3× more.
For validation, one NAT is enough. The cluster stays up if the
NAT's AZ fails (inbound traffic still works).

Cost difference: $32/month vs $96/month. Documented as ADR-007.

### Rule 5: Maximum debug local, minimum debug on cloud.

This is the meta-rule. Every Terraform syntax error caught locally
saves an apply cycle. Every IRSA misconfiguration caught in
`terraform validate` saves $0.50 of cloud debugging.

The discipline:
- `terraform fmt` before commits
- `terraform validate` after every change
- `terraform plan` before every apply
- Read the plan output line by line, not just the summary
- Verify expected resource count matches actual

## Cost Tracking in Practice

### What the alarms are for

The four CloudWatch billing alarms ($10, $30, $50, $60) give
escalating warnings before Atlas hits its $60 monthly ceiling.

These should fire in order:
- $10 first (you've been running infra for ~50 hours total)
- $30 mid-month (something is running you didn't know about)
- $50 yellow flag (significant resources running; investigate)
- $60 ceiling (drop everything, destroy)

If you skip from $0 directly to $50, that's a sign of a forgotten
expensive resource (typically a NAT gateway, EKS cluster, or RDS
instance left running).

### What to check when an alarm fires

```bash
# What EC2 instances are running?
aws ec2 describe-instances \
  --filters Name=instance-state-name,Values=running,pending \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,Tags[?Key==`Name`].Value|[0]]' \
  --output table

# What EKS clusters exist?
aws eks list-clusters --region ap-south-1

# What NAT gateways exist?
aws ec2 describe-nat-gateways \
  --filter Name=state,Values=available,pending \
  --query 'NatGateways[].[NatGatewayId,VpcId,State]' \
  --output table

# What's the current month-to-date cost?
aws ce get-cost-and-usage \
  --time-period Start=$(date -u +%Y-%m-01),End=$(date -u +%Y-%m-%d) \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --region us-east-1
```

If any of these show unexpected resources: destroy them immediately
and figure out why later.

### What "$0 ongoing" looks like in the AWS console

After `destroy.sh` completes:

- **EC2 → Instances:** No running instances
- **VPC → NAT Gateways:** None or all "deleted" state
- **EKS → Clusters:** atlas-eks-dev gone
- **CloudWatch → Alarms:** Still showing OK (no new charges)
- **Billing → Cost Explorer:** Today's charges should be just the
  partial hour for whatever was running before destroy

Wait 24 hours, then verify Cost Explorer shows total < $5 for the day.
If it shows more, something didn't destroy cleanly.

## The Cost Story for Interviews

A senior engineer in an interview will probe cost discipline:

> "How did you keep this cheap?"

Atlas's answer:

1. "I separated the writing phase (free) from the apply phase (paid).
   The writing phase produced 33 AWS resources defined in code over
   4 sessions, $0 spent."

2. "For the apply phase, I optimized for Atlas's lifecycle: single NAT
   instead of per-AZ NAT saves $64/month. Spot instances save another
   $66/month. The cluster has 4 billing alerts spaced from $10 to $60."

3. "I wrote `bootstrap.sh` and `destroy.sh` as paired scripts so the
   cluster lifecycle is one command. The validation session ran for
   ~6 hours, cost $1.20 total, then destroyed cleanly to $0."

That's a believable, specific story that demonstrates understanding,
not theater.

## Related

- `docs/learning/week-6-eks/aws-account-hardening.md` — billing alert setup
- ADR-007: Single NAT gateway (cost decision)
- ADR-008: Spot-only node group (cost decision)
- `infrastructure/terraform/README.md` — destroy script
- `infrastructure/terraform/bootstrap.sh` — bootstrap script
