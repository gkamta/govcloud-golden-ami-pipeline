variable "name" {
  description = "Name prefix for the launch template and Auto Scaling group."
  type        = string
}

variable "os" {
  description = "OS tag to match on the golden AMI (rhel9 or windows2022)."
  type        = string
}

variable "environment" {
  description = "Environment tag the golden AMI must carry (dev or prod)."
  type        = string
}

variable "ami_id" {
  description = "Optional explicit AMI ID. When null, the module looks up the latest tagged golden AMI."
  type        = string
  default     = null
}

variable "ami_owners" {
  description = "Account IDs considered owners of the golden AMI (usually this account)."
  type        = list(string)
  default     = ["self"]
}

variable "fallback_to_base_ami" {
  description = "If no golden AMI exists yet, fall back to a vendor base AMI so the stack can still be planned in dev."
  type        = bool
  default     = false
}

variable "fallback_ami_owners" {
  description = "Owners used for the optional vendor base-AMI fallback."
  type        = list(string)
  default     = ["amazon"]
}

variable "fallback_ami_name_filter" {
  description = "Name filter for the optional vendor base-AMI fallback."
  type        = string
  default     = "RHEL-9*_HVM-*-x86_64-*"
}

variable "instance_type" {
  description = "Instance type for the fleet."
  type        = string
  default     = "t3.medium"
}

variable "instance_profile_name" {
  description = "Instance profile attached to fleet instances (SSM)."
  type        = string
}

variable "security_group_ids" {
  description = "Security groups for fleet instances."
  type        = list(string)
}

variable "subnet_ids" {
  description = "Private subnet IDs for the Auto Scaling group."
  type        = list(string)
}

variable "kms_key_arn" {
  description = "CMK ARN for the root EBS volume."
  type        = string
}

variable "root_device_name" {
  description = "Root device name (xvda on RHEL, /dev/sda1 on Windows)."
  type        = string
  default     = "/dev/xvda"
}

variable "root_volume_size" {
  description = "Root volume size in GiB."
  type        = number
  default     = 30
}

variable "user_data_base64" {
  description = "Optional base64 user data. Leave null to use the AMI's first-boot defaults."
  type        = string
  default     = null
}

variable "min_size" {
  description = "ASG minimum size."
  type        = number
  default     = 1
}

variable "max_size" {
  description = "ASG maximum size."
  type        = number
  default     = 2
}

variable "desired_capacity" {
  description = "ASG desired capacity."
  type        = number
  default     = 1
}

variable "health_check_grace_period" {
  description = "Seconds to wait before a new instance is considered unhealthy."
  type        = number
  default     = 300
}

variable "refresh_min_healthy_percentage" {
  description = "Minimum healthy percentage during an instance refresh."
  type        = number
  default     = 90
}

variable "refresh_instance_warmup" {
  description = "Instance warmup seconds during an instance refresh."
  type        = number
  default     = 300
}

variable "tags" {
  description = "Additional tags."
  type        = map(string)
  default     = {}
}
