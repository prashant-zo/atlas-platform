# EBS CSI Driver IRSA Role
#
# The aws-ebs-csi-driver controller pod needs permissions to call EC2 APIs
# (CreateVolume, AttachVolume, DetachVolume, DeleteVolume, etc.) to provision
# and manage EBS volumes for PVCs.

resource "aws_iam_role" "ebs_csi_driver" {
  name = "${var.cluster_name}-ebs-csi-driver"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_url_stripped}:aud" = "sts.amazonaws.com"
            "${local.oidc_url_stripped}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          }
        }
      }
    ]
  })

  tags = {
    Name      = "${var.cluster_name}-ebs-csi-driver"
    Component = "ebs-csi-driver"
  }
}

# AWS-managed policy with the exact permissions the EBS CSI driver needs.
resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  role       = aws_iam_role.ebs_csi_driver.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# EKS Managed Addon: AWS EBS CSI Driver
#
# Installs the CSI driver as an EKS-managed addon. AWS handles upgrades,
# patching, and lifecycle of the driver pods. Service account is bound
# to the IRSA role above.
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name             = var.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi_driver.arn

  # If addon already exists in the cluster, overwrite its config to match Terraform.
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = {
    Name      = "${var.cluster_name}-ebs-csi-driver"
    Component = "ebs-csi-driver"
  }

  depends_on = [
    aws_iam_role_policy_attachment.ebs_csi_driver
  ]
}
