variable "operating_systems" {
  description = "Map of OS key (rhel9, windows2022) to an initial placeholder AMI ID. CI overwrites the value after each bake."
  type = map(object({
    initial_ami_id = string
  }))
}

variable "environment" {
  description = "Environment name stamped on the parameters."
  type        = string
}

variable "deprecate_after_days" {
  description = "If set, publish a policy parameter used by scripts/deprecate-old-amis.sh. Null skips it."
  type        = number
  default     = 60
}

variable "tags" {
  description = "Additional tags."
  type        = map(string)
  default     = {}
}
