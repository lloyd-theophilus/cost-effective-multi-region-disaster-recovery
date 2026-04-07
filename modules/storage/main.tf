# modules/storage/main.tf
# S3 buckets with versioning, CRR, and lifecycle policies

# ── Primary Application Bucket ────────────────────────────────────
resource "aws_s3_bucket" "app" {
  bucket        = "${var.app_name}-${var.environment}-${var.aws_account_id}-app"
  force_destroy = var.force_destroy
  tags          = merge(var.tags, { Name = "${var.app_name}-${var.environment}-app" })
}

resource "aws_s3_bucket_versioning" "app" {
  bucket = aws_s3_bucket.app.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "app" {
  bucket = aws_s3_bucket.app.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "app" {
  bucket                  = aws_s3_bucket.app.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "app" {
  bucket = aws_s3_bucket.app.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "intelligent-tiering"
    status = "Enabled"
    transition {
      days          = 30
      storage_class = "INTELLIGENT_TIERING"
    }
  }
}

# ── Cross-Region Replication (primary → DR) ───────────────────────
resource "aws_s3_bucket_replication_configuration" "app" {
  count  = var.is_primary && var.dr_bucket_arn != "" ? 1 : 0
  bucket = aws_s3_bucket.app.id
  role   = var.replication_role_arn

  rule {
    id     = "replicate-all"
    status = "Enabled"

    destination {
      bucket        = var.dr_bucket_arn
      storage_class = "STANDARD_IA"

      replication_time {
        status  = "Enabled"
        time {
          minutes = 15
        }
      }

      metrics {
        status = "Enabled"
        event_threshold {
          minutes = 15
        }
      }

      encryption_configuration {
        replica_kms_key_id = var.dr_kms_key_arn
      }
    }

    delete_marker_replication {
      status = "Enabled"
    }
  }

  depends_on = [aws_s3_bucket_versioning.app]
}

# ── ALB Access Logs Bucket ────────────────────────────────────────
resource "aws_s3_bucket" "alb_logs" {
  bucket        = "${var.app_name}-${var.environment}-${var.aws_account_id}-alb-logs"
  force_destroy = var.force_destroy
  tags          = merge(var.tags, { Name = "${var.app_name}-${var.environment}-alb-logs" })
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowALBLogs"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.elb_account_id}:root"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.alb_logs.arn}/*/AWSLogs/*"
      }
    ]
  })
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    id     = "expire-logs"
    status = "Enabled"
    expiration {
      days = 90
    }
  }
}
