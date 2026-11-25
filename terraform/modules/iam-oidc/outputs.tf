output "role_arn" {
  description = "Role ARN to set as the AWS_CI_ROLE_ARN GitHub variable."
  value       = aws_iam_role.ci.arn
}

output "role_name" {
  description = "Name of the CI role."
  value       = aws_iam_role.ci.name
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider (created or expected)."
  value       = local.provider_arn
}
