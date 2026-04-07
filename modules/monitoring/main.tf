# modules/monitoring/main.tf
# CloudWatch alarms, log groups, dashboard, SNS topics, and failover Lambda

# ── SNS Topic for Failover ────────────────────────────────────────
resource "aws_sns_topic" "failover_trigger" {
  name              = "${var.app_name}-failover-trigger"
  kms_master_key_id = var.kms_key_arn
  tags              = var.tags
}

resource "aws_sns_topic_subscription" "failover_lambda" {
  topic_arn = aws_sns_topic.failover_trigger.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.failover.arn
}

resource "aws_lambda_permission" "sns_failover" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.failover.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.failover_trigger.arn
}

# ── CloudWatch Log Group for Flow Logs ────────────────────────────
resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/vpc/${var.app_name}-${var.environment}/flow-logs"
  retention_in_days = 30
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

# ── Failover Orchestrator Lambda ──────────────────────────────────
data "archive_file" "failover_lambda" {
  type        = "zip"
  output_path = "${path.module}/failover_lambda.zip"
  source_file = "${path.root}/../../scripts/failover_lambda.py"
}

resource "aws_lambda_function" "failover" {
  function_name    = "${var.app_name}-failover-orchestrator"
  role             = var.failover_lambda_role_arn
  runtime          = "python3.12"
  handler          = "failover_lambda.handler"
  timeout          = 900   # 15 minutes — Aurora promotion can take time
  memory_size      = 256

  filename         = data.archive_file.failover_lambda.output_path
  source_code_hash = data.archive_file.failover_lambda.output_base64sha256

  environment {
    variables = {
      GLOBAL_CLUSTER_ID  = var.global_cluster_id
      DR_CLUSTER_ARN     = var.dr_cluster_arn
      DR_CLUSTER_ID      = var.dr_cluster_id
      ECS_CLUSTER        = var.ecs_cluster_name
      ECS_SERVICE        = var.ecs_service_name
      PROD_TASK_COUNT    = tostring(var.prod_task_count)
      APP_NAME           = var.app_name
      DR_REGION          = var.dr_region
      NOTIFICATION_TOPIC = aws_sns_topic.failover_trigger.arn
    }
  }

  kms_key_arn = var.kms_key_arn

  tracing_config {
    mode = "Active"
  }

  tags = merge(var.tags, { Name = "${var.app_name}-failover-orchestrator" })
}

resource "aws_cloudwatch_log_group" "failover_lambda" {
  name              = "/aws/lambda/${aws_lambda_function.failover.function_name}"
  retention_in_days = 90
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

# ── CloudWatch Alarms ─────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "aurora_replication_lag" {
  count               = var.is_primary ? 0 : 1
  alarm_name          = "${var.app_name}-aurora-replication-lag"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "AuroraGlobalDBReplicationLag"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 5000  # 5 seconds in milliseconds

  dimensions = {
    DBClusterIdentifier = var.dr_cluster_id
  }

  alarm_description = "Aurora Global DB replication lag exceeded 5 seconds — data loss risk increasing"
  alarm_actions     = [aws_sns_topic.failover_trigger.arn]
  tags              = var.tags
}

resource "aws_cloudwatch_metric_alarm" "ecs_cpu_high" {
  alarm_name          = "${var.app_name}-${var.environment}-ecs-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 5
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 85

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  alarm_description = "ECS service CPU sustained above 85%"
  alarm_actions     = [var.alert_topic_arn]
  tags              = var.tags
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.app_name}-${var.environment}-alb-5xx-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 50

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_description = "ALB 5xx error count exceeded 50 in 1 minute"
  alarm_actions     = [var.alert_topic_arn]
  tags              = var.tags
}

resource "aws_cloudwatch_metric_alarm" "alb_target_unhealthy" {
  alarm_name          = "${var.app_name}-${var.environment}-alb-unhealthy-hosts"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.tg_arn_suffix
  }

  alarm_description = "One or more ALB targets are unhealthy"
  alarm_actions     = [var.alert_topic_arn]
  tags              = var.tags
}

# ── CloudWatch Dashboard ──────────────────────────────────────────
resource "aws_cloudwatch_dashboard" "dr_overview" {
  dashboard_name = "${var.app_name}-dr-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0; y = 0; width = 12; height = 6
        properties = {
          title   = "Aurora Replication Lag (ms)"
          metrics = [["AWS/RDS", "AuroraGlobalDBReplicationLag", "DBClusterIdentifier", var.dr_cluster_id]]
          period  = 60
          stat    = "Maximum"
          view    = "timeSeries"
          annotations = {
            horizontal = [{ value = 5000, label = "Alert threshold", color = "#ff0000" }]
          }
        }
      },
      {
        type   = "metric"
        x      = 12; y = 0; width = 12; height = 6
        properties = {
          title   = "Route 53 Health Check Status"
          metrics = [
            ["AWS/Route53", "HealthCheckStatus", "HealthCheckId", var.primary_health_check_id, { label = "Primary" }],
            ["AWS/Route53", "HealthCheckStatus", "HealthCheckId", var.dr_health_check_id, { label = "DR" }]
          ]
          period = 60
          stat   = "Minimum"
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 0; y = 6; width = 8; height = 6
        properties = {
          title   = "ECS Service — Running Tasks"
          metrics = [["ECS/ContainerInsights", "RunningTaskCount", "ServiceName", var.ecs_service_name, "ClusterName", var.ecs_cluster_name]]
          period  = 60
          stat    = "Average"
          view    = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 8; y = 6; width = 8; height = 6
        properties = {
          title   = "ALB — Request Count & 5xx Errors"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix, { label = "Requests", stat = "Sum" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.alb_arn_suffix, { label = "5xx Errors", stat = "Sum", color = "#ff0000" }]
          ]
          period = 60
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 16; y = 6; width = 8; height = 6
        properties = {
          title   = "Aurora DB Connections"
          metrics = [["AWS/RDS", "DatabaseConnections", "DBClusterIdentifier", var.dr_cluster_id]]
          period  = 60
          stat    = "Average"
          view    = "timeSeries"
        }
      }
    ]
  })
}
