output "vpc_id" {
  description = "Packer build VPC ID (pass to Packer as vpc_id)."
  value       = aws_vpc.this.id
}

output "subnet_id" {
  description = "Private subnet ID for the Packer builder."
  value       = aws_subnet.private.id
}

output "builder_security_group_id" {
  description = "Security group with no inbound rules; use this in the Packer source."
  value       = aws_security_group.builder.id
}

output "instance_profile_name" {
  description = "Instance profile Packer should attach to the builder."
  value       = aws_iam_instance_profile.builder.name
}

output "builder_role_arn" {
  description = "Builder instance role ARN (for KMS key users and iam:PassRole)."
  value       = aws_iam_role.builder.arn
}

output "artifacts_bucket_name" {
  description = "Scan-artifact bucket name."
  value       = aws_s3_bucket.artifacts.id
}

output "artifacts_bucket_arn" {
  description = "Scan-artifact bucket ARN."
  value       = aws_s3_bucket.artifacts.arn
}
