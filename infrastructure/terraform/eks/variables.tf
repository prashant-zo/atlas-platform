variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "environment" {
  description = "Environment tag"
  type        = string
  default     = "dev"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "atlas-eks-dev"
}

variable "kubernetes_version" {
  description = "Kubernetes version on eks for control plane"
  type        = string
  default     = "1.31"
}

variable "vpc_id" {
  description = "VPC ID where eks will live"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for worker nodes (one per AZs)"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for control plane ENIs"
  type        = list(string)
}

# Node group sizing

variable "node_instance_type" {
  description = "EC2 instance type for worker nodes"
  type        = string
  default     = "t3.large"
}

variable "node_desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 4
}

variable "node_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 3
}

variable "node_max_size" {
  description = "Maximum number of worker nodes (for scale tests)"
  type        = number
  default     = 6
}

variable "node_disk_size" {
  description = "Disk size in GB per worker node"
  type        = number
  default     = 20
}

# Cluster endpoint access

variable "endpoint_public_access" {
  description = "Allow API server access from the internet (needed for kubectl from my laptop)"
  type        = bool
  default     = true
}

variable "endpoint_private_access" {
  description = "Allow API server access from within the VPC"
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "List of CIDRs allowed to reach the public API endpoint. Lock this down in production."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
