output "parameter_names" {
  description = "SSM parameter names, keyed by OS."
  value       = { for k, p in aws_ssm_parameter.latest : k => p.name }
}

output "parameter_arns" {
  description = "SSM parameter ARNs, keyed by OS (used by the CI role policy)."
  value       = { for k, p in aws_ssm_parameter.latest : k => p.arn }
}
