# ---------------------------------------------------------------------------
# One-time bootstrap: S3 bucket + DynamoDB table for remote Terraform state.
# Run once per account with local state, then every environment uses the
# S3 backend (see envs/*/backend.hcl.example).
#   terraform -chdir=terraform/bootstrap init
#   terraform -chdir=terraform/bootstrap apply -var=state_bucket_name=...
# ---------------------------------------------------------------------------
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.60, < 6.0"
    }
  }
}

variable "aws_region" {
  description = "Region (GovCloud default)."
  type        = string
  default     = "us-gov-west-1"
}

variable "state_bucket_name" {
  description = "Globally unique S3 bucket name for Terraform state."
  type        = string
}

variable "lock_table_name" {
  description = "DynamoDB table name for state locking."
  type        = string
  default     = "terraform-state-lock"
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    Project   = "govcloud-golden-ami-pipeline"
    ManagedBy = "terraform"
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = var.tags
  }
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "state_kms" {
  # checkov:skip=CKV_AWS_109:Key policy root statement is the AWS-recommended default.
  # checkov:skip=CKV_AWS_111:Key policy root statement is the AWS-recommended default.
  # checkov:skip=CKV_AWS_356:Key policies must use "*" as the resource.
  statement {
    sid       = "EnableRootAccountPermissions"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_kms_key" "state" {
  description             = "Terraform state encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.state_kms.json
}

resource "aws_kms_alias" "state" {
  name          = "alias/${var.lock_table_name}-tfstate"
  target_key_id = aws_kms_key.state.id
}

resource "aws_s3_bucket" "state" {
  # checkov:skip=CKV_AWS_144:Cross-region replication is optional for a demo state bucket.
  # checkov:skip=CKV_AWS_18:Access logging target bucket is environment-specific.
  # checkov:skip=CKV2_AWS_62:Event notifications not required for state.
  bucket = var.state_bucket_name
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "abort-incomplete-and-expire-old-versions"
    status = "Enabled"
    filter {}
    # Do not expire current state objects.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
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

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json
}

resource "aws_dynamodb_table" "lock" {
  # checkov:skip=CKV_AWS_119:A dedicated state CMK can be wired later; AWS-managed encryption is the default.
  # checkov:skip=CKV_AWS_28:Point-in-time recovery is recommended for production; enable when this leaves demo use.
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }
}

output "state_bucket" {
  description = "S3 bucket for Terraform state."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "S3 bucket ARN for Terraform state."
  value       = aws_s3_bucket.state.arn
}

output "lock_table" {
  description = "DynamoDB table for state locking."
  value       = aws_dynamodb_table.lock.name
}

output "lock_table_arn" {
  description = "DynamoDB lock table ARN."
  value       = aws_dynamodb_table.lock.arn
}

output "state_kms_key_arn" {
  description = "CMK used to encrypt the state bucket."
  value       = aws_kms_key.state.arn
}
