# ---------------------------------------------------------------------------
# Consume the latest golden AMI (by tag or explicit ID) and roll a fleet
# forward with an Auto Scaling instance refresh. IMDSv2 is required and the
# root volume is KMS-encrypted (SC-28, SI-4 / IMDS hop limit 1).
# ---------------------------------------------------------------------------
data "aws_ami_ids" "golden" {
  count  = var.ami_id == null ? 1 : 0
  owners = var.ami_owners

  filter {
    name   = "state"
    values = ["available"]
  }

  filter {
    name   = "tag:GoldenAMI"
    values = ["true"]
  }

  filter {
    name   = "tag:OS"
    values = [var.os]
  }

  filter {
    name   = "tag:Environment"
    values = [var.environment]
  }
}

data "aws_ami" "base_fallback" {
  count       = var.ami_id == null && var.fallback_to_base_ami && length(try(data.aws_ami_ids.golden[0].ids, [])) == 0 ? 1 : 0
  most_recent = true
  owners      = var.fallback_ami_owners

  filter {
    name   = "name"
    values = [var.fallback_ami_name_filter]
  }

  filter {
    name   = "state"
    values = ["available"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

locals {
  # Prefer an explicit ID, then the tagged golden AMI, then (dev only) a vendor base image.
  resolved_ami_id = coalesce(
    var.ami_id,
    try(data.aws_ami_ids.golden[0].ids[0], null),
    try(data.aws_ami.base_fallback[0].id, null),
  )
}

resource "aws_launch_template" "this" {
  name_prefix   = "${var.name}-"
  image_id      = local.resolved_ami_id
  instance_type = var.instance_type

  iam_instance_profile {
    name = var.instance_profile_name
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = true
  }

  network_interfaces {
    # checkov:skip=CKV_AWS_88:Public IP is intentionally disabled; instances stay in private subnets.
    associate_public_ip_address = false
    security_groups             = var.security_group_ids
    delete_on_termination       = true
  }

  block_device_mappings {
    device_name = var.root_device_name
    ebs {
      encrypted             = true
      kms_key_id            = var.kms_key_arn
      volume_type           = "gp3"
      volume_size           = var.root_volume_size
      delete_on_termination = true
    }
  }

  user_data = var.user_data_base64

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = var.name, OS = var.os })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = var.name, OS = var.os })
  }

  tags = merge(var.tags, { Name = var.name })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "this" {
  # checkov:skip=CKV_AWS_153:Tag propagation is configured in the tag blocks below (checkov often misses dynamically named tags).
  name                      = var.name
  min_size                  = var.min_size
  max_size                  = var.max_size
  desired_capacity          = var.desired_capacity
  vpc_zone_identifier       = var.subnet_ids
  health_check_type         = "EC2"
  health_check_grace_period = var.health_check_grace_period
  force_delete              = false

  launch_template {
    id      = aws_launch_template.this.id
    version = aws_launch_template.this.latest_version
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = var.refresh_min_healthy_percentage
      instance_warmup        = var.refresh_instance_warmup
    }
    triggers = ["launch_template"]
  }

  dynamic "tag" {
    for_each = merge(var.tags, { Name = var.name, OS = var.os })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}
