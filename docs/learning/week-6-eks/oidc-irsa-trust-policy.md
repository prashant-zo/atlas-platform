# OIDC and IRSA Trust Policy Mechanics

IRSA (IAM Roles for Service Accounts) is how Atlas's workloads get
AWS permissions in EKS. The mechanics are subtle. This document captures
how it actually works.

## The Problem IRSA Solves

In a standard EKS cluster without IRSA, all pods on a worker node share
the same IAM role (the node IAM role). This means:

- `external-secrets` controller needs Secrets Manager read access
- `cluster-autoscaler` needs EC2 modify access
- Your `backend` app has no business touching either

Without IRSA, you either:
- Give the node role both permissions (overly broad — backend can now
  read secrets and modify EC2)
- Don't deploy those controllers at all

IRSA gives each Kubernetes ServiceAccount its own IAM role.

## How It Works (The Flow)

1. **Pod starts** with ServiceAccount `external-secrets` in namespace
   `external-secrets`

2. **EKS injects an OIDC token** into the pod at
   `/var/run/secrets/eks.amazonaws.com/serviceaccount/token`

3. **The AWS SDK** in the pod sees this token (via env var
   `AWS_WEB_IDENTITY_TOKEN_FILE`)

4. **The SDK calls STS** `AssumeRoleWithWebIdentity`, presenting:
   - The OIDC token
   - The IAM role ARN to assume

5. **AWS STS validates the token signature** against the OIDC provider's
   thumbprint stored in IAM

6. **AWS STS checks the IAM role's trust policy** — does it allow
   THIS ServiceAccount from THIS namespace to assume the role?

7. **If yes**, STS returns temporary credentials (1-hour default TTL)

8. **The pod uses these credentials** to call AWS APIs

## The Trust Policy

This is where the magic happens, and where bugs hide.

```hcl
resource "aws_iam_role" "external_secrets" {
  name = "atlas-eks-dev-external-secrets"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_url_stripped}:aud" = "sts.amazonaws.com"
          "${local.oidc_url_stripped}:sub" = "system:serviceaccount:external-secrets:external-secrets"
        }
      }
    }]
  })
}
```

Three things matter:

### `Federated`

The ARN of the OIDC provider for the cluster. AWS uses this to know
which OIDC issuer (i.e., which EKS cluster) the token must come from.

If wrong: trust fails. Pods from a different cluster can't assume
this role.

### `:aud` condition

`aud` (audience) must equal `sts.amazonaws.com`. This is the constant
audience for AWS STS, hardcoded into AWS SDKs.

If wrong: trust fails.

### `:sub` condition

`sub` (subject) is THE critical field. Format:

system:serviceaccount:<namespace>:<serviceaccount-name>

This is the ONLY field that determines which specific Kubernetes
ServiceAccount can assume the role.

If wrong (typo in namespace, typo in name, wrong colons): trust fails
silently. The pod gets `AccessDenied` when it tries to use AWS APIs.

## Why "Silently" is the Worst Failure Mode

Pod boots normally. Kubernetes sees nothing wrong. Pod's logs say
"failed to read secret: AccessDenied: arn:aws:sts::ACCOUNT:assumed-role/...
is not authorized."

You go check:
- Is the role correctly attached? Yes
- Is the policy attached to the role? Yes
- Did the SA get the annotation? Yes
- Does the policy have the permissions? Yes

The problem is in the trust policy's `:sub` claim. Comparing the
expected vs actual ServiceAccount string is the only fix.

## Prevention: Naming Convention

For Atlas, every IRSA role's trust policy uses:
https://oidc.eks.ap-south-1.amazonaws.com/id/A1B2C3D4E5F6

The IAM trust policy expects it WITHOUT prefix:
oidc.eks.ap-south-1.amazonaws.com/id/A1B2C3D4E5F6

Atlas handles this with a Terraform local:

```hcl
locals {
  oidc_url_stripped = replace(var.oidc_provider_url, "https://", "")
}
```

Then references `local.oidc_url_stripped` in the trust policy.

If you forget this strip, the trust condition silently doesn't match.
Same `AccessDenied` failure mode as a typo.

## Pattern Worth Remembering

When debugging an IAM/IRSA AccessDenied:

1. **First, check the trust policy.** Use `aws iam get-role --role-name X`
   and look at the `:sub` condition. Compare character-by-character
   with the actual SA's namespace and name.

2. **Second, check the permission policy.** Make sure the actions and
   resources match what the pod is trying to do.

3. **Third, check the OIDC provider.** Is it the same one referenced
   in the trust policy?

90% of IRSA bugs are step 1.

## Validation in Phase B

The trust policies will be validated during Phase B:

- Load Balancer Controller pod should be able to call EC2/ELB APIs
- External Secrets pod should be able to call Secrets Manager
- A failed assume-role should be visible in CloudTrail

Any AccessDenied errors trace back to one of: trust policy typo,
permission policy gap, or OIDC provider mismatch.

## Related

- `infrastructure/terraform/iam-irsa/load-balancer-controller.tf` — LB controller IRSA
- `infrastructure/terraform/iam-irsa/external-secrets.tf` — External Secrets IRSA
- `infrastructure/terraform/iam-irsa/README.md` — module overview
- `infrastructure/terraform/eks/main.tf` — OIDC provider creation
