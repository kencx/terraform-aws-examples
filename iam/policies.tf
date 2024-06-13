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

resource "aws_iam_policy" "ProjectTag" {
  name        = "project_tag"
  path        = "/"
  description = "Only run, modify or create resources with specified project tag"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRunInstances"
        Effect = "Allow"
        Action = [
          "ec2:RunInstances"
        ]
        Resource = [
          "arn:aws:ec2:*::image/ami-*",
          "arn:aws:ec2:*:*:network-interface/*",
          "arn:aws:ec2:*:*:volume/*",
        ]
      },
      {
        Sid    = "AllowRunInstancesResourceTag"
        Effect = "Allow"
        Action = [
          "ec2:RunInstances"
        ]
        Resource = [
          "arn:aws:ec2:*:*:key-pair/*",
          "arn:aws:ec2:*:*:subnet/*",
          "arn:aws:ec2:*:*:security-group/*",
          "arn:aws:ec2:*:*:snapshot/*",
        ]
        Condition = {
          "StringEquals" = {
            "aws:ResourceTag/Project" = "${var.project}"
          }
        }
      },
      {
        Sid    = "AllowRunInstancesRequestTag"
        Effect = "Allow"
        Action = [
          "ec2:RunInstances"
        ]
        Resource = [
          "arn:aws:ec2:*:*:instance/*",
        ]
        Condition = {
          "StringEquals" = {
            "aws:RequestTag/Project" = "${var.project}"
          }
        }
      },
      {
        Sid    = "AllowNotInViewOnly"
        Effect = "Allow"
        Action = [
          "secretsmanager:ListSecrets",
          "ec2:DescribeEgressOnlyInternetGateways",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowCreateTags"
        Effect = "Allow"
        Action = [
          "ec2:CreateTags"
        ]
        Resource = "*"
        Condition = {
          "StringEquals" = {
            "ec2:CreateAction" = [
              "RunInstances",
              "CreateKeyPair",
              "CreateNetworkInterface",
              "CreateRoute",
              "CreateRouteTable",
              "CreateSecurityGroup",
              "CreateSnapshot",
              "CreateSubnet",
              "CreateVolume",
              "CreateVPC",
              "CreateVpcPeeringConnection",
              "AllocateAddress",
            ]
          }
        }
      },
      {
        Sid      = "AllowForProjectTag"
        Effect   = "Allow"
        Action   = ["*"]
        Resource = "*"
        Condition = {
          "StringEquals" = {
            "aws:ResourceTag/Project" = "${var.project}"
          }
        }
      },
    ]
  })
}
