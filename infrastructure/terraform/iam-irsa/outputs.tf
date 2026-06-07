output "load_balancer_controller_role_arn" {
  description = "ARN of the IAM role for AWS Load Balancer Controller. Annotate the ServiceAccount with this."
  value       = aws_iam_role.load_balancer_controller.arn
}

output "external_secrets_role_arn" {
  description = "ARN of the IAM role for External Secrets Operator. Annotate the ServiceAccount with this."
  value       = aws_iam_role.external_secrets.arn
}

output "service_account_annotation_lb_controller" {
  description = "Annotation to apply to aws-load-balancer-controller ServiceAccount"
  value       = "eks.amazonaws.com/role-arn: ${aws_iam_role.load_balancer_controller.arn}"
}

output "service_account_annotation_external_secrets" {
  description = "Annotation to apply to external-secrets ServiceAccount"
  value       = "eks.amazonaws.com/role-arn: ${aws_iam_role.external_secrets.arn}"
}

output "ebs_csi_driver_role_arn" {
  description = "IAM role ARN for the EBS CSI driver controller (via IRSA)"
  value       = aws_iam_role.ebs_csi_driver.arn
}

output "service_account_annotation_ebs_csi_driver" {
  description = "Helm chart annotation pointing the CSI driver ServiceAccount at its IRSA role"
  value       = "eks.amazonaws.com/role-arn: ${aws_iam_role.ebs_csi_driver.arn}"
}
