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
