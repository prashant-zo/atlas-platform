# IAM Role with trust policy locked to the specific ServiceAccount

resource "aws_iam_role" "load_balancer_controller" {
  name = "${var.cluster_name}-aws-lb-controller"

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
          "${local.oidc_url_stripped}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
        }
      }
    }]
  })

  tags = {
    Name      = "${var.cluster_name}-aws-lb-controller"
    Component = "aws-load-balancer-controller"
  }
}

# Permission policy — downloaded from AWS's official repo

resource "aws_iam_policy" "load_balancer_controller" {
  name        = "${var.cluster_name}-aws-lb-controller-policy"
  description = "Permissions for AWS Load Balancer Controller to manage ELBs"

  policy = file("${path.module}/aws-load-balancer-controller-policy.json")

  tags = {
    Component = "aws-load-balancer-controller"
  }
}

resource "aws_iam_role_policy_attachment" "load_balancer_controller" {
  role       = aws_iam_role.load_balancer_controller.name
  policy_arn = aws_iam_policy.load_balancer_controller.arn
}
