# VPC with a CIDR that will not collide with Tailscale, WARP, or the usual
# 10.0.0.0/16 office / default-VPC leftover.
#
# MTU is pinned at 1500. Jumbo frames plus Cloudflare Tunnel / Tailscale
# is an MTU black hole waiting for a large POST. See docs/postmortem-example.md.

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # 10.42.0.0/16
  #   public  : 10.42.0.0/24, 10.42.1.0/24, ...
  #   private : 10.42.10.0/24, 10.42.11.0/24, ...
  public_cidrs  = [for i in range(var.az_count) : cidrsubnet(var.cidr, 8, i)]
  private_cidrs = [for i in range(var.az_count) : cidrsubnet(var.cidr, 8, i + 10)]
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  instance_tenancy     = "default"

  # AWS VPC default MTU is 1500. Do not raise it on the instance ENI.
  # Jumbo (9001) plus Cloudflare Tunnel / Tailscale is an MTU black hole.
  # var.jumbo_frames is validated to false; it exists so a future PR has
  # to argue with the variable, not with a comment.
  tags = merge(var.tags, {
    Name = "${var.name}-vpc"
  })
}

resource "aws_default_network_acl" "lockdown" {
  default_network_acl_id = aws_vpc.this.default_network_acl_id
  # No subnet associations on the default NACL after we create our own.
  # Explicit deny-all so a forgotten subnet is closed.
  tags = merge(var.tags, { Name = "${var.name}-default-nacl-unused" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-igw" })
}

resource "aws_subnet" "public" {
  count                   = var.az_count
  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false # never auto-assign; compute module decides
  tags = merge(var.tags, {
    Name = "${var.name}-public-${local.azs[count.index]}"
    Tier = "public"
  })
}

resource "aws_subnet" "private" {
  count             = var.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags = merge(var.tags, {
    Name = "${var.name}-private-${local.azs[count.index]}"
    Tier = "private"
  })
}

# ----- routing -----
# Public subnets: IGW. Used either for the node itself (cost path) or for a
# NAT instance / NAT Gateway (strict path).
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-public-rt" })
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private subnets: local only, plus optional NAT.
resource "aws_route_table" "private" {
  count  = var.az_count
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-private-rt-${local.azs[count.index]}" })
}

resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? var.az_count : 0
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name}-nat-eip-${count.index}" })
}

resource "aws_nat_gateway" "this" {
  count         = var.enable_nat_gateway ? var.az_count : 0
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = merge(var.tags, { Name = "${var.name}-nat-${local.azs[count.index]}" })
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route" "private_default" {
  count                  = var.enable_nat_gateway ? var.az_count : 0
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[count.index].id
}

resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ----- NACLs -----
# Stateless seatbelt. Deny well-known inbound listeners from the world even
# if a security group is later opened by mistake. Allow ephemeral return
# traffic and ICMP dest-unreach (PMTUD — see postmortem).

resource "aws_network_acl" "public" {
  vpc_id     = aws_vpc.this.id
  subnet_ids = aws_subnet.public[*].id
  tags       = merge(var.tags, { Name = "${var.name}-public-nacl" })
}

# Deny inbound SSH / HTTP / HTTPS / RDP from the world (evaluated first).
resource "aws_network_acl_rule" "public_deny_ssh" {
  network_acl_id = aws_network_acl.public.id
  rule_number    = 50
  egress         = false
  protocol       = "tcp"
  rule_action    = "deny"
  cidr_block     = "0.0.0.0/0"
  from_port      = 22
  to_port        = 22
}

resource "aws_network_acl_rule" "public_deny_http" {
  network_acl_id = aws_network_acl.public.id
  rule_number    = 51
  egress         = false
  protocol       = "tcp"
  rule_action    = "deny"
  cidr_block     = "0.0.0.0/0"
  from_port      = 80
  to_port        = 80
}

resource "aws_network_acl_rule" "public_deny_https" {
  network_acl_id = aws_network_acl.public.id
  rule_number    = 52
  egress         = false
  protocol       = "tcp"
  rule_action    = "deny"
  cidr_block     = "0.0.0.0/0"
  from_port      = 443
  to_port        = 443
}

resource "aws_network_acl_rule" "public_deny_rdp" {
  network_acl_id = aws_network_acl.public.id
  rule_number    = 53
  egress         = false
  protocol       = "tcp"
  rule_action    = "deny"
  cidr_block     = "0.0.0.0/0"
  from_port      = 3389
  to_port        = 3389
}

# ICMP dest-unreach (type 3) and time-exceeded (type 11) for PMTUD / traceroute.
resource "aws_network_acl_rule" "public_in_icmp_unreach" {
  network_acl_id = aws_network_acl.public.id
  rule_number    = 90
  egress         = false
  protocol       = "icmp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  icmp_type      = 3
  icmp_code      = -1
}

resource "aws_network_acl_rule" "public_in_icmp_texceed" {
  network_acl_id = aws_network_acl.public.id
  rule_number    = 91
  egress         = false
  protocol       = "icmp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  icmp_type      = 11
  icmp_code      = -1
}

# Ephemeral return traffic for outbound-initiated flows.
resource "aws_network_acl_rule" "public_in_ephemeral" {
  network_acl_id = aws_network_acl.public.id
  rule_number    = 100
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 1024
  to_port        = 65535
}

resource "aws_network_acl_rule" "public_in_ephemeral_udp" {
  network_acl_id = aws_network_acl.public.id
  rule_number    = 110
  egress         = false
  protocol       = "udp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 1024
  to_port        = 65535
}

resource "aws_network_acl_rule" "public_out_all" {
  network_acl_id = aws_network_acl.public.id
  rule_number    = 100
  egress         = true
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 0
  to_port        = 0
}

resource "aws_network_acl" "private" {
  vpc_id     = aws_vpc.this.id
  subnet_ids = aws_subnet.private[*].id
  tags       = merge(var.tags, { Name = "${var.name}-private-nacl" })
}

resource "aws_network_acl_rule" "private_in_vpc" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 100
  egress         = false
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = var.cidr
  from_port      = 0
  to_port        = 0
}

resource "aws_network_acl_rule" "private_in_ephemeral" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 110
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 1024
  to_port        = 65535
}

resource "aws_network_acl_rule" "private_in_ephemeral_udp" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 111
  egress         = false
  protocol       = "udp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 1024
  to_port        = 65535
}

resource "aws_network_acl_rule" "private_in_icmp_unreach" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 90
  egress         = false
  protocol       = "icmp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  icmp_type      = 3
  icmp_code      = -1
}

resource "aws_network_acl_rule" "private_out_all" {
  network_acl_id = aws_network_acl.private.id
  rule_number    = 100
  egress         = true
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 0
  to_port        = 0
}

# ----- flow logs to S3 (cheap) not CloudWatch Logs (expensive) -----
resource "aws_s3_bucket" "flow" {
  count  = var.enable_flow_logs ? 1 : 0
  bucket = var.flow_logs_bucket
  tags   = merge(var.tags, { Name = "${var.name}-flow-logs" })
}

resource "aws_s3_bucket_public_access_block" "flow" {
  count                   = var.enable_flow_logs ? 1 : 0
  bucket                  = aws_s3_bucket.flow[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "flow" {
  count  = var.enable_flow_logs ? 1 : 0
  bucket = aws_s3_bucket.flow[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_flow_log" "this" {
  count                    = var.enable_flow_logs ? 1 : 0
  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  log_destination_type     = "s3"
  log_destination          = aws_s3_bucket.flow[0].arn
  max_aggregation_interval = 600
  destination_options {
    file_format                = "parquet"
    per_hour_partition         = true
    hive_compatible_partitions = true
  }
  tags = merge(var.tags, { Name = "${var.name}-flow" })
}

# S3 gateway endpoint is free and keeps image layers / flow logs off NAT.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat([aws_route_table.public.id], aws_route_table.private[*].id)
  tags              = merge(var.tags, { Name = "${var.name}-vpce-s3" })
}
