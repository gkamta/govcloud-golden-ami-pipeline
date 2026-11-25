output "key_arn" {
  description = "CMK ARN."
  value       = aws_kms_key.this.arn
}

output "key_id" {
  description = "CMK ID."
  value       = aws_kms_key.this.id
}

output "alias" {
  description = "KMS alias name."
  value       = aws_kms_alias.this.name
}
