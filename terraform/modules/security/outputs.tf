output "node_security_group_id" {
  value       = aws_security_group.node.id
  description = "Attach to the k3s ENI. No 0.0.0.0/0 TCP inbound."
}

output "endpoint_security_group_id" {
  value = aws_security_group.endpoints.id
}

output "ingress_summary" {
  value = {
    public_tcp          = "none"
    ssh_22              = "closed (Tailscale / SSM, not SG)"
    https_443           = "closed (Cloudflare Tunnel outbound)"
    kube_apiserver_6443 = "same SG only"
    kubelet_10250       = "same SG only"
    flannel_vxlan_8472  = "same SG only"
    flannel_wg_51820    = "same SG only"
    icmp                = "type 3 dest-unreach only"
  }
  description = "Human-readable posture. Use in plan reviews."
}
