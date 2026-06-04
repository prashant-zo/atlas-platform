# Creates IAM roles that specific Kubernetes ServiceAccounts can assume
# via OIDC token federation. Each role has a trust policy that ONLY allows
# a specific ServiceAccount in a specific namespace to assume it.

locals {
  # Strip "https://" prefix from OIDC URL — IAM trust policies need bare hostname
  oidc_url_stripped = replace(var.oidc_provider_url, "https://", "")
}
