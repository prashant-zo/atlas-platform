# Atlas — Terraform Infrastructure

Three modules + two orchestration scripts. Together they create a complete
EKS environment in ap-south-1 ready to host Atlas workloads.

## Layout

infrastructure/terraform/
├── vpc/             # Base network (VPC, subnets, NAT)
├── eks/             # Managed K8s cluster + node group
├── iam-irsa/        # Per-workload IAM roles via OIDC
├── bootstrap.sh     # Apply all three in dependency order
└── destroy.sh       # Tear all three down in reverse

## Quick Start

```bash
# Apply everything (~15-20 min, prompts for confirmation)
./bootstrap.sh

# Use the cluster
kubectl --context atlas-eks-dev get nodes

# When done — destroys everything (~10 min, prompts for confirmation)
./destroy.sh
```

## What Bootstrap Does

1. Pre-flight: checks `terraform`, `aws`, `jq` installed; verifies AWS auth as non-root
2. Confirmation: prompts for typed `apply` before any AWS resources created
3. Applies VPC → saves outputs to `/tmp/atlas-vpc-outputs.json`
4. Wires VPC outputs into `eks/terraform.tfvars`
5. Applies EKS (~12-15 min) → saves outputs to `/tmp/atlas-eks-outputs.json`
6. Wires EKS outputs into `iam-irsa/terraform.tfvars`
7. Applies IAM-IRSA (~30 sec)
8. Configures kubectl with `aws eks update-kubeconfig`

## What Destroy Does

Reverse order: iam-irsa → eks → vpc. Requires typed `destroy atlas` confirmation.
After teardown, verifies no Atlas-tagged EC2 instances or NAT gateways remain.

## Costs

| Phase | Time | Cost |
|-------|------|------|
| Writing modules (planning only) | hours | $0 |
| Bootstrap (apply) | 15-20 min | ~$0.05 |
| Cluster running | per hour | ~$0.20 |
| Destroy | 10 min | $0 |

**Daily cost if forgotten: ~$5.** Monthly: ~$144. Always destroy after sessions.

### Cost Breakdown (Running)

- EKS control plane:    $0.10/hr ($73/month — billed even when idle)
- 2× t3.large Spot:     ~$0.05/hr combined
- 2× 20GB EBS gp3:      ~$0.005/hr
- NAT Gateway:          $0.045/hr ($32/month — even with zero traffic)

NAT and EKS control plane are the dominant ongoing costs. Both are eliminated
by `destroy.sh`.

## State Files

Each module keeps state locally in its directory:
- `vpc/terraform.tfstate`
- `eks/terraform.tfstate`
- `iam-irsa/terraform.tfstate`

State files contain resource IDs and sensitive data — they are gitignored.
**Don't commit them. Don't share them.**

For production, state should live in S3 with DynamoDB locking. Atlas keeps
it local because the validation lifecycle is short (apply → demo → destroy).

## Outputs Cached At

- `/tmp/atlas-vpc-outputs.json`  (after VPC apply)
- `/tmp/atlas-eks-outputs.json`  (after EKS apply)

These survive across sessions but are recreated on each bootstrap run.
Inspect them with `cat /tmp/atlas-vpc-outputs.json | jq`.

## Troubleshooting

### Bootstrap fails partway through

Each module is applied independently. If EKS fails, the VPC stays applied.
Investigate the EKS error, then re-run `./bootstrap.sh` — it skips already-applied
resources and resumes.

### Destroy fails with "DependencyViolation"

Usually means a Kubernetes LoadBalancer (ALB) is still attached to a VPC subnet.
EKS doesn't auto-clean these on destroy. Fix:

```bash
kubectl --context atlas-eks-dev delete service --all --all-namespaces
# Wait 2-3 minutes for ALBs to deprovision
./destroy.sh
```

### "AccessDenied" during apply

`aws sts get-caller-identity` should show `user/atlas-admin`. If it shows root
or another user, fix your `~/.aws/credentials` or `AWS_PROFILE` env var.

### EKS apply takes a really long time

Control plane creation takes 8-10 minutes. Node group takes another 3-5 minutes.
The bootstrap script's "12-15 min" estimate is normal. If it's stuck past 20 min,
check EKS console for the cluster's status — it may have failed silently.

## Related

- `vpc/README.md`       — VPC module details
- `eks/README.md`       — EKS module details
- `iam-irsa/README.md`  — IAM-IRSA module details
- `../../docs/runbooks/` — operational procedures for the deployed cluster
