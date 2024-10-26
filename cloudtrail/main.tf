terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.70.0"
    }
  }
}

provider "aws" {
  region     = var.aws_region
  access_key = var.access_key
  secret_key = var.secret_key
}

locals {
  trail_name                = "example"
  s3_bucket_name            = "cloudtrail-logs"
  cloudwatch_log_group_name = "cloudtrail-logs"
  prefix                    = "management"

  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

resource "aws_cloudtrail" "this" {
  name                       = local.trail_name
  enable_logging             = true
  enable_log_file_validation = true

  # send logs to S3
  s3_bucket_name = module.s3_bucket.bucket_id
  s3_key_prefix  = local.prefix

  # send logs to cloudwatch
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_cloudwatch_role.arn
  cloud_watch_logs_group_arn = module.log_group.cloudwatch_log_group_arn

  kms_key_id = module.kms.key_arn

  is_multi_region_trail         = false
  is_organization_trail         = false
  include_global_service_events = false
}

# KMS
module "kms" {
  source  = "terraform-aws-modules/kms/aws"
  version = "~> 3.1.1"

  description = ""
  key_usage   = "ENCRYPT_DECRYPT"

  is_enabled              = true
  multi_region            = false
  deletion_window_in_days = 7

  # policy
  key_administrators = ["arn:aws:iam::012345678901:role/admin"]

  key_statements = [
    # cloudwatch
    # https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/encrypt-log-data-kms.html
    {
      sid = "CloudWatchLogs"
      actions = [
        "kms:Encrypt*",
        "kms:Decrypt*",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:Describe*"
      ]
      resources = ["*"]

      principals = [
        {
          type        = "Service"
          identifiers = ["logs.${var.region}.amazonaws.com"]
        }
      ]

      conditions = [
        {
          test     = "ArnLike"
          variable = "kms:EncryptionContext:aws:logs:arn"
          values = [
            "${module.log_group.cloudwatch_log_group_arn}"
          ]
        }
      ]
    },
    # cloudtrail
    # https://docs.aws.amazon.com/awscloudtrail/latest/userguide/create-kms-key-policy-for-cloudtrail.html
    {
      sid = "AllowCloudTrailToEncryptLogs"
      actions = [
        "kms:GenerateDataKey*",
      ]
      resources = ["*"]

      principals = [
        {
          type        = "Service"
          identifiers = ["cloudtrail.amazonaws.com"]
        }
      ]

      conditions = [
        {
          test     = "StringLike"
          variable = "kms:EncryptionContext:aws:cloudtrail:arn"
          values = [
            "arn:aws:cloudtrail:*:${local.account_id}:trail/*"
          ]
        },
        {
          test     = "StringEquals"
          variable = "aws:SourceArn"
          values = [
            "${aws_cloudtrail.this.arn}"
          ]
        }
      ]
    },
    {
      sid       = "AllowCloudTrailToDescribeKey"
      resources = ["*"]
      actions = [
        "kms:DescribeKey",
      ]

      principals = [
        {
          type        = "Service"
          identifiers = ["cloudtrail.amazonaws.com"]
        }
      ]
    },
    {
      sid       = "AllowCloudTrailDecrypt"
      resources = ["*"]
      actions = [
        "kms:Decrypt",
      ]

      principals = [
        {
          type        = "Service"
          identifiers = ["cloudtrail.amazonaws.com"]
        }
      ]
    },
    {
      sid       = "AllowPrincipalsToDecryptCloudTrailLogFiles"
      resources = ["*"]
      actions = [
        "kms:Decrypt",
        "kms:ReEncryptFrom",
      ]

      principals = {
        type        = "AWS"
        identifiers = ["*"]
      }

      conditions = [
        {
          test     = "StringEquals"
          variable = "kms:CallerAccount"
          values = [
            local.account_id
          ]
        },
        {
          test     = "StringLike"
          variable = "kms:EncryptionContext:aws:cloudtrail:arn"
          values = [
            aws_cloudtrail.this.arn
          ]
        }
      ]
    },
  ]
}

# S3
module "s3_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.2.1"

  bucket        = local.s3_bucket_name
  acl           = "private"
  force_destroy = true

  attach_policy = true
  policy        = data.aws_iam_policy_document.cloudtrail_bucket_policy.json

  versioning = {
    enabled = true
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        kms_master_key_id = module.kms.key_arn
        sse_algorithm     = "aws:kms"
      }
    }
  }

  block_public_acls       = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# https://docs.aws.amazon.com/awscloudtrail/latest/userguide/create-s3-bucket-policy-for-cloudtrail.html
data "aws_iam_policy_document" "cloudtrail_bucket_policy" {
  statement {
    sid    = "AWSCloudTrailAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions = [
      "s3:GetBucketAcl"
    ]

    resources = [module.s3_bucket.s3_bucket_arn]

    # optional condition to allow specific trails
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values = [
        "arn:${local.partition}:cloudtrail:${var.region}:${local.account_id}:trail/${local.trail_name}"
      ]
    }
  }

  statement {
    sid    = "AWSCloudTrailWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions = ["s3:PutObject"]
    resources = [
      "${module.s3_bucket_arn}/${local.prefix}/AWSLogs/${local.account_id}/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
    # optional condition to allow specific trails
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values = [
        "arn:${local.partition}:cloudtrail:${var.region}:${local.account_id}:trail/${local.trail_name}"
      ]
    }
  }
}

# CloudWatch
module "log_group" {
  source  = "terraform-aws-modules/cloudwatch/aws//modules/log-group"
  version = "~> 5.6.1"

  name              = local.cloudwatch_log_group_name
  retention_in_days = 7
  kms_key_id        = module.kms.key_arn
}

# role for CloudTrail to send logs to CloudWatch
resource "aws_iam_role" "cloudtrail_cloudwatch_role" {
  name               = "cloudtrail-cloudwatch-${local.trail_name}"
  assume_role_policy = data.aws_iam_policy_document.cloudtrail_cloudwatch_logs.json
}

# https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-required-policy-for-cloudwatch-logs.html
data "aws_iam_policy_document" "cloudtrail_cloudwatch_logs" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }

  statement {
    sid    = "WriteCloudWatchLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = [
      "${module.log_group.cloudwatch_log_group_arn}:log-stream:*"
    ]
  }
}
