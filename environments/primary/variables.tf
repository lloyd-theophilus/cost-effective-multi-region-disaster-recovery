# environments/primary/variables.tf

# ── Identity ──────────────────────────────────────────────────────
variable "app_name"       { type = string  description = "Application name used as resource prefix" }
variable "aws_account_id" { type = string  description = "AWS Account ID" }
variable "owner_tag"      { type = string  default = "platform-team" }

# ── Regions ───────────────────────────────────────────────────────
variable "primary_region" { type = string  default = "us-east-1" }
variable "dr_region"      { type = string  default = "eu-west-1" }

# ── Networking ────────────────────────────────────────────────────
variable "primary_vpc_cidr" { type = string  default = "10.0.0.0/16" }
variable "primary_azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"]
}
variable "app_port" { type = number  default = 8080 }

# ── Domain ────────────────────────────────────────────────────────
variable "domain_name"               { type = string  description = "Route 53 hosted zone domain, e.g. example.com" }
variable "primary_acm_certificate_arn" { type = string  description = "ACM cert ARN for the primary ALB HTTPS listener (us-east-1)" }
variable "health_check_path"         { type = string  default = "/health" }

# ── Compute ───────────────────────────────────────────────────────
variable "container_image"    { type = string  description = "Full ECR image URI including tag" }
variable "task_cpu"           { type = number  default = 512   description = "Fargate task CPU units (256/512/1024/2048/4096)" }
variable "task_memory"        { type = number  default = 1024  description = "Fargate task memory in MiB" }
variable "ecs_desired_count"  { type = number  default = 2 }
variable "ecs_min_capacity"   { type = number  default = 2 }
variable "ecs_max_capacity"   { type = number  default = 20 }
variable "log_retention_days" { type = number  default = 30 }

# ── Database ──────────────────────────────────────────────────────
variable "aurora_engine_version"          { type = string  default = "15.4" }
variable "database_name"                  { type = string  default = "appdb" }
variable "db_master_username"             { type = string  default = "dbadmin" }
variable "db_master_password"             { type = string  sensitive = true }
variable "primary_aurora_min_acu"         { type = number  default = 0.5 }
variable "primary_aurora_max_acu"         { type = number  default = 16 }
variable "primary_aurora_instance_count"  { type = number  default = 2  description = "1 writer + N readers" }
variable "backup_retention_days"          { type = number  default = 7 }
variable "deletion_protection"            { type = bool    default = true }

# ── Cache ─────────────────────────────────────────────────────────
variable "primary_redis_node_type"    { type = string  default = "cache.t3.small" }
variable "primary_redis_num_replicas" { type = number  default = 2 }
variable "redis_auth_token"           { type = string  sensitive = true }

# ── Storage ───────────────────────────────────────────────────────
# ELB service account IDs: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/enable-access-logging.html
variable "elb_service_account_id" { type = string  default = "127311923021"  description = "ELB service account for ALB logs (us-east-1 default)" }

# ── Alerting ──────────────────────────────────────────────────────
variable "alert_emails"       { type = list(string)  default = []  description = "Email addresses for DR alerts" }
variable "pagerduty_endpoint" { type = string         default = ""  description = "PagerDuty HTTPS endpoint for SNS subscription" }
