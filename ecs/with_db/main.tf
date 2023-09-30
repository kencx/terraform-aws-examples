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

  cluster_name = "sample"

  container_name  = "miniflux"
  container_image = "miniflux/miniflux:2.0.36"
  container_port  = 8120

  db_name     = "${local.container_name}-postgres"
  db_username = local.container_name
  db_port     = 5432
  db_password = "miniflux"
  db_url      = "postgres://${local.db_username}:${local.db_password}@${module.db.db_instance_endpoint}/${local.container_name}?sslmode=disable"

  admin_username = "admin"
  admin_pass     = "admin123"
}

data "aws_ssm_parameter" "container_image" {
  name = "/${local.container_name}/container_image"
}

data "aws_secretsmanager_secret" "db_url" {
  arn = aws_secretsmanager_secret.db_url.arn
}

data "aws_secretsmanager_secret" "admin" {
  arn = aws_secretsmanager_secret.admin.arn
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
  public_subnets   = [for i, v in local.azs : cidrsubnet(local.vpc_cidr, 8, i)]
  private_subnets  = [for i, v in local.azs : cidrsubnet(local.vpc_cidr, 8, i + 4)]
  database_subnets = [for i, v in local.azs : cidrsubnet(local.vpc_cidr, 8, i + 8)]

  create_database_subnet_group = true

  # single NAT gateway
  enable_nat_gateway = true
  single_nat_gateway = true

  enable_vpn_gateway = false
}

module "ecs_cluster" {
  source = "terraform-aws-modules/ecs/aws//modules/cluster"

  cluster_name                = local.cluster_name
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

  name        = local.cluster_name
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

  task_exec_ssm_param_arns = [aws_ssm_parameter.container_image.arn]
  task_exec_secret_arns = [
    data.aws_secretsmanager_secret.db_url.arn,
    data.aws_secretsmanager_secret.admin.arn,
  ]

  container_definitions = {
    (local.container_name) = {
      image     = data.aws_ssm_parameter.container_image.value
      cpu       = 1024
      memory    = 2048
      essential = true
      port_mappings = [
        # container and host port must be the same
        {
          name          = local.container_name
          containerPort = local.container_port
          hostPort      = local.container_port
          protocol      = "tcp"
        }
      ]

      secrets = [
        {
          name      = "DATABASE_URL"
          valueFrom = data.aws_secretsmanager_secret.db_url.arn
        },
        {
          name      = "ADMIN_USERNAME"
          valueFrom = "${data.aws_secretsmanager_secret.admin.arn}:username::"
        },
        {
          name      = "ADMIN_PASSWORD"
          valueFrom = "${data.aws_secretsmanager_secret.admin.arn}:password::"
        }
      ]

      environment = [
        {
          name  = "PORT"
          value = local.container_port
        },
        {
          name  = "DEBUG"
          value = 1
        },
        {
          name  = "RUN_MIGRATIONS"
          value = 1
        },
        {
          name  = "POLLING_FREQUENCY"
          value = 1440
        },
        {
          name  = "CREATE_ADMIN"
          value = 1
        },
      ]

      readonly_root_filesystem = false

      # cloudwatch logging is fully managed by Terraform
      enable_cloudwatch_logging   = true
      create_cloudwatch_log_group = true
    }
  }

  load_balancer = {
    service = {
      container_name   = local.container_name
      container_port   = local.container_port
      target_group_arn = element(module.alb.target_group_arns, 0)
    }
  }

  subnet_ids            = module.vpc.private_subnets
  create_security_group = true
  security_group_rules = {
    alb_ingress = {
      type                     = "ingress"
      from_port                = local.container_port
      to_port                  = local.container_port
      protocol                 = "tcp"
      source_security_group_id = module.alb_sg.security_group_id
    }
    db_ingress = {
      type                     = "ingress"
      from_port                = local.db_port
      to_port                  = local.db_port
      protocol                 = "tcp"
      source_security_group_id = module.db_sg.security_group_id
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

  name   = "${local.cluster_name}-service"
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
      name             = "${local.cluster_name}-${local.container_name}"
      backend_protocol = "HTTP"
      backend_port     = 80
      target_type      = "ip"
    },
  ]
}

module "db_sg" {
  source = "terraform-aws-modules/security-group/aws"

  name   = local.db_name
  vpc_id = module.vpc.vpc_id

  ingress_rules       = ["postgresql-tcp"]
  ingress_cidr_blocks = module.vpc.private_subnets_cidr_blocks
}

module "db" {
  source = "terraform-aws-modules/rds/aws"

  identifier = local.db_name

  engine               = "postgres"
  engine_version       = "14"
  family               = "postgres14"
  major_engine_version = "14"
  instance_class       = "db.t3.micro"

  # in GB
  allocated_storage     = 10
  max_allocated_storage = 25

  db_name  = local.container_name
  username = local.db_username
  password = local.db_password
  port     = local.db_port

  # manage master password in SSM not supported with replicas
  manage_master_user_password = false

  multi_az               = false
  db_subnet_group_name   = module.vpc.database_subnet_group
  vpc_security_group_ids = [module.db_sg.security_group_id]

  enabled_cloudwatch_logs_exports = ["postgresql"]
  create_cloudwatch_log_group     = true

  # backups required in order to create a replica
  # backup_retention_period = 0
  # skip_final_snapshot     = true
  # deletion_protection     = false

  parameters = [
    {
      name  = "autovacuum"
      value = 1
    },
    {
      name  = "client_encoding"
      value = "utf8"
    }
  ]
}
