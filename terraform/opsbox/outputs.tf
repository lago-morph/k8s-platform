output "instance_id" {
  description = "Instance id of the ops box — this is what you click Connect on in Session Manager"
  value       = aws_instance.opsbox.id
}

output "role_arn" {
  description = "IAM role the ops box runs as. The bring-up scripts grant this principal access to each cluster as it appears."
  value       = aws_iam_role.opsbox.arn
}

output "console_url" {
  description = "Direct link to the browser shell for this instance"
  value       = "https://${var.aws_region}.console.aws.amazon.com/systems-manager/session-manager/${aws_instance.opsbox.id}?region=${var.aws_region}"
}

output "checkout_path" {
  description = "Where the repository is checked out on the box"
  value       = "/opt/k8-platform"
}
