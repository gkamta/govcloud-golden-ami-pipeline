# ---------------------------------------------------------------------------
# Isolated Packer build network and supporting IAM/S3.
#
# The builder instance sits in a private subnet. The security group has *no
# inbound rules* — Packer reaches the instance through SSM Session Manager
# (SC-7). Interface endpoints for SSM/EC2/STS/KMS/Logs plus an S3 gateway
# endpoint keep management traffic off the public internet. A NAT gateway is
# optional and intended only so the builder can reach RHUI or Windows Update
# during the bake; turn it off in a disconnected enclave and point at a
# mirrored repo instead.
# ---------------------------------------------------------------------------
data "aws_partition" "current" {}
data "aws_region" "current" {}
locals {
  interface_services = toset(var.interface_endpoint_services)
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = "${var.name}-packer-vpc" })
}

# Close the default SG (it otherwise allows all egress). Workloads use the
# named builder and endpoint security groups instead.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-default-closed" })
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.private_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false
  tags                    = merge(var.tags, { Name = "${var.name}-packer-private" })
}

resource "aws_subnet" "public" {
  count                   = var.enable_nat_gateway ? 1 : 0
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false
  tags                    = merge(var.tags, { Name = "${var.name}-packer-public" })
}

resource "aws_internet_gateway" "this" {
  count  = var.enable_nat_gateway ? 1 : 0
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-packer-igw" })
}

resource "aws_eip" "nat" {
  # checkov:skip=CKV2_AWS_19:EIP is associated with the NAT gateway below.
  count  = var.enable_nat_gateway ? 1 : 0
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name}-packer-nat-eip" })
}

resource "aws_nat_gateway" "this" {
  count         = var.enable_nat_gateway ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id
  depends_on    = [aws_internet_gateway.this]
  tags          = merge(var.tags, { Name = "${var.name}-packer-nat" })
}

resource "aws_route_table" "public" {
  count  = var.enable_nat_gateway ? 1 : 0
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-packer-public-rt" })
}

resource "aws_route" "public_internet" {
  count                  = var.enable_nat_gateway ? 1 : 0
  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}

resource "aws_route_table_association" "public" {
  count          = var.enable_nat_gateway ? 1 : 0
  subnet_id      = aws_subnet.public[0].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-packer-private-rt" })
}

resource "aws_route" "private_nat" {
  count                  = var.enable_nat_gateway ? 1 : 0
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[0].id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_flow_log" "this" {
  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  iam_role_arn             = aws_iam_role.flow_logs.arn
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs.arn
  max_aggregation_interval = 60
  tags                     = merge(var.tags, { Name = "${var.name}-packer-flow-logs" })
}

resource "aws_cloudwatch_log_group" "flow_logs" {
  # checkov:skip=CKV_AWS_338:One year retention is enough for a bake VPC; increase if your ATO requires longer.
  name              = "/vpc/${var.name}-packer-flow-logs"
  retention_in_days = 365
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${var.name}-packer-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "flow_logs" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs.arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "flow-logs-write"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs.json
}

# --- VPC endpoints (SSM path + supporting APIs) ---

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = merge(var.tags, { Name = "${var.name}-s3" })
}

resource "aws_security_group" "endpoints" {
  # checkov:skip=CKV2_AWS_5:Attached to the interface VPC endpoints below (for_each not resolved by checkov).
  name        = "${var.name}-vpce"
  description = "HTTPS from the Packer VPC to interface endpoints"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.this.cidr_block]
  }

  egress {
    description = "Responses within VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_vpc.this.cidr_block]
  }

  tags = merge(var.tags, { Name = "${var.name}-vpce" })
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = local.interface_services
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  tags                = merge(var.tags, { Name = "${var.name}-${each.value}" })
}

# Builder security group: NO inbound rules. Egress is HTTPS (and HTTP for
# yum/RHUI redirects when NAT is enabled). Packer uses SSM, not SSH/WinRM ports.
resource "aws_security_group" "builder" {
  # checkov:skip=CKV2_AWS_5:Attached at bake time by Packer via iam/sg ids in packer variables.
  # checkov:skip=CKV_AWS_382:Egress 443 to 0.0.0.0/0 is only opened when NAT is enabled so the builder can reach RHUI or Windows Update; in an enclave set enable_nat_gateway=false.
  name        = "${var.name}-packer-builder"
  description = "Packer builder - no inbound; SSM Session Manager only"
  vpc_id      = aws_vpc.this.id
  tags        = merge(var.tags, { Name = "${var.name}-packer-builder" })
}

resource "aws_security_group_rule" "builder_egress_vpc" {
  type              = "egress"
  security_group_id = aws_security_group.builder.id
  description       = "HTTPS to VPC endpoints"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [aws_vpc.this.cidr_block]
}

resource "aws_security_group_rule" "builder_egress_updates" {
  count             = var.enable_nat_gateway ? 1 : 0
  type              = "egress"
  security_group_id = aws_security_group.builder.id
  description       = "HTTPS to vendor update services via NAT"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "builder_egress_http_updates" {
  count             = var.enable_nat_gateway ? 1 : 0
  type              = "egress"
  security_group_id = aws_security_group.builder.id
  description       = "HTTP redirects to vendor update services via NAT"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

# --- Artifacts bucket (scan reports, Packer manifests) ---

resource "aws_s3_bucket" "artifacts" {
  # checkov:skip=CKV_AWS_144:Cross-region replication is optional for a demo artifacts bucket.
  # checkov:skip=CKV_AWS_18:Access logging target is environment-specific; enable when a log-archive bucket exists.
  # checkov:skip=CKV2_AWS_62:Event notifications are not required for scan artifacts.
  bucket = var.artifacts_bucket_name
  tags   = merge(var.tags, { Name = var.artifacts_bucket_name })
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    id     = "expire-old-scan-reports"
    status = "Enabled"
    filter {}
    expiration {
      days = var.artifact_expiration_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "artifacts" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.artifacts.arn,
      "${aws_s3_bucket.artifacts.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  policy = data.aws_iam_policy_document.artifacts.json
}

# --- Builder instance role (SSM + KMS + artifacts) ---

data "aws_iam_policy_document" "builder_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.${data.aws_partition.current.dns_suffix}"]
    }
  }
}

resource "aws_iam_role" "builder" {
  name               = "${var.name}-packer-builder"
  assume_role_policy = data.aws_iam_policy_document.builder_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "builder_ssm" {
  role       = aws_iam_role.builder.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "builder" {
  statement {
    sid       = "Artifacts"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
  }

  statement {
    sid = "Kms"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "builder" {
  name   = "packer-builder-artifacts"
  role   = aws_iam_role.builder.id
  policy = data.aws_iam_policy_document.builder.json
}

resource "aws_iam_instance_profile" "builder" {
  name = "${var.name}-packer-builder"
  role = aws_iam_role.builder.name
  tags = var.tags
}
