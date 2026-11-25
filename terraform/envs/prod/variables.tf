variable "aws_region" {
  description = "AWS region. GovCloud default is us-gov-west-1; commercial fallback is typically us-west-2."
  type        = string
  default     = "us-gov-west-1"
}

variable "expected_partition" {
  description = "Guardrail: the partition this stack must deploy into (aws-us-gov for GovCloud, aws for commercial demo)."
  type        = string
  default     = "aws-us-gov"

  validation {
    condition     = contains(["aws", "aws-us-gov"], var.expected_partition)
    error_message = "expected_partition must be aws or aws-us-gov."
  }
}

variable "allowed_account_ids" {
  description = "Guardrail: refuse to run against any other AWS account."
  type        = list(string)
  default     = null
}

variable "environment" {
  description = "Environment name (dev or prod)."
  type        = string
}

variable "project" {
  description = "Project name used in resource names and tags."
  type        = string
  default     = "golden-ami"
}

variable "vpc_cidr" {
  description = "CIDR for the Packer build VPC."
  type        = string
}

variable "private_subnet_cidr" {
  description = "Private subnet CIDR for the Packer builder (and the demo fleet)."
  type        = string
}

variable "public_subnet_cidr" {
  description = "Public subnet CIDR used only when NAT is enabled."
  type        = string
}

variable "availability_zone" {
  description = "AZ for the build subnet."
  type        = string
}

variable "enable_nat_gateway" {
  description = "Create a NAT gateway so the builder can reach vendor update services."
  type        = bool
  default     = true
}

variable "artifacts_bucket_name" {
  description = "Globally unique S3 bucket name for scan reports."
  type        = string
}

variable "github_repository" {
  description = "owner/repo whose Actions workflows may assume the CI role."
  type        = string
  default     = "gkamta/govcloud-golden-ami-pipeline"
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub OIDC provider (set false if it already exists in the account)."
  type        = bool
  default     = true
}

variable "state_bucket_arn" {
  description = "Optional Terraform state bucket ARN to include in the CI role policy."
  type        = string
  default     = null
}

variable "lock_table_arn" {
  description = "Optional Terraform lock table ARN to include in the CI role policy."
  type        = string
  default     = null
}

variable "fallback_to_base_ami" {
  description = "If no golden AMI has been published yet, let the ASG use a vendor base AMI (dev convenience only)."
  type        = bool
  default     = false
}

variable "owner" {
  description = "Owner tag."
  type        = string
  default     = "gkamta"
}

variable "classification" {
  description = "Data classification tag (for example CUI)."
  type        = string
  default     = "CUI"
}

variable "extra_tags" {
  description = "Extra tags merged into the defaults."
  type        = map(string)
  default     = {}
}
