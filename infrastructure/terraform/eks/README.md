# Atlas EKS Module

Managed Kubernetes cluster for Atlas workloads in ap-south-1.

## What This Creates

- 1 EKS cluster (managed control plane, K8s 1.31)
- 1 IAM role for the cluster + policy attachment
- 1 IAM role for nodes + 3 policy attachments
- 1 OIDC provider (for IRSA — service-account-level IAM)
- 1 managed node group with 2 desired worker nodes (max 4)
- Worker instances: t3.large on Spot (with t3a.large + t2.large fallbacks)

## Cost Per Hour When Applied

| Resource | Cost |
|----------|------|
| EKS control plane | $0.10/hr ($73/mo) |
| 2× t3.large Spot nodes | ~$0.05/hr ($36/mo) |
| 2× 20GB EBS gp3 volumes | ~$0.005/hr |
| **Total EKS** | **~$0.155/hr (~$112/mo)** |

Plus VPC's NAT gateway: ~$0.045/hr. **Total infrastructure: ~$0.20/hr (~$144/mo).**

**For a 12-hour validation: ~$2.40. Always destroy after the session.**

## Tradeoffs

**Pure Spot capacity** — saves ~70% over on-demand. Workers may be reclaimed
with 2-min warning; pods reschedule on remaining nodes. Acceptable for
validation, not for production-critical workloads. Change `capacity_type` in
main.tf to `ON_DEMAND` if guaranteed availability is needed.

**Public API endpoint** — open to `0.0.0.0/0` so kubectl works from your
laptop. In production, lock `public_access_cidrs` to your VPN's egress IP.

**Mixed AZ distribution** — node group spans all private subnets (one per AZ).
If a single AZ fails, the cluster keeps running on remaining nodes.

## Usage

```bash
cd infrastructure/terraform/eks

# First-time setup
terraform init

# After applying the VPC module, copy its outputs into terraform.tfvars
cd ../vpc && terraform output && cd ../eks
# Update vpc_id, public_subnet_ids, private_subnet_ids in terraform.tfvars

# Plan and apply
terraform plan
terraform apply

# Configure kubectl
aws eks update-kubeconfig --region ap-south-1 --name atlas-eks-dev
kubectl get nodes

# When done
terraform destroy
```

## Outputs Used Downstream

| Output | Used By |
|--------|---------|
| `cluster_name` | ArgoCD bootstrap, IRSA module |
| `cluster_endpoint` | kubeconfig |
| `oidc_provider_arn` | IRSA module |
| `oidc_provider_url` | IRSA module |
| `kubeconfig_command` | Manual kubectl setup |

## Related

- `../vpc/` — required prerequisite (network layer)
- `../iam-irsa/` — service-account-level IAM roles (Task 6.3)
- `../README.md` — overall infrastructure docs
