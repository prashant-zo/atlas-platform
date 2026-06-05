# Terraform Variable Naming Consistency

A naming inconsistency caused silent failure during Week 6. This is the
postmortem and the prevention pattern.

## The Bug

The VPC module declared:

```hcl
variable "region" {
  default = "ap-south-1"
}
```

The EKS module declared:

```hcl
variable "aws_region" {
  default = "ap-south-1"
}
```

Same value, two different variable names across modules.

When `terraform.tfvars` was created for EKS, the value was placed under
`region` (matching the VPC convention by habit). Terraform validated this
as a warning, not an error:

Warning: Value for undeclared variable
The root module does not declare a variable named "region" but a value
was found in file "terraform.tfvars".

The actual `aws_region` variable used the default (`ap-south-1`), which
happened to match — so the bug had no observable behavior during plan.

## Why This Mattered

Two reasons it had to be fixed:

1. **Silent failure mode.** If the tfvars value had been different
   (say, `region = "us-east-1"` for testing), it would have been
   silently ignored. The plan would have run against `ap-south-1` (the
   default of `aws_region`), giving no indication that the intended
   region was different.

2. **Cross-module references break.** When the bootstrap script wires
   modules together, it does:
```bash
   terraform output -json | jq '.region.value'
```
   If the variable name varies between modules, the script needs
   conditional logic per module — fragile and error-prone.

## The Fix

Standardized on `region` (matching VPC, the older module). Changed in
4 files:

| File | Change |
|------|--------|
| `eks/variables.tf` | `variable "aws_region"` → `variable "region"` |
| `eks/versions.tf` | `region = var.aws_region` → `region = var.region` |
| `eks/outputs.tf` | `${var.aws_region}` → `${var.region}` |
| `eks/terraform.tfvars` | `aws_region = "..."` → `region = "..."` |

After fix:
- `terraform validate` clean (no warnings)
- `terraform plan` unchanged (still `Plan: 9 to add`)
- Cross-module bootstrap script works without per-module conditionals

## Why `region` Won Over `aws_region`

Looked at industry conventions:

- **terraform-aws-modules** (most-used Terraform registry): `region`
- **HashiCorp's own examples**: `region`
- **Multi-cloud projects**: `aws_region` (because they also need
  `gcp_region`, `azure_location`)

Atlas is single-cloud (AWS only). `region` is the idiomatic choice.

## Prevention Pattern

For any future Atlas module, the variable header is now:

```hcl
variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "environment" {
  description = "Environment tag (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "atlas-eks-dev"
}
```

These three variables appear in every module that needs them. Same name,
same description, same default. **Consistency over cleverness.**

## Pattern Worth Remembering

When adding a new module, the first step is to grep existing modules
for common variable names:

```bash
grep -rh "^variable" infrastructure/terraform/ | sort -u
```

This reveals the project's conventions immediately. Following them is
free; breaking them creates silent bugs.

## How This Was Caught

The Terraform warning was visible in `terraform init` and `terraform validate`
output. Easy to overlook in a long output stream, but explicit when looked at.

Reviewing the output after each `validate` is now part of the workflow.

## Related

- `infrastructure/terraform/eks/variables.tf` — fixed variable
- `infrastructure/terraform/vpc/variables.tf` — convention source
- ADR-006: Multi-module Terraform structure
