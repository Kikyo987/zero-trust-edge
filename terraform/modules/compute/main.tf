# Single k3s node. ARM by default (t4g.small). Encrypted gp3, IMDSv2
# required. IAM profile comes from the iam module — this module does
# not mint its own role.
#
# assign_public_ip = true is the cheap path: IGW SNAT, empty public
# inbound SG, no NAT Gateway. Set it false and enable_nat_gateway on
# the VPC module if a policy forbids public addresses on compute.
#
# cloud-init (user_data) installs Docker + k3s. Secrets stay in SSM.

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = [var.ami_name_filter]
  }
  filter {
    name   = "architecture"
    values = [var.architecture]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

resource "aws_eip" "node" {
  count  = var.assign_public_ip ? 1 : 0
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name}-node-eip" })
}

resource "aws_instance" "node" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  iam_instance_profile   = var.instance_profile_name
  key_name               = var.key_name == "" ? null : var.key_name

  associate_public_ip_address = var.assign_public_ip

  ebs_optimized = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_gb
    encrypted             = true
    delete_on_termination = true
    tags                  = merge(var.tags, { Name = "${var.name}-root" })
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 2          # 1 is too low once containerd is in the path
    instance_metadata_tags      = "enabled"
  }

  monitoring = var.detailed_monitoring

  user_data                   = var.user_data
  user_data_replace_on_change = false

  tags = merge(var.tags, {
    Name = "${var.name}-node"
    Role = "k3s"
  })

  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_eip_association" "node" {
  count         = var.assign_public_ip ? 1 : 0
  instance_id   = aws_instance.node.id
  allocation_id = aws_eip.node[0].id
}

# Daily snapshots of the root volume — cheap RPO for k3s sqlite.
resource "aws_iam_role" "dlm" {
  count = var.enable_snapshots ? 1 : 0
  name  = "${var.name}-dlm"
  tags  = var.tags
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "dlm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dlm" {
  count      = var.enable_snapshots ? 1 : 0
  role       = aws_iam_role.dlm[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "node" {
  count              = var.enable_snapshots ? 1 : 0
  description        = "${var.name} k3s root snapshots"
  execution_role_arn = aws_iam_role.dlm[0].arn
  state              = "ENABLED"
  tags               = var.tags

  policy_details {
    resource_types = ["VOLUME"]
    target_tags = {
      Name = "${var.name}-root"
    }
    schedule {
      name = "daily"
      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["03:00"]
      }
      retain_rule {
        count = 7
      }
      copy_tags = true
    }
  }
}
