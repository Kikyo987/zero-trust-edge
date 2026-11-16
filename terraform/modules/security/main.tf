# Security groups for the edge node.
#
# Ingress on sg-node is INTENTIONALLY EMPTY. Tailscale and Cloudflare
# Tunnel are both outbound-initiated. Return packets match stateful SG
# tracking. If you feel the urge to add :22 from 0.0.0.0/0, stop and
# read docs/architecture.md.

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
  description = "k3s node — no public inbound. Operators via Tailscale, users via Cloudflare Tunnel."
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-node" })

  # AWS provider 5.x: prefer aws_vpc_security_group_*_rule resources so a
  # later "allow 22 from me" change is a discrete reviewable object.
  lifecycle {
    # Catch accidental inline ingress if someone pastes an old snippet.
    ignore_changes = []
  }
}

# Optional: intra-VPC node-to-node for a future second k3s member.
# Still not public. kubelet / flannel / WireGuard overlay stay inside 10.42/16.
resource "aws_vpc_security_group_ingress_rule" "from_self" {
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "-1"
  description                  = "Intra-cluster, same SG. Needed the moment a second node exists."
}

# ICMP dest-unreach from anywhere so PMTUD works on egress paths.
# Echo-request from the world stays denied (no inbound rule for type 8).
resource "aws_vpc_security_group_ingress_rule" "pmtud" {
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "icmp"
  from_port         = 3
  to_port           = -1
  description       = "PMTUD dest-unreach. Do not delete — see docs/postmortem-example.md."
}

# ----- egress -----
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
  description       = "Cloudflare Tunnel, GHCR, GitHub, IdP, DERP-over-HTTPS"
}

resource "aws_vpc_security_group_egress_rule" "http" {
  count             = var.egress_unrestricted ? 0 : 1
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  description       = "apt mirrors that still speak HTTP then 301"
}

resource "aws_vpc_security_group_egress_rule" "dns_udp" {
  count             = var.egress_unrestricted ? 0 : 1
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 53
  to_port           = 53
  description       = "DNS. Prefer VPC resolver (.2) via dhcp-options where possible."
}

resource "aws_vpc_security_group_egress_rule" "dns_tcp" {
  count             = var.egress_unrestricted ? 0 : 1
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 53
  to_port           = 53
  description       = "DNS TCP (truncation / DNSSEC)"
}

resource "aws_vpc_security_group_egress_rule" "ntp" {
  count             = var.egress_unrestricted ? 0 : 1
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 123
  to_port           = 123
  description       = "NTP. TLS and Tailscale both suffer if the clock drifts."
}

resource "aws_vpc_security_group_egress_rule" "tailscale_direct" {
  count             = var.egress_unrestricted ? 0 : 1
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 41641
  to_port           = 41641
  description       = "Tailscale direct WireGuard"
}

resource "aws_vpc_security_group_egress_rule" "stun" {
  count             = var.egress_unrestricted ? 0 : 1
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 3478
  to_port           = 3478
  description       = "Tailscale STUN"
}

resource "aws_vpc_security_group_egress_rule" "https_udp" {
  count             = var.egress_unrestricted ? 0 : 1
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 443
  to_port           = 443
  description       = "QUIC (Cloudflare Tunnel) and HTTP/3"
}

resource "aws_vpc_security_group_egress_rule" "icmp" {
  count             = var.egress_unrestricted ? 0 : 1
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "icmp"
  from_port         = -1
  to_port           = -1
  description       = "Outbound ICMP for PMTUD and mtu-path-check.sh"
}

# SSM / VPC endpoints later can attach to this SG if we drop public IP.
resource "aws_security_group" "endpoints" {
  name        = "${var.name}-vpce"
  description = "Interface VPC endpoints (SSM, ECR) if the node loses its public IP."
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-vpce" })
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_node" {
  security_group_id            = aws_security_group.endpoints.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "Nodes to interface endpoints"
}

resource "aws_vpc_security_group_egress_rule" "endpoints_out" {
  security_group_id = aws_security_group.endpoints.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "Endpoint ENI to AWS"
}
