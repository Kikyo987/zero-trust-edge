output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr" {
  value = module.vpc.vpc_cidr
}

output "public_subnet_cidrs" {
  value = module.vpc.public_subnet_cidrs
}

output "private_subnet_cidrs" {
  value = module.vpc.private_subnet_cidrs
}

output "node_security_group_id" {
  value = module.security.node_security_group_id
}

output "ingress_summary" {
  value = module.security.ingress_summary
}

output "iam_role_arn" {
  value = module.iam.role_arn
}

output "ssm_parameter_path" {
  value       = module.iam.ssm_parameter_path
  description = "aws ssm put-parameter --name /edge-zero/tailscale-auth-key --type SecureString --value tskey-..."
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
    1. aws ec2 describe-security-groups --group-ids ${module.security.node_security_group_id}
       Expect: no 0.0.0.0/0 TCP. 6443/10250 from self only.
    2. Optional: aws ssm put-parameter --name ${module.iam.ssm_parameter_path}tailscale-auth-key --type SecureString --value tskey-...
    3. aws ssm start-session --target ${module.compute.instance_id}
       (or wait for Tailscale and ssh to 100.x)
    4. sudo journalctl -u k3s -u docker -f
       kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml -n edge get pods,svc,ingress
    5. Point a Cloudflare Tunnel CNAME at the Traefik Ingress host. Never at the Elastic IP.
  EOT
}
