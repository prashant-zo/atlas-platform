# Atlas VPC Module

Base VPC for Atlas EKS workloads in ap-south-1.

## What This Creates

- 1 VPC with CIDR `10.0.0.0/16`
- 3 public subnets, one per AZ (for ALBs, NAT gateway)
- 3 private subnets, one per AZ (for EKS worker nodes)
- 1 Internet Gateway
- **1 NAT Gateway** in ap-south-1a (cost-optimized; not one per AZ)
- 1 public + 1 private route table, with appropriate associations
- 1 Elastic IP for the NAT Gateway

## Cost Per Hour When Applied

| Resource | Cost |
|----------|------|
| VPC, subnets, IGW, route tables | Free |
| NAT Gateway | $0.045/hr |
| Elastic IP (while attached to NAT) | Free |
| Data through NAT | $0.045/GB |

**Estimated cost: ~$0.05/hour, ~$1.20/day, ~$32/month**

This is the dominant cost of having Atlas's infrastructure provisioned but idle. Always `terraform destroy` after a validation session.

## Tradeoffs

**Single NAT Gateway** — chosen for cost. If ap-south-1a fails, private subnets in 1b/1c lose outbound internet (cluster stays up, inbound LB traffic works). Production would use one NAT per AZ.

## Usage

```bash
cd infrastructure/terraform/vpc

# First time
terraform init

# See what would be created (free, no AWS resources)
terraform plan

# Create the resources (costs begin once applied)
terraform apply

# Destroy when done
terraform destroy
```

## Inputs

| Variable | Description | Default |
|----------|-------------|---------|
| `region` | AWS region | `ap-south-1` |
| `environment` | Environment tag | `dev` |
| `vpc_cidr` | VPC CIDR block | `10.0.0.0/16` |
| `availability_zones` | List of AZs | All 3 in ap-south-1 |
| `public_subnet_cidrs` | Public subnet CIDRs | `10.0.0.0/24` × 3 |
| `private_subnet_cidrs` | Private subnet CIDRs | `10.0.10.0/24` × 3 |
| `cluster_name` | EKS cluster name (used in subnet tags) | `atlas-eks-dev` |

## Outputs

| Output | Used By |
|--------|---------|
| `vpc_id` | EKS module |
| `public_subnet_ids` | EKS module (control plane ENIs, public LBs) |
| `private_subnet_ids` | EKS module (worker nodes) |
| `nat_gateway_id` | Debugging reference |
| `internet_gateway_id` | Debugging reference |

## Related

- `../eks/` — depends on VPC outputs (next module)
- `../iam-irsa/` — service account IAM roles
- `../README.md` — overall infrastructure docs
