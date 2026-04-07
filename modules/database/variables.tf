# modules/database/variables.tf
variable "app_name"                 { type = string }
variable "environment"              { type = string }
variable "is_primary"               { type = bool   default = true }
variable "private_data_subnet_ids"  { type = list(string) }
variable "database_sg_id"           { type = string }
variable "cache_sg_id"              { type = string }
variable "kms_key_arn"              { type = string }
variable "rds_monitoring_role_arn"  { type = string }

# Aurora
variable "aurora_engine_version"  { type = string  default = "15.4" }
variable "database_name"          { type = string  default = "appdb" }
variable "db_master_username"     { type = string  default = "dbadmin" }
variable "db_master_password"     { type = string  sensitive = true }
variable "aurora_min_acu"         { type = number  default = 0.5 }
variable "aurora_max_acu"         { type = number  default = 16 }
variable "aurora_instance_count"  { type = number  default = 2 }
variable "global_cluster_id"      { type = string  default = "" }
variable "backup_retention_days"  { type = number  default = 7 }
variable "deletion_protection"    { type = bool    default = true }
variable "skip_final_snapshot"    { type = bool    default = false }

# Redis
variable "redis_node_type"        { type = string  default = "cache.t3.micro" }
variable "redis_num_replicas"     { type = number  default = 1 }
variable "redis_auth_token"       { type = string  sensitive = true }

variable "tags" { type = map(string) default = {} }
