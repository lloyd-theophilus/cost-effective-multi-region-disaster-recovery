# modules/dns/variables.tf
variable "app_name"                  { type = string }
variable "domain_name"               { type = string }
variable "primary_alb_dns_name"      { type = string }
variable "primary_alb_zone_id"       { type = string }
variable "dr_alb_dns_name"           { type = string }
variable "dr_alb_zone_id"            { type = string }
variable "health_check_path"         { type = string  default = "/health" }
variable "kms_key_arn"               { type = string }
variable "failover_lambda_topic_arn" { type = string }
variable "alert_emails"              { type = list(string) default = [] }
variable "pagerduty_endpoint"        { type = string  default = "" }
variable "tags"                      { type = map(string) default = {} }

# modules/dns/outputs.tf
output "health_check_alerts_topic_arn" { value = aws_sns_topic.health_check_alerts.arn }
output "primary_health_check_id"       { value = aws_route53_health_check.primary_alb.id }
output "dr_health_check_id"            { value = aws_route53_health_check.dr_alb.id }
