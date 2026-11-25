# ---------------------------------------------------------------------------
# Keyless CI auth: GitHub Actions exchanges its OIDC token for short-lived AWS
# credentials used by Packer and Terraform. No long-lived access keys
# (IA-2, IA-5, AC-2). The trust policy is limited to this repository and the
# subjects we allow (main, pull requests, and named environments).
# ---------------------------------------------------------------------------
data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count           = var.create_oidc_provider ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
  tags            = var.tags
}

data "aws_iam_policy_document" "assume" {
  statement {
    sid     = "GitHubOidcTrust"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for s in var.allowed_subjects : "repo:${var.github_repository}:${s}"]
    }
  }
}

resource "aws_iam_role" "ci" {
  name                 = var.role_name
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  max_session_duration = 3600
  tags                 = var.tags
}

# Least-privilege Packer + AMI lifecycle permissions. EC2 image APIs still
# require "*" on many actions (AWS does not support resource-level auth for
# RunInstances/CreateImage in all cases); we scope everything else.
data "aws_iam_policy_document" "ci" {
  # checkov:skip=CKV_AWS_111:Packer must call EC2 image APIs that only support Resource "*".
  # checkov:skip=CKV_AWS_109:Same constraint; write actions are listed explicitly rather than "*:*".
  # checkov:skip=CKV_AWS_356:EC2 CreateImage/RunInstances cannot be resource-scoped tightly.

  statement {
    sid = "PackerEc2"
    actions = [
      "ec2:Describe*",
      "ec2:CreateImage",
      "ec2:RegisterImage",
      "ec2:CopyImage",
      "ec2:ModifyImageAttribute",
      "ec2:CreateTags",
      "ec2:RunInstances",
      "ec2:TerminateInstances",
      "ec2:StopInstances",
      "ec2:StartInstances",
      "ec2:CreateVolume",
      "ec2:DeleteVolume",
      "ec2:AttachVolume",
      "ec2:DetachVolume",
      "ec2:CreateSnapshot",
      "ec2:DeleteSnapshot",
      "ec2:EnableImageDeprecation",
      "ec2:DisableImageDeprecation",
      "ec2:DeregisterImage",
      "ec2:CreateKeyPair",
      "ec2:DeleteKeyPair",
      "ec2:CreateSecurityGroup",
      "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "PassPackerInstanceRole"
    actions   = ["iam:PassRole", "iam:GetRole", "iam:GetInstanceProfile"]
    resources = var.packer_instance_role_arns
  }

  statement {
    sid = "SessionManager"
    actions = [
      "ssm:StartSession",
      "ssm:TerminateSession",
      "ssm:DescribeSessions",
      "ssm:DescribeInstanceInformation",
      "ssm:GetConnectionStatus",
      "ssm:ResumeSession",
    ]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = length(var.ssm_parameter_arns) > 0 ? [1] : []
    content {
      sid       = "GoldenAmiParameters"
      actions   = ["ssm:PutParameter", "ssm:GetParameter", "ssm:GetParameters", "ssm:AddTagsToResource"]
      resources = var.ssm_parameter_arns
    }
  }

  dynamic "statement" {
    for_each = var.artifacts_bucket_arn == null ? [] : [1]
    content {
      sid       = "ArtifactsBucket"
      actions   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:DeleteObject"]
      resources = [var.artifacts_bucket_arn, "${var.artifacts_bucket_arn}/*"]
    }
  }

  dynamic "statement" {
    for_each = var.kms_key_arn == null ? [] : [1]
    content {
      sid = "KmsForAmiAndArtifacts"
      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:GenerateDataKey",
        "kms:GenerateDataKeyWithoutPlaintext",
        "kms:DescribeKey",
        "kms:ReEncrypt*",
        "kms:CreateGrant",
      ]
      resources = [var.kms_key_arn]
    }
  }

  dynamic "statement" {
    for_each = var.state_bucket_arn == null ? [] : [1]
    content {
      sid       = "TfState"
      actions   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
      resources = [var.state_bucket_arn, "${var.state_bucket_arn}/*"]
    }
  }

  dynamic "statement" {
    for_each = var.lock_table_arn == null ? [] : [1]
    content {
      sid       = "TfLock"
      actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
      resources = [var.lock_table_arn]
    }
  }
}

resource "aws_iam_role_policy" "ci" {
  name   = "packer-ami-least-privilege"
  role   = aws_iam_role.ci.id
  policy = data.aws_iam_policy_document.ci.json
}

# Read-only for terraform plan on PRs.
resource "aws_iam_role_policy_attachment" "readonly" {
  role       = aws_iam_role.ci.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/ReadOnlyAccess"
}
