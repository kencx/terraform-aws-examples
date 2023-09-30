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
}

data "aws_availability_zones" "available" {}


module "vpc" {
  # https://github.com/terraform-aws-modules/terraform-aws-vpc/tree/master
  source = "terraform-aws-modules/vpc/aws"

  name = "vpc"
  cidr = local.vpc_cidr
  azs  = local.azs

  # calculate subnet address within given IP network address prefix
  # cidrsubnet(prefix, newbits, netnum)
  public_subnets  = [for i, v in local.azs : cidrsubnet(local.vpc_cidr, 8, i)]
  private_subnets = [for i, v in local.azs : cidrsubnet(local.vpc_cidr, 8, i + 4)]

  # single NAT gateway
  enable_nat_gateway = true
  single_nat_gateway = true

  enable_vpn_gateway = false
}

module "ecs_cluster" {
  source = "terraform-aws-modules/ecs/aws//modules/cluster"

  cluster_name                = var.cluster_name
  create_cloudwatch_log_group = true

  # map of fargate capacity provider definitions
  # not using autoscaling_capacity_providers map
  default_capacity_provider_use_fargate = true
  fargate_capacity_providers = {
    FARGATE = {
      default_capacity_provider_strategy = {
        weight = 50
        base   = 5
      }
    }
  }
}

module "ecs_service" {
  source = "terraform-aws-modules/ecs/aws//modules/service"

  name        = var.service_name
  cluster_arn = module.ecs_cluster.arn

  cpu    = 1024
  memory = 2048

  # defaults
  # launch_type = "FARGATE"
  # platform_version = "LATEST"
  # network_mode = "awsvpc"

  # lifecycle changes for desired_count are always ignored
  # https://github.com/terraform-aws-modules/terraform-aws-ecs/blob/master/docs/README.md#service-1
  # desired_count = 1

  container_definitions = {
    (var.container_name) = {
      image     = var.container_image
      cpu       = 512
      memory    = 1024
      essential = true
      port_mappings = [
        {
          name          = var.container_name
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
        }
      ]

      readonly_root_filesystem = false

      # cloudwatch logging is fully managed by Terraform
      enable_cloudwatch_logging   = true
      create_cloudwatch_log_group = true
    }
  }

  load_balancer = {
    service = {
      container_name   = var.container_name
      container_port   = var.container_port
      target_group_arn = element(module.alb.target_group_arns, 0)
    }
  }

  subnet_ids            = module.vpc.private_subnets
  create_security_group = true
  security_group_rules = {
    alb_ingress = {
      type                     = "ingress"
      from_port                = var.container_port
      to_port                  = var.container_port
      protocol                 = "tcp"
      source_security_group_id = module.alb_sg.security_group_id
    }
    egress_all = {
      type        = "egress"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
}

module "alb_sg" {
  source = "terraform-aws-modules/security-group/aws"

  name   = "${var.service_name}-service"
  vpc_id = module.vpc.vpc_id

  ingress_rules       = ["http-80-tcp"]
  ingress_cidr_blocks = ["0.0.0.0/0"]

  egress_rules       = ["all-all"]
  egress_cidr_blocks = module.vpc.private_subnets_cidr_blocks
}

module "alb" {
  source = "terraform-aws-modules/alb/aws"

  load_balancer_type = "application"
  vpc_id             = module.vpc.vpc_id
  subnets            = module.vpc.public_subnets
  security_groups    = [module.alb_sg.security_group_id]

  http_tcp_listeners = [
    {
      port               = 80
      protocol           = "HTTP"
      target_group_index = 0
    },
  ]

  target_groups = [
    {
      name             = "${var.service_name}-${var.container_name}"
      backend_protocol = "HTTP"
      backend_port     = 80
      target_type      = "ip"
    },
  ]
}
