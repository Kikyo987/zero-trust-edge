# Dev environment — one VPC, one IAM profile, one node.
# cloud-init installs Docker and k3s. Review the plan for:
#   - 0 NAT Gateways unless you opted in
#   - 0 inbound TCP from 0.0.0.0/0
#   - kube-apiserver 6443 sourced from the node SG only
#   - http_tokens = required

locals {
  tags = {
    Project     = var.project
    Environment = "dev"
  }

  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    project        = var.project
    k3s_version    = var.k3s_version
    cluster_cidr   = var.cluster_cidr
    service_cidr   = var.service_cidr
    app_image      = var.app_image
    app_hostname   = var.app_hostname
    manifests_repo = var.manifests_repo
  })
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

module "iam" {
  source  = "../../modules/iam"
  name    = "${var.project}-dev"
  project = var.project
  tags    = local.tags
}

module "compute" {
  source                = "../../modules/compute"
  name                  = "${var.project}-dev"
  subnet_id             = var.assign_public_ip ? module.vpc.public_subnet_ids[0] : module.vpc.private_subnet_ids[0]
  security_group_id     = module.security.node_security_group_id
  instance_profile_name = module.iam.instance_profile_name
  instance_type         = var.instance_type
  architecture          = var.architecture
  assign_public_ip      = var.assign_public_ip
  root_volume_gb        = var.root_volume_gb
  user_data             = local.user_data
  tags                  = local.tags
}
