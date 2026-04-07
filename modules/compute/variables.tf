# modules/compute/variables.tf
variable "app_name"               { type = string }
variable "environment"            { type = string }
variable "aws_region"             { type = string }
variable "vpc_id"                 { type = string }
variable "public_subnet_ids"      { type = list(string) }
variable "private_app_subnet_ids" { type = list(string) }
variable "alb_sg_id"              { type = string }
variable "app_sg_id"              { type = string }
variable "kms_key_arn"            { type = string }
variable "ecs_execution_role_arn" { type = string }
variable "ecs_task_role_arn"      { type = string }
variable "lambda_role_arn"        { type = string }
variable "acm_certificate_arn"    { type = string }
variable "alb_logs_bucket"        { type = string }
variable "container_image"        { type = string }
variable "app_port"               { type = number  default = 8080 }
variable "health_check_path"      { type = string  default = "/health" }
variable "task_cpu"               { type = number  default = 512 }
variable "task_memory"            { type = number  default = 1024 }
variable "ecs_desired_count"      { type = number  default = 2 }
variable "ecs_min_capacity"       { type = number  default = 1 }
variable "ecs_max_capacity"       { type = number  default = 20 }
variable "log_retention_days"     { type = number  default = 30 }
variable "deletion_protection"    { type = bool    default = true }
variable "tags"                   { type = map(string) default = {} }
