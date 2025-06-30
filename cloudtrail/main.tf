#################################
# 0) Provider & Identity
#################################
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
}

/* 追加：自アカウント番号を取得するデータソース  */
data "aws_caller_identity" "current" {}

#################################
# 1) S3 – CloudTrail ログバケット
#################################
resource "aws_s3_bucket" "cloudtrail_log" {
  bucket        = "${var.project}-cloudtrail-log"
  force_destroy = false

  tags = {
    Name        = "${var.project}-cloud-trail"
    Environment = var.environment
  }

  /* Terraform が誤って削除しようとした場合に検知して失敗させる */
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [tags_all]
  }
}

resource "aws_s3_bucket_ownership_controls" "cloudtrail_log" {
  bucket = aws_s3_bucket.cloudtrail_log.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_versioning" "cloudtrail_log" {
  bucket = aws_s3_bucket.cloudtrail_log.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail_log" {
  bucket = aws_s3_bucket.cloudtrail_log.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail_log" {
  bucket = aws_s3_bucket.cloudtrail_log.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail_log" {
  bucket = aws_s3_bucket.cloudtrail_log.id
  rule {
    id     = "expire-logs"
    status = "Enabled"
    filter { prefix = "" } # 空 prefix が必須
    expiration { days = 365 }
  }
}

#################################
# 2) バケットポリシー（CloudTrail 書き込み許可）
#################################
resource "aws_s3_bucket_policy" "cloudtrail_log" {
  bucket = aws_s3_bucket.cloudtrail_log.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      # Cloud Trailがログ書き込み前にS3のACLを確認するため
      {
        Sid       = "AWSCloudTrailAclCheck",
        Effect    = "Allow",
        Principal = { Service = "cloudtrail.amazonaws.com" },
        Action    = "s3:GetBucketAcl",
        Resource  = aws_s3_bucket.cloudtrail_log.arn
      },
      # CloudTrailがログ書き込みを可能にする
      {
        Sid       = "AWSCloudTrailWrite",
        Effect    = "Allow",
        Principal = { Service = "cloudtrail.amazonaws.com" },
        Action    = "s3:PutObject",
        Resource  = "${aws_s3_bucket.cloudtrail_log.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*",
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      },
      # TerraformユーザがPlan・Apply時にS3バケットの状態を確認するために必要
      {
        Sid       = "AllowTerraformAdminAccessForTerraformPlan",
        Effect    = "Allow",
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/terraform-admin"
        },
        Action    = [
          "s3:GetBucketOwnershipControls",
          "s3:GetBucketVersioning",
          "s3:GetEncryptionConfiguration",
          "s3:GetBucketPolicy",
          "s3:GetLifecycleConfiguration",
          "s3:GetBucketPublicAccessBlock"
        ],
        Resource = aws_s3_bucket.cloudtrail_log.arn
      }
    ]
  })
}

#################################
# 3) CloudTrail 本体
#################################
resource "aws_cloudtrail" "main" {
  name                          = "${var.project}-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail_log.bucket
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_logging                = true
  # enable_log_file_validation = true
  # ここを設定するとS3バケットポリシーが適用された後に
  # CoudTrailが作成される
  depends_on                    = [aws_s3_bucket_policy.cloudtrail_log]
  tags = {
    Name        = "${var.project}-trail"
    Environment = var.environment
  }

  lifecycle {
    # 以下の変更は無視する
    # AWSによる自動変更や、手動オペレーションによってTerraformと
    # 状態がずれてもTerraform Apply時に無視できる
    ignore_changes = [
      tags_all, 
      enable_logging
      ]
  }
  event_selector {
    # 読み取りあきとりどちらも記録する
    read_write_type = "WriteOnly"
    # 管理イベント(＝リソースの作成)を記録
    # データの更新などは追わない。
    include_management_events = true
    # CloudTrail自体がログを保存する操作のログは取得しない
    # →無限ループに陥るため。
    # exclude_management_event_sources = [
    #   "cloudtrail.amazonaws.com"
    # ]
  }
}
