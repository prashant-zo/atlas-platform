# AWS Account Hardening for Atlas

The first hour of Week 6 was spent NOT on infrastructure code, but on
hardening the AWS account. This document captures what was set up and why
each piece matters.

## What Was Done

1. MFA on the root account
2. Created `atlas-admin` IAM user with `AdministratorAccess`
3. MFA on `atlas-admin`
4. Configured AWS CLI profile `atlas` with `atlas-admin` credentials
5. Enabled billing alerts at the account level
6. Created SNS topic + email subscription for billing notifications
7. Created 4 CloudWatch alarms: $10, $30, $50, $60 thresholds
8. Verified Terraform can authenticate as `atlas-admin` (no resources created)

Total time: ~45 minutes. Total spend: $0.

## Why Each Step Matters

### Why MFA on root

The root account is the AWS equivalent of `sudo` with unlimited power.
It can delete IAM users, disable billing, modify the root password,
and access every service in every region. Without MFA, root account
credentials are the single most attractive target on AWS.

Real consequence if compromised: an attacker spins up GPU instances
mining crypto, generating $50,000 bills in days. AWS doesn't reverse
these charges unless you can prove unauthorized access. MFA prevents
this entire class of disaster.

After enabling MFA, the root account should never be used for daily
work. Only for: billing changes, account recovery, IAM user rotation.

### Why an IAM user instead of root credentials

Terraform needs AWS credentials. The convenient (and wrong) choice
is to give it root keys. The correct choice is to create a dedicated
IAM user with the minimum permissions needed.

For Atlas, `atlas-admin` has `AdministratorAccess` (broad), which is
acceptable because:
- Atlas is a solo dev project, not a multi-team production environment
- The blast radius of `atlas-admin` is bounded by what we explicitly
  do via Terraform
- The user is MFA-protected; even if its access keys leak, attackers
  can't use them without the MFA token

In a real team, you'd narrow this further: separate roles for VPC
management, EKS management, billing access, etc.

### Why billing alerts before any infrastructure

Cost surprises are the #1 horror story for hobby cloud users:
"I forgot a NAT gateway running for 3 months and got a $300 bill."

The billing alerts created:

| Threshold | Purpose |
|-----------|---------|
| $10 | Early warning — something is running and starting to cost money |
| $30 | Mid-month check — investigate what's running |
| $50 | Yellow flag — getting close to budget ceiling |
| $60 | Ceiling — destroy everything immediately |

Atlas's monthly budget is $60. The four thresholds give 4 separate
chances to catch a runaway resource before it does serious damage.

### Why CloudWatch billing alerts must be in us-east-1

AWS publishes billing metrics ONLY to us-east-1 (N. Virginia),
regardless of where your resources are. The SNS topic and CloudWatch
alarms must be in us-east-1 even though Atlas's actual resources
are in ap-south-1.

This is an AWS quirk, not a design choice. The Terraform tag
`Project = "atlas"` on resources doesn't make the alarms region-aware;
the alarms just watch the global EstimatedCharges metric.

## Verification That Setup Worked

After completion, three commands proved the setup:

```bash
aws sts get-caller-identity
# Should show: arn:aws:iam::816621202130:user/atlas-admin
# NOT: arn:aws:iam::816621202130:root
```

```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix atlas-billing- \
  --region us-east-1 \
  --query 'MetricAlarms[].[AlarmName,Threshold,StateValue]' \
  --output table
# Should show 4 alarms, OK state once data flows
```

```bash
# Terraform reads AWS account info (no resources created)
terraform apply -auto-approve
# Output: account_id, user_arn (atlas-admin), region (ap-south-1)
```

## Pattern Worth Remembering

**Hardening before deployment, not after.**

It's tempting to skip account setup ("I'll add billing alerts later")
and dive into Terraform code. The cost of skipping is asymmetric:
the setup is free and takes an hour; a missing alert can cost
hundreds of dollars.

Atlas's first 45 minutes of Week 6 were spent making spending
mistakes impossible. That's correct prioritization.

## Related

- `docs/learning/week-6-eks/cost-discipline-for-eks-validation.md` —
  how cost discipline carried through the rest of Week 6
- ADR-006: Multi-module Terraform with bash orchestration
- ADR-007: Single NAT gateway (cost tradeoff decision)
- ADR-008: Spot-only node group (cost tradeoff decision)
