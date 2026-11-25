output "github_actions_role_arn" {
  description = "Set this as the AWS_CI_ROLE_ARN GitHub Actions variable."
  value       = module.github_oidc.role_arn
}

output "packer_vpc_id" {
  description = "VPC ID to pass to Packer."
  value       = module.packer_build.vpc_id
}

output "packer_subnet_id" {
  description = "Private subnet ID to pass to Packer."
  value       = module.packer_build.subnet_id
}

output "packer_security_group_id" {
  description = "No-inbound security group for the Packer builder."
  value       = module.packer_build.builder_security_group_id
}

output "packer_instance_profile" {
  description = "Instance profile name for the Packer builder."
  value       = module.packer_build.instance_profile_name
}

output "kms_key_arn" {
  description = "CMK used to encrypt AMIs, EBS, and artifacts."
  value       = module.kms.key_arn
}

output "artifacts_bucket" {
  description = "S3 bucket for OpenSCAP / Evaluate-STIG reports."
  value       = module.packer_build.artifacts_bucket_name
}

output "golden_ami_parameter_names" {
  description = "SSM parameters the bake pipeline updates after a successful scan gate."
  value       = module.ami_lifecycle.parameter_names
}

output "rhel9_asg_name" {
  description = "RHEL 9 Auto Scaling group that rolls forward on a new golden AMI."
  value       = module.fleet_rhel9.autoscaling_group_name
}

output "windows2022_asg_name" {
  description = "Windows Server 2022 Auto Scaling group that rolls forward on a new golden AMI."
  value       = module.fleet_windows2022.autoscaling_group_name
}

output "partition" {
  description = "AWS partition resolved by the provider (aws or aws-us-gov)."
  value       = data.aws_partition.current.partition
}
