# Atlas IAM-IRSA Module

IAM Roles for Service Accounts (IRSA) — per-workload AWS permissions via OIDC.

## What IRSA Solves

Without IRSA, all pods on a worker node share the same AWS permissions (whatever's
on the node IAM role). This violates least-privilege: a compromised pod gets
node-level AWS access.

With IRSA, each Kubernetes ServiceAccount can assume its own IAM role via OIDC
token federation. Pods get only the AWS permissions their specific workload needs.

## What This Creates

| IAM Role | Used By | AWS Permissions |
|----------|---------|------------------|
| `atlas-eks-dev-aws-lb-controller` | `kube-system:aws-load-balancer-controller` | Manage ALBs, NLBs, Target Groups |
| `atlas-eks-dev-external-secrets` | `external-secrets:external-secrets` | Read Secrets Manager + SSM (prefix `atlas/`) |

## Cost When Applied

**$0/hour.** IAM roles and policies are free. Cost only accrues when the workloads
using these roles create AWS resources (e.g., Load Balancer Controller creating
ALBs at $0.025/hr each).

## Trust Policy Pattern

Each role's trust policy locks `sts:AssumeRoleWithWebIdentity` to a specific
ServiceAccount in a specific namespace:

"${oidc_url}:sub" = "system:serviceaccount:<namespace>:<sa-name>"

The `:sub` claim format is exact — typos here cause silent `AccessDenied` errors
when the pod calls AWS APIs.

## Permission Policy Pattern

Permissions are restricted by ARN prefix where possible. For example, External
Secrets can only read secrets under `atlas/*`, not arbitrary secrets:

"Resource": "arn:aws:secretsmanager:ap-south-1::secret:atlas/"

This is defense-in-depth: even if someone misuses the role, they can't reach
unrelated AWS resources.

## Usage

```bash
cd infrastructure/terraform/iam-irsa

# First time
terraform init

# After EKS module is applied, get its OIDC outputs
cd ../eks && terraform output -raw oidc_provider_arn
cd ../eks && terraform output -raw oidc_provider_url

# Update terraform.tfvars with the real ARN and URL, then:
terraform plan
terraform apply
```

After apply, get the role ARNs:

```bash
terraform output load_balancer_controller_role_arn
terraform output external_secrets_role_arn
```

Use these ARNs to annotate the corresponding Kubernetes ServiceAccounts:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aws-load-balancer-controller
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: <load_balancer_controller_role_arn>
```

## Related

- `../vpc/` — base network
- `../eks/` — required prerequisite (creates the OIDC provider)
- `../README.md` — overall infrastructure docs
- AWS Load Balancer Controller install guide:
  https://kubernetes-sigs.github.io/aws-load-balancer-controller/
- External Secrets Operator install guide:
  https://external-secrets.io/
