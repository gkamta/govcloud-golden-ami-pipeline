output "launch_template_id" {
  description = "Launch template ID."
  value       = aws_launch_template.this.id
}

output "launch_template_latest_version" {
  description = "Latest launch-template version (the ASG tracks this)."
  value       = aws_launch_template.this.latest_version
}

output "autoscaling_group_name" {
  description = "Auto Scaling group name."
  value       = aws_autoscaling_group.this.name
}

output "ami_id" {
  description = "AMI ID resolved for this fleet."
  value       = local.resolved_ami_id
}
