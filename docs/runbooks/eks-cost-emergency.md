# Runbook — EKS Cost Emergency Response

When a billing alarm fires for Atlas's AWS account, this runbook gets you
from "alert email" to "verified $0 ongoing charges" in under 10 minutes.

**Audience:** Atlas operator (Prashant)
**Trigger:** Email from AWS via SNS topic `atlas-billing-alerts`
**Time to recover:** 5-10 minutes

## Severity Triage — Which Alarm Fired?

Match the alarm name to the response:

### `atlas-billing-warning-10` ($10 threshold)

Early warning. Something is running and starting to cost money.
Investigate but don't panic.

→ Go to "Investigate Running Resources" below.

### `atlas-billing-warning-30` ($30 threshold)

Mid-month flag. If you're not actively running a validation session,
something is running you forgot about.

→ Go to "Investigate Running Resources" below.

### `atlas-billing-yellow-50` ($50 threshold)

Yellow flag. Close to budget ceiling. If validation isn't actively
in progress, stop work and destroy.

→ Go to "Force Tear Down" below.

### `atlas-billing-ceiling-60` ($60 threshold)

Budget ceiling. Drop everything and destroy.

→ Go directly to "Force Tear Down" below.

## Investigate Running Resources

Run these queries to see what's actually running. Replace
ap-south-1 with your region if different.

```bash
# Switch to atlas profile if not already
export AWS_PROFILE=atlas
export AWS_REGION=ap-south-1

# Check EKS clusters in the region
aws eks list-clusters --region ap-south-1

# Check running EC2 instances (where worker nodes live)
aws ec2 describe-instances \
  --filters Name=instance-state-name,Values=running,pending \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,LaunchTime,Tags[?Key==`Name`].Value|[0]]' \
  --output table

# Check NAT gateways (THE most common forgotten expensive resource)
aws ec2 describe-nat-gateways \
  --filter Name=state,Values=available,pending \
  --query 'NatGateways[].[NatGatewayId,VpcId,SubnetId,State]' \
  --output table

# Check EBS volumes — orphaned volumes cost money too
aws ec2 describe-volumes \
  --filters Name=status,Values=available \
  --query 'Volumes[?Size>`5`].[VolumeId,Size,VolumeType,CreateTime]' \
  --output table

# Check Elastic IPs not attached to anything ($0.005/hr each)
aws ec2 describe-addresses \
  --query 'Addresses[?AssociationId==`null`].[AllocationId,PublicIp]' \
  --output table

# Check ELBs (Load Balancers) — created indirectly by Ingress resources
aws elbv2 describe-load-balancers \
  --query 'LoadBalancers[].[LoadBalancerName,Type,Scheme,CreatedTime]' \
  --output table
```

Three outcomes:

### Outcome A: Everything is empty / expected

The alarm fired but the resources are minor (e.g., the S3 bucket you
forgot from a prior project costing $0.40/month). Calculate the
total monthly cost. If under $20/month and you can't easily delete it,
note it and continue with Atlas work.

### Outcome B: Atlas resources are still running but expected

You're in the middle of a validation session. The alarm fired during
expected work. **This is fine.** Continue, but make sure `destroy.sh`
runs at session end.

### Outcome C: Atlas resources are running unexpectedly

You ran `bootstrap.sh` previously and forgot to destroy. This is
the actual emergency case.

→ Go to "Force Tear Down" below.

## Force Tear Down

The cleanest path: run the destroy script. The longest valid path
through the cluster is ~10 minutes.

```bash
cd "/Users/prashant/Documents/The Helios Project/DevOps/Project/atlas/infrastructure/terraform"

# Sanity check — verify Terraform can see the state
ls -la vpc/terraform.tfstate eks/terraform.tfstate iam-irsa/terraform.tfstate

# Run destroy (will prompt for "destroy atlas" confirmation)
./destroy.sh
```

The script destroys in reverse order:
1. IAM-IRSA (~30 sec)
2. EKS cluster (~8-10 min — control plane teardown is slow)
3. VPC (~2 min)

**Total time: ~10-15 minutes.** Don't interrupt mid-destroy.

### If destroy.sh fails partway

The most common failure: VPC won't destroy because an ALB or ENI
is still attached.

```bash
# Find any LoadBalancers still in your VPC
aws elbv2 describe-load-balancers \
  --query 'LoadBalancers[].[LoadBalancerName,LoadBalancerArn]' \
  --output table

# If any exist, delete them manually
aws elbv2 delete-load-balancer --load-balancer-arn <arn>

# Wait 60 seconds for the ALB to deprovision
sleep 60

# Retry destroy
./destroy.sh
```

### If destroy.sh fails completely

Manual destroy via Console as last resort:

1. AWS Console → EKS → Clusters → Delete `atlas-eks-dev`
2. Wait until status is "Deleting" → gone (10 min)
3. AWS Console → VPC → Your VPCs → Find `atlas-dev-vpc` → Delete
   - May need to manually delete NAT gateway first
   - May need to manually release Elastic IP
4. AWS Console → IAM → Roles → Delete:
   - `atlas-eks-dev-cluster-role`
   - `atlas-eks-dev-node-role`
   - `atlas-eks-dev-aws-lb-controller`
   - `atlas-eks-dev-external-secrets`

## Verify Clean State

After tear down:

```bash
# Should return: An error occurred (ResourceNotFoundException)
aws eks describe-cluster --name atlas-eks-dev 2>&1 | head -3

# Should return empty list
aws ec2 describe-nat-gateways \
  --filter Name=state,Values=available,pending \
  --query 'NatGateways[].NatGatewayId' \
  --output text

# Should return empty list
aws ec2 describe-instances \
  --filters Name=instance-state-name,Values=running,pending Name=tag:Project,Values=atlas \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text

# Should NOT show atlas-eks-dev
aws eks list-clusters --query 'clusters' --output text
```

All four commands should return empty or "not found."

## Check Today's Spend

```bash
aws ce get-cost-and-usage \
  --time-period Start=$(date -u +%Y-%m-%d),End=$(date -u +%Y-%m-%d -d "+1 day") \
  --granularity DAILY \
  --metrics UnblendedCost \
  --region us-east-1
```

This shows today's charges. After destroy, it should match the cost
incurred during the validation window. Wait 24 hours to see the
post-destroy day at $0.

## Update Billing Alarms If Needed

If you triggered the $60 alarm and want to raise the ceiling for a
specific validation window:

```bash
# Update ceiling to $80 temporarily (for one validation run)
aws cloudwatch put-metric-alarm \
  --alarm-name atlas-billing-ceiling-60 \
  --threshold 80 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --dimensions Name=Currency,Value=USD \
  --evaluation-periods 1 \
  --period 21600 \
  --metric-name EstimatedCharges \
  --namespace AWS/Billing \
  --statistic Maximum \
  --alarm-actions arn:aws:sns:us-east-1:816621202130:atlas-billing-alerts \
  --region us-east-1

# After the validation, restore to $60
aws cloudwatch put-metric-alarm \
  --alarm-name atlas-billing-ceiling-60 \
  --threshold 60 \
  # ... (same other args)
```

Don't raise the ceiling without a specific reason. The whole point of
having ceiling alarms is to catch runaway costs.

## Common Causes by Cost Pattern

If the alarm consistently fires earlier than expected, the cause is
usually one of:

| Pattern | Likely Cause |
|---------|--------------|
| Alarm fires within 1-2 hours of bootstrap | NAT gateway running 24/7 |
| Alarm fires within 1 day | EKS control plane + NAT both running |
| Alarm fires within hours of "destroyed" | Orphaned ALB or ENI; manual cleanup needed |
| Charges in services unrelated to Atlas | Old project's resources; investigate by service |

## Pattern Worth Remembering

**Destroy is cheap; forgotten resources are expensive.**

A 30-second `destroy.sh` at the end of every session is cheaper than
a $30 surprise bill from forgetting a NAT gateway for two weeks.

The bootstrap/destroy cycle was designed for exactly this discipline:
both scripts complete in under 20 minutes. There's no friction to
the "destroy at end of session" workflow.

## Related

- `infrastructure/terraform/destroy.sh` — the teardown script
- `infrastructure/terraform/bootstrap.sh` — the recreation script
- `docs/learning/week-6-eks/aws-account-hardening.md` — alarm setup
- `docs/learning/week-6-eks/cost-discipline-for-eks-validation.md` — cost rules
