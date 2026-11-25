# ---------------------------------------------------------------------------
# Customer-managed key for EBS volumes, AMI snapshots, and the artifacts
# bucket (SC-12, SC-28). Rotation is enabled. The instance role and CI role
# receive use grants; the account root retains administration.
# ---------------------------------------------------------------------------
data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "this" {
  # checkov:skip=CKV_AWS_109:Key policy root statement is the AWS-recommended default.
  # checkov:skip=CKV_AWS_111:Key policy root statement is the AWS-recommended default.
  # checkov:skip=CKV_AWS_356:KMS key policies must use "*" as the resource.

  statement {
    sid       = "EnableRootAccountPermissions"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "AllowCloudWatchLogs"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.${data.aws_partition.current.dns_suffix}"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${data.aws_partition.current.partition}:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }

  dynamic "statement" {
    for_each = length(var.key_user_arns) > 0 ? [1] : []
    content {
      sid = "AllowKeyUsers"
      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:GenerateDataKey",
        "kms:GenerateDataKeyWithoutPlaintext",
        "kms:DescribeKey",
        "kms:ReEncrypt*",
        "kms:CreateGrant",
      ]
      resources = ["*"]
      principals {
        type        = "AWS"
        identifiers = var.key_user_arns
      }
      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values = [
          "ec2.${var.region}.${data.aws_partition.current.dns_suffix}",
          "s3.${var.region}.${data.aws_partition.current.dns_suffix}",
          "ssm.${var.region}.${data.aws_partition.current.dns_suffix}",
        ]
      }
    }
  }
}

resource "aws_kms_key" "this" {
  description             = var.description
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.this.json
  tags                    = var.tags
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.alias}"
  target_key_id = aws_kms_key.this.id
}
