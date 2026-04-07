# modules/security/main.tf
# KMS keys, IAM roles, Secrets Manager, and the failover Lambda

# ── KMS Key ───────────────────────────────────────────────────────
resource "aws_kms_key" "main" {
  description             = "${var.app_name}-${var.environment} encryption key"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  multi_region            = var.is_primary  # Primary key for multi-region replication

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM Policies"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.aws_account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow CloudWatch"
        Effect = "Allow"
        Principal = {
          Service = "cloudwatch.amazonaws.com"
        }
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = "*"
      }
    ]
  })

  tags = merge(var.tags, { Name = "${var.app_name}-${var.environment}-kms" })
}

resource "aws_kms_alias" "main" {
  name          = "alias/${var.app_name}-${var.environment}"
  target_key_id = aws_kms_key.main.key_id
}

# ── ECS Execution Role ────────────────────────────────────────────
resource "aws_iam_role" "ecs_execution" {
  name = "${var.app_name}-${var.environment}-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, { Name = "${var.app_name}-${var.environment}-ecs-execution-role" })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_managed" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "ecs_execution_ssm" {
  name = "ssm-secrets-access"
  role = aws_iam_role.ecs_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ssm:GetParameters", "ssm:GetParameter"]
        Resource = "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/${var.app_name}/${var.environment}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = aws_kms_key.main.arn
      }
    ]
  })
}

# ── ECS Task Role ─────────────────────────────────────────────────
resource "aws_iam_role" "ecs_task" {
  name = "${var.app_name}-${var.environment}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, { Name = "${var.app_name}-${var.environment}-ecs-task-role" })
}

resource "aws_iam_role_policy" "ecs_task_app" {
  name = "app-permissions"
  role = aws_iam_role.ecs_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = ["arn:aws:s3:::${var.app_name}-${var.environment}-*", "arn:aws:s3:::${var.app_name}-${var.environment}-*/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = "arn:aws:sqs:${var.aws_region}:${var.aws_account_id}:${var.app_name}-${var.environment}-*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.main.arn
      }
    ]
  })
}

# ── Lambda Execution Role ─────────────────────────────────────────
resource "aws_iam_role" "lambda" {
  name = "${var.app_name}-${var.environment}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, { Name = "${var.app_name}-${var.environment}-lambda-role" })
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_xray" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# ── Failover Lambda Role (in DR region) ───────────────────────────
resource "aws_iam_role" "failover_lambda" {
  count = var.is_primary ? 0 : 1
  name  = "${var.app_name}-failover-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, { Name = "${var.app_name}-failover-lambda-role" })
}

# ── Failover Lambda Managed Policy (loaded from policies/ directory) ─
# Using aws_iam_policy (managed) instead of aws_iam_role_policy (inline)
# so the policy can be audited, versioned, and re-used independently.
resource "aws_iam_policy" "failover_lambda" {
  count       = var.is_primary ? 0 : 1
  name        = "${var.app_name}-failover-lambda-policy"
  description = "Permissions for the DR failover orchestrator Lambda: Aurora promotion, ECS scale-out, SSM, SNS, CloudWatch, X-Ray, VPC, Route53, ElastiCache."
  path        = "/dr/"

  # Loaded from policies/failover_lambda_policy.json at the repo root.
  # path.root resolves to the calling environment directory (environments/dr),
  # so we walk two levels up to reach the repo root.
  policy = file("${path.root}/../../policies/failover_lambda_policy.json")

  tags = merge(var.tags, { Name = "${var.app_name}-failover-lambda-policy" })
}

resource "aws_iam_role_policy_attachment" "failover_lambda_policy" {
  count      = var.is_primary ? 0 : 1
  role       = aws_iam_role.failover_lambda[0].name
  policy_arn = aws_iam_policy.failover_lambda[0].arn
}

# CloudWatch Logs + VPC access for failover Lambda (AWS managed policies)
resource "aws_iam_role_policy_attachment" "failover_lambda_logs" {
  count      = var.is_primary ? 0 : 1
  role       = aws_iam_role.failover_lambda[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy_attachment" "failover_lambda_xray" {
  count      = var.is_primary ? 0 : 1
  role       = aws_iam_role.failover_lambda[0].name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# ── RDS Enhanced Monitoring Role ──────────────────────────────────
resource "aws_iam_role" "rds_monitoring" {
  name = "${var.app_name}-${var.environment}-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ── S3 Replication Role ───────────────────────────────────────────
resource "aws_iam_role" "s3_replication" {
  count = var.is_primary ? 1 : 0
  name  = "${var.app_name}-s3-replication-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "s3_replication" {
  count = var.is_primary ? 1 : 0
  name  = "s3-replication-policy"
  role  = aws_iam_role.s3_replication[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl", "s3:ListBucket", "s3:GetReplicationConfiguration"]
        Resource = ["arn:aws:s3:::${var.app_name}-primary-*", "arn:aws:s3:::${var.app_name}-primary-*/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"]
        Resource = "arn:aws:s3:::${var.app_name}-dr-*/*"
      }
    ]
  })
}

# ── VPC Flow Logs Role ────────────────────────────────────────────
resource "aws_iam_role" "vpc_flow_logs" {
  name = "${var.app_name}-${var.environment}-vpc-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "vpc_flow_logs" {
  name = "flow-logs-policy"
  role = aws_iam_role.vpc_flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams"]
      Resource = "*"
    }]
  })
}

# ── Secrets Manager ───────────────────────────────────────────────
resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "${var.app_name}/${var.environment}/db/credentials"
  description             = "Aurora master credentials"
  kms_key_id              = aws_kms_key.main.arn
  recovery_window_in_days = 30
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = var.db_master_username
    password = var.db_master_password
    host     = "PLACEHOLDER_SET_BY_DATABASE_MODULE"
    dbname   = var.database_name
    port     = 5432
  })

  lifecycle {
    ignore_changes = [secret_string]  # Rotated externally
  }
}
