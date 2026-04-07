# modules/security/variables.tf
variable "app_name"            { type = string }
variable "environment"         { type = string }
variable "aws_region"          { type = string }
variable "aws_account_id"      { type = string }
variable "is_primary"          { type = bool    default = true }
variable "db_master_username"  { type = string  default = "dbadmin" }
variable "db_master_password"  { type = string  sensitive = true }
variable "database_name"       { type = string  default = "appdb" }
variable "tags"                { type = map(string) default = {} }

# modules/security/outputs.tf
output "kms_key_arn"              { value = aws_kms_key.main.arn }
output "kms_key_id"               { value = aws_kms_key.main.key_id }
output "ecs_execution_role_arn"   { value = aws_iam_role.ecs_execution.arn }
output "ecs_task_role_arn"        { value = aws_iam_role.ecs_task.arn }
output "lambda_role_arn"          { value = aws_iam_role.lambda.arn }
output "failover_lambda_role_arn"   { value = var.is_primary ? "" : aws_iam_role.failover_lambda[0].arn }
output "failover_lambda_policy_arn" { value = var.is_primary ? "" : aws_iam_policy.failover_lambda[0].arn }
output "rds_monitoring_role_arn"  { value = aws_iam_role.rds_monitoring.arn }
output "s3_replication_role_arn"  { value = var.is_primary ? aws_iam_role.s3_replication[0].arn : "" }
output "vpc_flow_logs_role_arn"   { value = aws_iam_role.vpc_flow_logs.arn }
output "db_credentials_secret_arn" { value = aws_secretsmanager_secret.db_credentials.arn }
