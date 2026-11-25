variable "role_name" {
  description = "Name of the IAM role GitHub Actions assumes."
  type        = string
}

variable "github_repository" {
  description = "owner/repo allowed to assume the role (for example gkamta/govcloud-golden-ami-pipeline)."
  type        = string
}

variable "allowed_subjects" {
  description = "OIDC sub patterns (relative to repo:<owner/repo>:) allowed to assume the role."
  type        = list(string)
  default     = ["ref:refs/heads/main", "environment:dev", "environment:prod", "pull_request"]
}

variable "create_oidc_provider" {
  description = "Create the token.actions.githubusercontent.com IAM OIDC provider (once per account)."
  type        = bool
  default     = true
}

variable "packer_instance_role_arns" {
  description = "IAM role/instance-profile ARNs Packer may pass to the builder instance."
  type        = list(string)
  default     = []
}

variable "ssm_parameter_arns" {
  description = "SSM parameter ARNs the pipeline may update (/golden-ami/<os>/latest)."
  type        = list(string)
  default     = []
}

variable "artifacts_bucket_arn" {
  description = "S3 bucket ARN for scan reports and Packer logs."
  type        = string
  default     = null
}

variable "kms_key_arn" {
  description = "CMK used to encrypt AMIs, EBS, and artifacts."
  type        = string
  default     = null
}

variable "state_bucket_arn" {
  description = "Terraform state bucket ARN (for plan/apply)."
  type        = string
  default     = null
}

variable "lock_table_arn" {
  description = "Terraform lock table ARN (for plan/apply)."
  type        = string
  default     = null
}

variable "tags" {
  description = "Additional tags."
  type        = map(string)
  default     = {}
}
