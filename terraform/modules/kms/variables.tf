variable "alias" {
  description = "KMS alias name without the alias/ prefix."
  type        = string
}

variable "description" {
  description = "Human-readable key description."
  type        = string
  default     = "Golden AMI, EBS, and artifacts encryption"
}

variable "region" {
  description = "Region, used in kms:ViaService conditions. Must match the provider region."
  type        = string
}

variable "key_user_arns" {
  description = "IAM principal ARNs allowed to use the key (CI role, builder instance role)."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Additional tags."
  type        = map(string)
  default     = {}
}
