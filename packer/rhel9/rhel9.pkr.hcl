# ---------------------------------------------------------------------------
# Packer amazon-ebs build for a STIG-hardened, FIPS-enabled RHEL 9 golden AMI.
#
# Defaults target AWS GovCloud (us-gov-west-1 / aws-us-gov). Override
# aws_region + aws_partition for a commercial demo account.
#
# The builder has no inbound security-group rules. Packer reaches it
# through SSM Session Manager (ssh_interface = "session_manager").
# ---------------------------------------------------------------------------

packer {
  required_version = ">= 1.10.0"
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = ">= 1.3.0, < 2.0.0"
    }
    ansible = {
      source  = "github.com/hashicorp/ansible"
      version = ">= 1.1.0, < 2.0.0"
    }
  }
}

variable "aws_region" {
  type        = string
  default     = "us-gov-west-1"
  description = "Region to bake in. Commercial fallback is typically us-west-2."
}

variable "aws_partition" {
  type        = string
  default     = "aws-us-gov"
  description = "Partition (aws-us-gov or aws). Informational; the region selects the endpoints."
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
  type        = string
  default     = ""
  description = "Packer build VPC (terraform output packer_vpc_id)."
}

variable "subnet_id" {
  type        = string
  default     = ""
  description = "Private subnet ID (terraform output packer_subnet_id)."
}

variable "security_group_id" {
  type        = string
  default     = ""
  description = "No-inbound builder security group."
}

variable "iam_instance_profile" {
  type        = string
  default     = "golden-ami-packer-builder"
  description = "Instance profile with AmazonSSMManagedInstanceCore (Terraform output packer_instance_profile)."
}

variable "kms_key_id" {
  type        = string
  default     = ""
  description = "CMK used to encrypt the AMI and the builder EBS volume."
}

variable "source_ami" {
  type        = string
  default     = ""
  description = "Optional explicit source AMI. When empty, source_ami_filter is used."
}

variable "source_ami_owners" {
  type        = list(string)
  default     = ["amazon", "309956199498", "219670896067"]
  description = "Owner IDs to search. Confirm the Red Hat account ID in your partition before a real bake."
}

variable "source_ami_name_filter" {
  type    = string
  default = "RHEL-9*_HVM-*-x86_64-*"
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "ssh_username" {
  type        = string
  default     = "ec2-user"
  description = "Some RHEL AMIs use cloud-user instead of ec2-user."
}

variable "root_volume_size" {
  type    = number
  default = 30
}

variable "artifacts_bucket" {
  type        = string
  default     = ""
  description = "Optional bucket to upload OpenSCAP reports after the gate."
}

locals {
  timestamp                 = regex_replace(timestamp(), "[- TZ:]", "")
  ami_name                  = "${var.project}-rhel9-${var.environment}-${local.timestamp}"
  source_ami_filter_enabled = var.source_ami == ""
}

source "amazon-ebs" "rhel9" {
  region          = var.aws_region
  instance_type   = var.instance_type
  ami_name        = local.ami_name
  ami_description = "STIG-hardened RHEL 9 golden AMI (${var.environment})"
  source_ami      = var.source_ami == "" ? null : var.source_ami

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

  # IMDSv2 required, hop limit 1 (IMDSv2 SSRF mitigation).
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

  # No inbound SSH: communicate through SSM Session Manager.
  communicator            = "ssh"
  ssh_username            = var.ssh_username
  ssh_interface           = "session_manager"
  ssh_timeout             = "15m"
  temporary_key_pair_type = "ed25519"

  tags = {
    Name        = local.ami_name
    GoldenAMI   = "true"
    OS          = "rhel9"
    Environment = var.environment
    Project     = var.project
    Partition   = var.aws_partition
    BuiltBy     = "packer"
  }

  run_tags = {
    Name        = "${local.ami_name}-builder"
    Role        = "packer-builder"
    OS          = "rhel9"
    Environment = var.environment
    Project     = var.project
  }
}

build {
  name    = "rhel9-golden"
  sources = ["source.amazon-ebs.rhel9"]

  # 1) Harden + enable FIPS (FIPS may request a reboot).
  provisioner "ansible" {
    playbook_file = "${path.root}/../../ansible/site-rhel.yml"
    user          = var.ssh_username
    use_proxy     = false
    extra_arguments = [
      "--become",
      "-e", "enable_fips=true",
      "-e", "ansible_python_interpreter=/usr/bin/python3",
    ]
  }

  # 2) Reboot only if the fips role left its marker file.
  provisioner "shell" {
    expect_disconnect = true
    inline = [
      "if [ -f /var/tmp/fips-reboot-required ]; then rm -f /var/tmp/fips-reboot-required; sudo reboot; else echo 'No FIPS reboot required'; fi",
    ]
  }

  provisioner "shell" {
    pause_before = "30s"
    inline       = ["echo builder is back after optional FIPS reboot"]
  }

  # 3) Confirm FIPS actually took effect.
  provisioner "ansible" {
    playbook_file = "${path.root}/../../ansible/fips-verify.yml"
    user          = var.ssh_username
    use_proxy     = false
    extra_arguments = [
      "--become",
      "-e", "ansible_python_interpreter=/usr/bin/python3",
    ]
  }

  # 4) OpenSCAP DISA STIG profile + CAT I gate. Failure aborts the AMI.
  provisioner "file" {
    source      = "${path.root}/../../scripts/scan-rhel-openscap.sh"
    destination = "/tmp/scan-rhel-openscap.sh"
  }

  provisioner "file" {
    source      = "${path.root}/../../scripts/gate-oscap.py"
    destination = "/tmp/gate-oscap.py"
  }

  provisioner "shell" {
    environment_vars = [
      "SCAN_DIR=/var/tmp/scan-artifacts",
    ]
    inline = [
      "sudo mkdir -p /var/tmp/scan-artifacts",
      "sudo cp /tmp/scan-rhel-openscap.sh /tmp/gate-oscap.py /var/tmp/",
      "sudo chmod 0755 /var/tmp/scan-rhel-openscap.sh /var/tmp/gate-oscap.py",
      "sudo SCAN_DIR=/var/tmp/scan-artifacts /var/tmp/scan-rhel-openscap.sh",
    ]
  }

  # 5) Optional upload of scan artifacts, then clean packer leftovers.
  provisioner "shell" {
    environment_vars = [
      "ARTIFACTS_BUCKET=${var.artifacts_bucket}",
      "AWS_REGION=${var.aws_region}",
      "AMI_NAME=${local.ami_name}",
    ]
    inline = [
      "if [ -n \"$${ARTIFACTS_BUCKET}\" ]; then aws s3 cp --recursive /var/tmp/scan-artifacts \"s3://$${ARTIFACTS_BUCKET}/rhel9/$${AMI_NAME}/\"; fi",
      "sudo rm -rf /var/tmp/fips-reboot-required /tmp/scan-rhel-openscap.sh /tmp/gate-oscap.py",
    ]
  }

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}
