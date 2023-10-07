terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.19.0"
    }
  }
}

provider "aws" {
  region     = var.aws_region
  access_key = var.access_key
  secret_key = var.secret_key
}

locals {
  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  name      = "sample"
  endpoints = toset(["ssm", "ssmmessages", "ec2messages"])

  user_data = <<-EOT
    #!/bin/bash
    echo "Hello World!"
  EOT
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-kernel-5.10*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

resource "aws_instance" "instance" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t2.micro"

  availability_zone      = element(module.vpc.azs, 0)
  subnet_id              = element(module.vpc.intra_subnets, 0)
  vpc_security_group_ids = [module.security_group.security_group_id]

  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.this.name

  user_data_base64            = base64encode(local.user_data)
  user_data_replace_on_change = true
}

# iam to access SSM
data "aws_iam_policy_document" "this" {
  statement {
    sid     = "EC2AssumeRole"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name                  = local.name
  assume_role_policy    = data.aws_iam_policy_document.this.json
  force_detach_policies = true
}

resource "aws_iam_role_policy_attachment" "this" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.this.name
}

resource "aws_iam_instance_profile" "this" {
  name = local.name
  role = aws_iam_role.this.name

  lifecycle {
    create_before_destroy = true
  }
}

# networking
data "aws_availability_zones" "available" {}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "vpc"
  cidr = local.vpc_cidr
  azs  = local.azs

  # private subnet with no Internet access
  intra_subnets = [for i, v in local.azs : cidrsubnet(local.vpc_cidr, 8, i + 8)]

  enable_nat_gateway = false
  enable_vpn_gateway = false
}

# SSM requires HTTPS outbound traffic to endpoints:
# ec2messages.region.amazonaws.com
# ssm.region.amazonaws.com
# ssmmessages.region.amazonaws.com
module "security_group" {
  source = "terraform-aws-modules/security-group/aws"

  name        = "${local.name}-ec2"
  description = "Security Group for EC2 Instance Egress"
  vpc_id      = module.vpc.vpc_id

  egress_rules = ["https-443-tcp"]
}

# VPC endpoint
data "aws_vpc_endpoint_service" "this" {
  for_each = local.endpoints

  service = each.value

  filter {
    name   = "service-type"
    values = ["Interface"]
  }
}

resource "aws_vpc_endpoint" "this" {
  for_each = local.endpoints

  vpc_id            = module.vpc.vpc_id
  service_name      = data.aws_vpc_endpoint_service.this[each.value].service_name
  vpc_endpoint_type = "Interface"

  security_group_ids  = [aws_security_group.vpc_endpoint.id]
  subnet_ids          = module.vpc.intra_subnets
  private_dns_enabled = true

  timeouts {
    create = "10m"
    update = "10m"
    delete = "10m"
  }
}

resource "aws_security_group" "vpc_endpoint" {
  vpc_id      = module.vpc.vpc_id
  name_prefix = "${local.name}-vpc-endpoints-"
  description = "VPC endpoint security group"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "https_ingress" {
  security_group_id = aws_security_group.vpc_endpoint.id
  protocol          = "tcp"
  from_port         = 443
  to_port           = 443
  type              = "ingress"

  description = "HTTPS from subnets"
  cidr_blocks = module.vpc.intra_subnets_cidr_blocks
}
