# environments/dr/variables.tf

variable "app_name"       { type = string }
variable "aws_account_id" { type = string }
variable "owner_tag"      { type = string  default = "platform-team" }

variable "primary_region" { type = string  default = "us-east-1" }
variable "dr_region"      { type = string  default = "eu-west-1" }

variable "dr_vpc_cidr"    { type = string  default = "10.1.0.0/16" }
variable "dr_azs" {
  type    = list(string)
  default = ["eu-west-1a", "eu-west-1b"]
}
variable "app_port"           { type = number  default = 8080 }
variable "health_check_path"  { type = string  default = "/health" }

variable "dr_acm_certificate_arn"  { type = string  description = "ACM cert ARN for DR ALB (eu-west-1)" }
variable "container_image"         { type = string }
variable "task_cpu"                { type = number  default = 512 }
variable "task_memory"             { type = number  default = 1024 }
variable "prod_task_count"         { type = number  default = 4   description = "ECS task count to scale to on failover" }
variable "log_retention_days"      { type = number  default = 30 }

variable "aurora_engine_version"   { type = string  default = "15.4" }
variable "database_name"           { type = string  default = "appdb" }
variable "db_master_username"      { type = string  default = "dbadmin" }
variable "db_master_password"      { type = string  sensitive = true }
variable "aurora_max_acu"          { type = number  default = 16 }
variable "backup_retention_days"   { type = number  default = 7 }
variable "deletion_protection"     { type = bool    default = true }

variable "dr_redis_node_type"      { type = string  default = "cache.t3.micro" }
variable "redis_auth_token"        { type = string  sensitive = true }

variable "elb_service_account_id"  { type = string  default = "156460612806"  description = "ELB service account for ALB logs (eu-west-1)" }

# Fallback for first apply before primary state exists
variable "global_cluster_id_override" { type = string  default = "" }


# environments/dr/outputs.tf

output "vpc_id"              { value = module.networking.vpc_id }
output "alb_dns_name"        { value = module.compute.alb_dns_name }
output "alb_zone_id"         { value = module.compute.alb_zone_id }
output "alb_arn"             { value = module.compute.alb_arn }
output "ecs_cluster_name"    { value = module.compute.ecs_cluster_name }
output "ecs_service_name"    { value = module.compute.ecs_service_name }
output "aurora_cluster_id"   { value = module.database.aurora_cluster_id }
output "aurora_cluster_arn"  { value = module.database.aurora_cluster_arn }
output "aurora_endpoint"     { value = module.database.aurora_cluster_endpoint }
output "kms_key_arn"         { value = module.security.kms_key_arn }
output "app_bucket_arn"      { value = module.storage.app_bucket_arn }
output "backup_vault_arn"    { value = module.backup.vault_arn }
output "failover_topic_arn"  { value = module.monitoring.failover_trigger_topic_arn }
output "failover_lambda_arn" { value = module.monitoring.failover_lambda_arn }


# environments/dr/terraform.tfvars.example
# Copy to terraform.tfvars and fill in your values.

# app_name       = "myapp"
# aws_account_id = "123456789012"
# owner_tag      = "platform-team"
#
# primary_region = "us-east-1"
# dr_region      = "eu-west-1"
#
# dr_vpc_cidr = "10.1.0.0/16"
# dr_azs      = ["eu-west-1a", "eu-west-1b"]
# app_port    = 8080
#
# dr_acm_certificate_arn = "arn:aws:acm:eu-west-1:123456789012:certificate/yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"
# container_image        = "123456789012.dkr.ecr.us-east-1.amazonaws.com/myapp:latest"
# task_cpu               = 512
# task_memory            = 1024
# prod_task_count        = 4    # How many tasks to scale to on failover
#
# database_name              = "appdb"
# db_master_username         = "dbadmin"
# aurora_engine_version      = "15.4"
# aurora_max_acu             = 16.0
# backup_retention_days      = 7
# deletion_protection        = true
#
# dr_redis_node_type         = "cache.t3.micro"
#
# elb_service_account_id = "156460612806"   # eu-west-1
