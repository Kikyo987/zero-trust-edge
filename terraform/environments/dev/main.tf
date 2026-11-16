# Dev environment — one VPC, one node, zero public inbound ports.
# Read terraform plan and confirm:
#   - aws_vpc_security_group_ingress_rule.node has no 0.0.0.0/0 TCP
#   - aws_nat_gateway count is 0 unless you opted in
#   - instance metadata http_tokens = required

locals {
  tags = {
    Project     = var.project
    Environment = "dev"
  }
}

module "vpc" {
  source             = "../../modules/vpc"
  name               = "${var.project}-dev"
  cidr               = var.vpc_cidr
  region             = var.region
  az_count           = 2
  enable_nat_gateway = var.enable_nat_gateway
  enable_flow_logs   = true
  flow_logs_bucket   = var.flow_logs_bucket
  tags               = local.tags
}

module "security" {
  source              = "../../modules/security"
  name                = "${var.project}-dev"
  vpc_id              = module.vpc.vpc_id
  egress_unrestricted = var.egress_unrestricted
  tags                = local.tags
}

module "compute" {
  source            = "../../modules/compute"
  name              = "${var.project}-dev"
  subnet_id         = var.assign_public_ip ? module.vpc.public_subnet_ids[0] : module.vpc.private_subnet_ids[0]
  security_group_id = module.security.node_security_group_id
  instance_type     = var.instance_type
  architecture      = var.architecture
  assign_public_ip  = var.assign_public_ip
  root_volume_gb    = var.root_volume_gb
  user_data         = file("${path.module}/user-data.sh")
  tags              = local.tags
}
