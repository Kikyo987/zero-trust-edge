output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr" {
  value = module.vpc.vpc_cidr
}

output "private_subnet_cidrs" {
  value = module.vpc.private_subnet_cidrs
}

output "node_instance_id" {
  value = module.compute.instance_id
}

output "node_private_ip" {
  value = module.compute.private_ip
}

output "node_public_ip" {
  value       = module.compute.public_ip
  description = "Egress identifier only. Do not put this in DNS."
}

output "nat_gateway_ids" {
  value       = module.vpc.nat_gateway_ids
  description = "Must be empty on the cheap path."
}

output "next_steps" {
  value = <<-EOT
    1. Confirm SG ingress: aws ec2 describe-security-groups --group-ids <node sg>
       Expected: no 0.0.0.0/0 TCP.
    2. SSM start-session OR wait for Tailscale (user-data) and ssh to 100.x.
    3. sudo /opt/edge/k3s/install.sh
    4. ./scripts/zero-trust-verify.sh
    5. Point a named Cloudflare tunnel at the in-cluster Service.
  EOT
}
