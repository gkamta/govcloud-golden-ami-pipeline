# ---------------------------------------------------------------------------
# Packer amazon-ebs build for a STIG-hardened Windows Server 2022 golden AMI.
#
# Defaults target AWS GovCloud (us-gov-west-1 / aws-us-gov). The builder
# has no inbound security-group rules. User data installs OpenSSH Server
# so Packer can use SSM Session Manager (ssh_interface = "session_manager").
# Hardening is applied with PowerShell (scripts/windows-stig.ps1). The
# Ansible windows_stig role is the same content, usable over SSH or WinRM
# outside this bake. The image is generalized with EC2Launch v2 sysprep.
# ---------------------------------------------------------------------------

packer {
  required_version = ">= 1.10.0"
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = ">= 1.3.0, < 2.0.0"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-gov-west-1"
}

variable "aws_partition" {
  type    = string
  default = "aws-us-gov"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "project" {
  type    = string
  default = "golden-ami"
}

variable "vpc_id" {
  type    = string
  default = ""
}

variable "subnet_id" {
  type    = string
  default = ""
}

variable "security_group_id" {
  type    = string
  default = ""
}

variable "iam_instance_profile" {
  type        = string
  default     = "golden-ami-packer-builder"
  description = "Instance profile with AmazonSSMManagedInstanceCore (Terraform output packer_instance_profile)."
}

variable "kms_key_id" {
  type    = string
  default = ""
}

variable "source_ami" {
  type        = string
  default     = ""
  description = "Optional explicit source AMI. When empty, source_ami_filter is used."
}

variable "source_ami_owners" {
  type    = list(string)
  default = ["amazon"]
}

variable "source_ami_name_filter" {
  type    = string
  default = "Windows_Server-2022-English-Full-Base-*"
}

variable "instance_type" {
  type    = string
  default = "t3.large"
}

variable "ssh_username" {
  type    = string
  default = "Administrator"
}

variable "root_volume_size" {
  type    = number
  default = 50
}

variable "artifacts_bucket" {
  type    = string
  default = ""
}

locals {
  timestamp                 = regex_replace(timestamp(), "[- TZ:]", "")
  ami_name                  = "${var.project}-windows2022-${var.environment}-${local.timestamp}"
  source_ami_filter_enabled = var.source_ami == ""
}

source "amazon-ebs" "windows2022" {
  region          = var.aws_region
  instance_type   = var.instance_type
  ami_name        = local.ami_name
  ami_description = "STIG-hardened Windows Server 2022 golden AMI (${var.environment})"
  source_ami      = var.source_ami == "" ? null : var.source_ami
  user_data_file  = "${path.root}/../../scripts/windows-userdata.ps1"

  dynamic "source_ami_filter" {
    for_each = local.source_ami_filter_enabled ? [1] : []
    content {
      filters = {
        name                = var.source_ami_name_filter
        root-device-type    = "ebs"
        virtualization-type = "hvm"
        architecture        = "x86_64"
        state               = "available"
      }
      owners      = var.source_ami_owners
      most_recent = true
    }
  }

  vpc_id                      = var.vpc_id == "" ? null : var.vpc_id
  subnet_id                   = var.subnet_id == "" ? null : var.subnet_id
  security_group_id           = var.security_group_id == "" ? null : var.security_group_id
  iam_instance_profile        = var.iam_instance_profile
  associate_public_ip_address = false
  encrypt_boot                = true
  kms_key_id                  = var.kms_key_id == "" ? null : var.kms_key_id

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    delete_on_termination = true
    encrypted             = true
    kms_key_id            = var.kms_key_id == "" ? null : var.kms_key_id
  }

  communicator            = "ssh"
  ssh_username            = var.ssh_username
  ssh_interface           = "session_manager"
  ssh_timeout             = "30m"
  temporary_key_pair_type = "ed25519"

  tags = {
    Name        = local.ami_name
    GoldenAMI   = "true"
    OS          = "windows2022"
    Environment = var.environment
    Project     = var.project
    Partition   = var.aws_partition
    BuiltBy     = "packer"
  }

  run_tags = {
    Name        = "${local.ami_name}-builder"
    Role        = "packer-builder"
    OS          = "windows2022"
    Environment = var.environment
    Project     = var.project
  }
}

build {
  name    = "windows2022-golden"
  sources = ["source.amazon-ebs.windows2022"]

  provisioner "powershell" {
    script = "${path.root}/../../scripts/windows-stig.ps1"
  }

  provisioner "powershell" {
    script = "${path.root}/../../scripts/scan-windows-evaluate-stig.ps1"
  }

  provisioner "powershell" {
    inline = [
      "if ($env:ARTIFACTS_BUCKET) { aws s3 cp --recursive C:\\scan-artifacts s3://$env:ARTIFACTS_BUCKET/windows2022/${local.ami_name}/ }",
    ]
    environment_vars = [
      "ARTIFACTS_BUCKET=${var.artifacts_bucket}",
    ]
  }

  # Generalize with EC2Launch v2 and shut down so Packer can snapshot a
  # clean image. Do not add provisioners after this step.
  provisioner "powershell" {
    inline = [
      "& 'C:\\Program Files\\Amazon\\EC2Launch\\EC2Launch.exe' sysprep --shutdown true",
    ]
  }

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}
