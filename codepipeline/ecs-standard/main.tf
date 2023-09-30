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
  account_id   = var.account_id
  name         = "catpipeline"
  cluster_name = module.ecs.cluster_name
  service_name = module.ecs.service_name
}

module "ecs" {
  source = "../../ecs/simple"

  aws_region = var.aws_region
  access_key = var.access_key
  secret_key = var.secret_key

  container_name  = local.name
  container_image = "${local.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${local.name}"
  container_port  = 80
}

# SSH key
resource "tls_private_key" "this" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.this.private_key_pem
  filename        = "${path.module}/${local.name}.pem"
  file_permission = "0600"
}

resource "local_file" "public_key" {
  content         = tls_private_key.this.public_key_pem
  filename        = "${path.module}/${local.name}.pub"
  file_permission = "0644"
}

resource "local_file" "ssh_config" {
  content         = <<EOF
Host git-codecommit.*.amazonaws.com
    User ${aws_iam_user_ssh_key.this.ssh_public_key_id}
    IdentityFile ../${local.name}.pem
EOF
  filename        = "${path.module}/ssh_config"
  file_permission = "0644"
}

# IAM
resource "aws_iam_user" "this" {
  name = local.name
  path = "/"
}

resource "aws_iam_user_ssh_key" "this" {
  username   = aws_iam_user.this.name
  encoding   = "SSH"
  public_key = tls_private_key.this.public_key_openssh
}

resource "aws_iam_user_policy" "this" {
  name   = local.name
  user   = aws_iam_user.this.name
  policy = data.aws_iam_policy_document.codecommit.json
}

data "aws_iam_policy_document" "codecommit" {
  statement {
    effect = "Allow"

    actions = [
      "codecommit:GitPush",
      "codecommit:GitPull"
    ]

    resources = ["*"]
  }
}

# codecommit
resource "aws_codecommit_repository" "this" {
  repository_name = local.name
  description     = "Sample repository for Cat Pipeline"
}

# ecr
resource "aws_ecr_repository" "this" {
  name                 = local.name
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# codebuild
# TODO add S3 cache
data "aws_iam_policy_document" "codebuild-role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "codebuild-role" {
  name               = "codebuild-role"
  assume_role_policy = data.aws_iam_policy_document.codebuild-role.json
}

data "aws_iam_policy_document" "permissions" {
  statement {
    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "codecommit:GitPull",
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:GetAuthorizationToken",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecs:RunTask",
      "iam:PassRole",
      "ssm:GetParameters",
      "secretsmanager:GetSecretValue",
    ]

    resources = ["*"]
  }

  statement {
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:GetBucketVersioning",
      "s3:PutObjectAcl",
      "s3:PutObject",
    ]

    resources = [
      aws_s3_bucket.codepipeline.arn,
      "${aws_s3_bucket.codepipeline.arn}/*"
    ]
  }
}

resource "aws_iam_role_policy" "codebuild-permissions" {
  role   = aws_iam_role.codebuild-role.name
  policy = data.aws_iam_policy_document.permissions.json
}

resource "aws_codebuild_project" "this" {
  name          = "${local.name}-build"
  build_timeout = "5"
  service_role  = aws_iam_role.codebuild-role.arn

  source {
    type     = "CODEPIPELINE"
    location = aws_codecommit_repository.this.clone_url_http
  }

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:2.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true

    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = var.aws_region
    }
    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = local.account_id
    }
    environment_variable {
      name  = "IMAGE_TAG"
      value = "latest"
    }
    environment_variable {
      name  = "IMAGE_REPO_NAME"
      value = local.name
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "a4l-codebuild"
      stream_name = local.name
    }
  }
}

# codepipeline
data "aws_iam_policy_document" "codepipeline-role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com", "codedeploy.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "codepipeline-role" {
  name               = "codepipeline-role"
  assume_role_policy = data.aws_iam_policy_document.codepipeline-role.json
}

data "aws_iam_policy_document" "codepipeline" {
  statement {
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:GetBucketVersioning",
      "s3:PutObjectAcl",
      "s3:PutObject",
    ]

    resources = [
      aws_s3_bucket.codepipeline.arn,
      "${aws_s3_bucket.codepipeline.arn}/*"
    ]
  }

  statement {
    effect = "Allow"

    actions = [
      "codecommit:CancelUploadArchive",
      "codecommit:GetBranch",
      "codecommit:GetCommit",
      "codecommit:GetUploadArchiveStatus",
      "codecommit:UploadArchive",
      "codebuild:BatchGetBuilds",
      "codebuild:StartBuild",
      "codedeploy:CreateDeployment",
      "codedeploy:GetApplicationRevision",
      "codedeploy:GetDeployment",
      "codedeploy:GetDeploymentConfig",
      "codedeploy:RegisterApplicationRevision"
    ]

    resources = ["*"]
  }

  statement {
    sid = ""

    actions = [
      "ec2:*",
      "cloudwatch:*",
      "s3:*",
      "sns:*",
      "iam:PassRole",
      "ecs:*",
    ]

    resources = ["*"]
    effect    = "Allow"
  }

  # statement {
  #   effect = "Allow"
  #
  #   actions = [
  #     "kms:DescribeKey",
  #     "kms:GenerateDataKey*",
  #     "kms:Encrypt",
  #     "kms:ReEncrypt*",
  #     "kms:Decrypt"
  #   ]
  #
  #   resources = ["${aws_kms_key}"]
  # }
}

resource "aws_iam_role_policy" "codepipeline" {
  role   = aws_iam_role.codepipeline-role.name
  policy = data.aws_iam_policy_document.codepipeline.json
}

resource "aws_codepipeline" "this" {
  name     = local.name
  role_arn = aws_iam_role.codepipeline-role.arn

  artifact_store {
    location = aws_s3_bucket.codepipeline.bucket
    type     = "S3"

    # encryption_key {
    #   id   = data.aws_kms_alias.s3kmskey.arn
    #   type = "KMS"
    # }
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeCommit"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        RepositoryName = local.name
        BranchName     = "master"
        # If false, use CloudWatch Events rule to detect source changes
        PollForSourceChanges = "true"
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]
      version          = "1"

      configuration = {
        ProjectName = aws_codebuild_project.this.name
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name     = "Deploy"
      category = "Deploy"
      owner    = "AWS"
      # ECS CodeDeploy deployments are performed with "ECS", not "CodeDeploy"
      # Not to be confused with "CodeDeployToECS" which requires blue-green deployments
      # https://stackoverflow.com/questions/48955491/codepipeline-insufficient-permissions-unable-to-access-the-artifact-with-amazon
      provider        = "ECS"
      input_artifacts = ["build_output"]
      version         = "1"

      configuration = {
        ClusterName = local.cluster_name
        ServiceName = local.service_name
        FileName    = "imagedefinitions.json"
      }
    }
  }
}

resource "aws_s3_bucket" "codepipeline" {
  bucket        = "${local.name}-bucket"
  force_destroy = true
}

# data "aws_kms_alias" "s3kmskey" {
#   name = "alias/myKmsKey"
# }

output "clone_url" {
  value = aws_codecommit_repository.this.clone_url_ssh
}
