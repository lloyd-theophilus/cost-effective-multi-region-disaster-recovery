# modules/monitoring/variables.tf
variable "app_name"                  { type = string }
variable "environment"               { type = string }
variable "is_primary"                { type = bool    default = true }
variable "dr_region"                 { type = string }
variable "kms_key_arn"               { type = string }
variable "failover_lambda_role_arn"  { type = string }
variable "global_cluster_id"         { type = string  default = "" }
variable "dr_cluster_arn"            { type = string  default = "" }
variable "dr_cluster_id"             { type = string  default = "" }
variable "ecs_cluster_name"          { type = string }
variable "ecs_service_name"          { type = string }
variable "prod_task_count"           { type = number  default = 4 }
variable "alb_arn_suffix"            { type = string }
variable "tg_arn_suffix"             { type = string  default = "" }
variable "primary_health_check_id"   { type = string  default = "" }
variable "dr_health_check_id"        { type = string  default = "" }
variable "alert_topic_arn"           { type = string }
variable "tags"                      { type = map(string) default = {} }

# modules/monitoring/outputs.tf
output "failover_trigger_topic_arn"  { value = aws_sns_topic.failover_trigger.arn }
output "failover_lambda_arn"         { value = aws_lambda_function.failover.arn }
output "vpc_flow_logs_group_name"    { value = aws_cloudwatch_log_group.vpc_flow_logs.name }
output "vpc_flow_logs_group_arn"     { value = aws_cloudwatch_log_group.vpc_flow_logs.arn }
