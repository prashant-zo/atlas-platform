variable "region" {
  description = "AWS regiom"
  type        = string
  default     = "ap-south-1"
}

variable "environment" {
  description = "Environment tag"
  type        = string
  default     = "dev"
}

variable "cluster_name" {
  description = "Name of the cluster (for naming roles)"
  type        = string
  default     = "atlas-eks-dev"
}

# These come from the EKS module's outputs.

variable "oidc_provider_arn" {
  description = "ARN of the EKS cluster's OIDC provider"
  type        = string
}

variable "oidc_provider_url" {
  description = "URL of the EKS cluster's OIDC issuer (without https:// prefix)"
  type        = string
}
