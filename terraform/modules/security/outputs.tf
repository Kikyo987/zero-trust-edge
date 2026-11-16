output "node_security_group_id" {
  value       = aws_security_group.node.id
  description = "Attach to the k3s ENI. Ingress is empty aside from PMTUD + self."
}

output "endpoint_security_group_id" {
  value = aws_security_group.endpoints.id
}

output "ingress_is_closed" {
  value       = true
  description = "Documentation output. There is no 0.0.0.0/0 TCP inbound."
}
