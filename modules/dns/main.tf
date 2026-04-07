# modules/dns/main.tf
# Route 53: hosted zone, health checks, failover routing records

data "aws_route53_zone" "main" {
  name = var.domain_name
}

# ── Health Check — Primary ALB ────────────────────────────────────
resource "aws_route53_health_check" "primary_alb" {
  fqdn              = var.primary_alb_dns_name
  port              = 443
  type              = "HTTPS"
  resource_path     = var.health_check_path
  failure_threshold = 3
  request_interval  = 10
  measure_latency   = true
  regions           = ["us-east-1", "eu-west-1", "ap-southeast-1"]

  tags = merge(var.tags, { Name = "${var.app_name}-primary-alb-hc" })
}

# ── Health Check — DR ALB ─────────────────────────────────────────
resource "aws_route53_health_check" "dr_alb" {
  fqdn              = var.dr_alb_dns_name
  port              = 443
  type              = "HTTPS"
  resource_path     = var.health_check_path
  failure_threshold = 3
  request_interval  = 10
  measure_latency   = true
  regions           = ["us-east-1", "eu-west-1", "ap-southeast-1"]

  tags = merge(var.tags, { Name = "${var.app_name}-dr-alb-hc" })
}

# ── API Subdomain — Primary (FAILOVER PRIMARY) ────────────────────
resource "aws_route53_record" "api_primary" {
  zone_id        = data.aws_route53_zone.main.zone_id
  name           = "api.${var.domain_name}"
  type           = "A"
  set_identifier = "primary"

  failover_routing_policy {
    type = "PRIMARY"
  }

  health_check_id = aws_route53_health_check.primary_alb.id

  alias {
    name                   = var.primary_alb_dns_name
    zone_id                = var.primary_alb_zone_id
    evaluate_target_health = true
  }
}

# ── API Subdomain — DR (FAILOVER SECONDARY) ───────────────────────
resource "aws_route53_record" "api_dr" {
  zone_id        = data.aws_route53_zone.main.zone_id
  name           = "api.${var.domain_name}"
  type           = "A"
  set_identifier = "secondary"

  failover_routing_policy {
    type = "SECONDARY"
  }

  health_check_id = aws_route53_health_check.dr_alb.id

  alias {
    name                   = var.dr_alb_dns_name
    zone_id                = var.dr_alb_zone_id
    evaluate_target_health = true
  }
}

# ── SNS Alerts for health check state changes ─────────────────────
resource "aws_sns_topic" "health_check_alerts" {
  name              = "${var.app_name}-health-check-alerts"
  kms_master_key_id = var.kms_key_arn
  tags              = var.tags
}

resource "aws_sns_topic_subscription" "pagerduty" {
  count     = var.pagerduty_endpoint != "" ? 1 : 0
  topic_arn = aws_sns_topic.health_check_alerts.arn
  protocol  = "https"
  endpoint  = var.pagerduty_endpoint
}

resource "aws_sns_topic_subscription" "email_alerts" {
  for_each  = toset(var.alert_emails)
  topic_arn = aws_sns_topic.health_check_alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# ── CloudWatch Alarms for health check failures ───────────────────
resource "aws_cloudwatch_metric_alarm" "primary_health_check_failed" {
  alarm_name          = "${var.app_name}-primary-health-check-failed"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HealthCheckStatus"
  namespace           = "AWS/Route53"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1

  dimensions = {
    HealthCheckId = aws_route53_health_check.primary_alb.id
  }

  alarm_description         = "Primary region health check is failing — failover may be triggered"
  alarm_actions             = [aws_sns_topic.health_check_alerts.arn, var.failover_lambda_topic_arn]
  ok_actions                = [aws_sns_topic.health_check_alerts.arn]
  insufficient_data_actions = [aws_sns_topic.health_check_alerts.arn]
  treat_missing_data        = "breaching"

  tags = var.tags
}
