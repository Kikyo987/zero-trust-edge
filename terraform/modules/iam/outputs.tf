output "role_name" {
  value = aws_iam_role.node.name
}

output "role_arn" {
  value = aws_iam_role.node.arn
}

output "instance_profile_name" {
  value = aws_iam_instance_profile.node.name
}

output "ssm_parameter_path" {
  value       = "/${var.project}/"
  description = "Put Tailscale auth keys and tunnel tokens under this path."
}
