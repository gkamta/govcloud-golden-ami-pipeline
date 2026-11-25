# ---------------------------------------------------------------------------
# Environment root: wires KMS, Packer build infra, GitHub OIDC, AMI
# lifecycle pointers, and a launch-template / ASG fleet per OS.
# ---------------------------------------------------------------------------
data "aws_partition" "current" {}

locals {
  name = "${var.project}-${var.environment}"
  tags = merge({
    Project        = var.project
    Environment    = var.environment
    Owner          = var.owner
    ManagedBy      = "terraform"
    Classification = var.classification
    Repository     = var.github_repository
  }, var.extra_tags)
}

# Guardrail: fail the plan if credentials point at the wrong partition
# (for example commercial creds used against a GovCloud stack).
check "partition_guardrail" {
  assert {
    condition     = data.aws_partition.current.partition == var.expected_partition
    error_message = "Credentials resolve to partition ${data.aws_partition.current.partition}, expected ${var.expected_partition}."
  }
}

module "kms" {
  source = "../../modules/kms"

  alias  = "${local.name}-golden-ami"
  region = var.aws_region
  tags   = local.tags
}

module "packer_build" {
  source = "../../modules/packer-build-infra"

  name                  = local.name
  vpc_cidr              = var.vpc_cidr
  private_subnet_cidr   = var.private_subnet_cidr
  public_subnet_cidr    = var.public_subnet_cidr
  availability_zone     = var.availability_zone
  enable_nat_gateway    = var.enable_nat_gateway
  kms_key_arn           = module.kms.key_arn
  artifacts_bucket_name = var.artifacts_bucket_name
  tags                  = local.tags
}

module "ami_lifecycle" {
  source = "../../modules/ami-lifecycle"

  environment = var.environment
  operating_systems = {
    rhel9 = {
      initial_ami_id = "pending"
    }
    windows2022 = {
      initial_ami_id = "pending"
    }
  }
  deprecate_after_days = 60
  tags                 = local.tags
}

module "github_oidc" {
  source = "../../modules/iam-oidc"

  role_name                 = "${local.name}-github-actions"
  github_repository         = var.github_repository
  create_oidc_provider      = var.create_github_oidc_provider
  packer_instance_role_arns = [module.packer_build.builder_role_arn]
  ssm_parameter_arns        = values(module.ami_lifecycle.parameter_arns)
  artifacts_bucket_arn      = module.packer_build.artifacts_bucket_arn
  kms_key_arn               = module.kms.key_arn
  state_bucket_arn          = var.state_bucket_arn
  lock_table_arn            = var.lock_table_arn
  tags                      = local.tags
}

# Fleet security group: no inbound, SSM egress via VPC endpoints (same pattern as the builder).
resource "aws_security_group" "fleet" {
  # checkov:skip=CKV2_AWS_5:Attached to the Auto Scaling groups in launch-template-asg.
  name        = "${local.name}-fleet"
  description = "Golden-AMI fleet - no inbound; SSM Session Manager only"
  vpc_id      = module.packer_build.vpc_id
  tags        = merge(local.tags, { Name = "${local.name}-fleet" })
}

resource "aws_security_group_rule" "fleet_egress_vpc" {
  type              = "egress"
  security_group_id = aws_security_group.fleet.id
  description       = "HTTPS to VPC endpoints"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
}

module "fleet_rhel9" {
  source = "../../modules/launch-template-asg"

  name                     = "${local.name}-rhel9"
  os                       = "rhel9"
  environment              = var.environment
  fallback_to_base_ami     = var.fallback_to_base_ami
  fallback_ami_owners      = ["amazon", "309956199498"]
  fallback_ami_name_filter = "RHEL-9*_HVM-*-x86_64-*"
  instance_type            = var.rhel9_instance_type
  min_size                 = var.asg_min_size
  max_size                 = var.asg_max_size
  desired_capacity         = var.asg_desired_capacity
  instance_profile_name    = module.packer_build.instance_profile_name
  security_group_ids       = [aws_security_group.fleet.id]
  subnet_ids               = [module.packer_build.subnet_id]
  kms_key_arn              = module.kms.key_arn
  root_device_name         = "/dev/xvda"
  root_volume_size         = 30
  tags                     = local.tags
}

module "fleet_windows2022" {
  source = "../../modules/launch-template-asg"

  name                     = "${local.name}-windows2022"
  os                       = "windows2022"
  environment              = var.environment
  fallback_to_base_ami     = var.fallback_to_base_ami
  fallback_ami_owners      = ["amazon"]
  fallback_ami_name_filter = "Windows_Server-2022-English-Full-Base-*"
  instance_type            = var.windows_instance_type
  min_size                 = var.asg_min_size
  max_size                 = var.asg_max_size
  desired_capacity         = var.asg_desired_capacity
  instance_profile_name    = module.packer_build.instance_profile_name
  security_group_ids       = [aws_security_group.fleet.id]
  subnet_ids               = [module.packer_build.subnet_id]
  kms_key_arn              = module.kms.key_arn
  root_device_name         = "/dev/sda1"
  root_volume_size         = 50
  tags                     = local.tags
}
