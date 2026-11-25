# ---------------------------------------------------------------------------
# Pointers to the current golden AMI, plus optional deprecation metadata.
#
# The bake pipeline overwrites the SSM parameter value after a successful
# scan gate (scripts/publish-ami-ssm.sh). Terraform creates the parameter
# and ignores subsequent value changes so CI and Terraform do not fight
# (CM-2: the approved image is the one the parameter names).
# ---------------------------------------------------------------------------

resource "aws_ssm_parameter" "latest" {
  # checkov:skip=CKV_AWS_337:The value is an AMI ID (not a secret); SecureString would hide it from operators for no benefit. Access is still IAM-controlled.
  # checkov:skip=CKV2_AWS_34:Same justification — this parameter is an AMI ID pointer, not a secret.
  for_each    = var.operating_systems
  name        = "/golden-ami/${each.key}/latest"
  description = "Latest scanned golden AMI ID for ${each.key} in ${var.environment}"
  type        = "String"
  value       = each.value.initial_ami_id
  tier        = "Standard"
  overwrite   = true
  tags        = merge(var.tags, { OS = each.key, Environment = var.environment })

  lifecycle {
    ignore_changes = [value]
  }
}

# Optional: record the deprecation horizon so operators and scripts agree.
resource "aws_ssm_parameter" "deprecate_after_days" {
  # checkov:skip=CKV_AWS_337:Integer policy setting, not a secret.
  # checkov:skip=CKV2_AWS_34:Integer policy setting, not a secret.
  count       = var.deprecate_after_days == null ? 0 : 1
  name        = "/golden-ami/deprecate-after-days"
  description = "AMIs older than this many days should be deprecated (used by scripts/deprecate-old-amis.sh)."
  type        = "String"
  value       = tostring(var.deprecate_after_days)
  overwrite   = true
  tags        = var.tags
}
