# Security groups — least privilege, every rule named with its reason.
#
# Users never hit this SG. They terminate on Cloudflare; cloudflared
# dials OUT. Operators never hit this SG on :22. They arrive on
# Tailscale (UDP/41641 egress, stateful return).
#
# Therefore there is no 0.0.0.0/0 TCP inbound. Not 22, not 80, not 443,
# not 6443. If a rule looks like "I'll just open 22 from my IP", it does
# not belong here.

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
  }
}

resource "aws_security_group" "node" {
  name        = "${var.name}-node"
  description = "k3s node. No public inbound TCP. Overlay + same-SG cluster ports only."
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-node" })
}

# ----- ingress: cluster fabric, source = this SG only -----
# Explicit ports rather than ip_protocol = "-1". A second node in the
# same SG can join; a random ENI in the VPC cannot.

resource "aws_vpc_security_group_ingress_rule" "kube_apiserver" {
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  description                  = "kube-apiserver. Source: other k3s nodes, never 0.0.0.0/0."
}

resource "aws_vpc_security_group_ingress_rule" "kubelet" {
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "tcp"
  from_port                    = 10250
  to_port                      = 10250
  description                  = "kubelet. Source: control plane / other nodes."
}

resource "aws_vpc_security_group_ingress_rule" "flannel_vxlan" {
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "udp"
  from_port                    = 8472
  to_port                      = 8472
  description                  = "flannel VXLAN fallback. Unused when wireguard-native is active."
}

resource "aws_vpc_security_group_ingress_rule" "flannel_wireguard" {
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "udp"
  from_port                    = 51820
  to_port                      = 51820
  description                  = "flannel wireguard-native overlay (k3s --flannel-backend)."
}

# ICMP dest-unreach (type 3) so Path MTU Discovery works on egress.
# Echo-request (type 8) is intentionally absent — we are not a ping target.
resource "aws_vpc_security_group_ingress_rule" "pmtud" {
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "icmp"
  from_port         = 3
  to_port           = -1
  description       = "PMTUD dest-unreach. Required. See docs/postmortem-example.md."
}

# ----- egress: allow-list of what this node is allowed to start -----
resource "aws_vpc_security_group_egress_rule" "unrestricted" {
  count             = var.egress_unrestricted ? 1 : 0
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "BOOTSTRAP ONLY. Set egress_unrestricted=false before handover."
}

resource "aws_vpc_security_group_egress_rule" "https" {
  count             = var.egress_unrestricted ? 0 : 1
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "Cloudflare Tunnel, GHCR, GitHub, IdP, apt HTTPS, SSM, DERP."
}

resource "aws_vpc_security_group_egress_rule" "http" {
  count             = var.egress_unrestricted ? 0 : 1
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  description       = "apt mirrors that still 301 from HTTP. Not a user listener."
}

resource "aws_vpc_security_group_egress_rule" "dns_udp" {
  count             = var.egress_unrestricted ? 0 : 1
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 53
  to_port           = 53
  description       = "DNS. Prefer the VPC resolver at cidr+2 when possible."
}

resource "aws_vpc_security_group_egress_rule" "dns_tcp" {
  count             = var.egress_unrestricted ? 0 : 1
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 53
  to_port           = 53
  description       = "DNS TCP (truncation / DNSSEC)."
}

resource "aws_vpc_security_group_egress_rule" "ntp" {
  count             = var.egress_unrestricted ? 0 : 1
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 123
  to_port           = 123
  description       = "NTP. TLS, Tailscale, and k3s certs all break on clock skew."
}

resource "aws_vpc_security_group_egress_rule" "tailscale_direct" {
  count             = var.egress_unrestricted ? 0 : 1
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 41641
  to_port           = 41641
  description       = "Tailscale direct WireGuard. Return traffic is stateful."
}

resource "aws_vpc_security_group_egress_rule" "stun" {
  count             = var.egress_unrestricted ? 0 : 1
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 3478
  to_port           = 3478
  description       = "Tailscale STUN for NAT traversal."
}

resource "aws_vpc_security_group_egress_rule" "https_udp" {
  count             = var.egress_unrestricted ? 0 : 1
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 443
  to_port           = 443
  description       = "QUIC (Cloudflare Tunnel) and HTTP/3."
}

resource "aws_vpc_security_group_egress_rule" "icmp" {
  count             = var.egress_unrestricted ? 0 : 1
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "icmp"
  from_port         = -1
  to_port           = -1
  description       = "Outbound ICMP for PMTUD / mtu-path-check.sh."
}

# Same-SG egress so a second node can reach 6443/10250/overlays without
# relying on the 0.0.0.0/0 HTTPS rule.
resource "aws_vpc_security_group_egress_rule" "to_self" {
  count                        = var.egress_unrestricted ? 0 : 1
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "-1"
  description                  = "Intra-cluster fabric (apiserver, kubelet, flannel)."
}

# Interface VPC endpoints (SSM/ECR) if the node is fully private.
resource "aws_security_group" "endpoints" {
  name        = "${var.name}-vpce"
  description = "Interface VPC endpoints. Ingress only from the node SG on 443."
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-vpce" })
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_node" {
  security_group_id            = aws_security_group.endpoints.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "Nodes to SSM/ECR interface endpoints. Source: node SG, not 0.0.0.0/0."
}

resource "aws_vpc_security_group_egress_rule" "endpoints_out" {
  security_group_id = aws_security_group.endpoints.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "Endpoint ENI to AWS public API."
}
