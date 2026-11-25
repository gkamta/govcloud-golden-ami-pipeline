variable "name" {
  description = "Name prefix for build-infra resources."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR for the Packer build VPC."
  type        = string
  default     = "10.50.0.0/16"
}

variable "private_subnet_cidr" {
  description = "Private subnet CIDR that hosts the Packer builder."
  type        = string
  default     = "10.50.1.0/24"
}

variable "public_subnet_cidr" {
  description = "Public subnet CIDR used only when NAT is enabled."
  type        = string
  default     = "10.50.0.0/24"
}

variable "availability_zone" {
  description = "AZ for the build subnets (single-AZ is enough for a bake VPC)."
  type        = string
}

variable "enable_nat_gateway" {
  description = "Create a NAT gateway so the builder can reach RHUI or Windows Update. Set false in a disconnected enclave."
  type        = bool
  default     = true
}

variable "interface_endpoint_services" {
  description = "Interface VPC endpoint service short names (com.amazonaws.<region>.<name>)."
  type        = list(string)
  default     = ["ssm", "ssmmessages", "ec2messages", "ec2", "sts", "kms", "logs"]
}

variable "kms_key_arn" {
  description = "CMK ARN for EBS, artifacts, and log-group encryption."
  type        = string
}

variable "artifacts_bucket_name" {
  description = "Globally unique S3 bucket name for scan reports and Packer manifests."
  type        = string
}

variable "artifact_expiration_days" {
  description = "Days to retain scan artifacts."
  type        = number
  default     = 90
}

variable "tags" {
  description = "Additional tags."
  type        = map(string)
  default     = {}
}
