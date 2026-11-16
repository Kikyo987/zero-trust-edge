output "instance_id" {
  value = aws_instance.node.id
}

output "private_ip" {
  value = aws_instance.node.private_ip
}

output "public_ip" {
  value       = var.assign_public_ip ? aws_eip.node[0].public_ip : null
  description = "Present on the cheap path. Must NEVER appear in public DNS."
}

output "iam_role_arn" {
  value = aws_iam_role.node.arn
}
