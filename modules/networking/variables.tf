# modules/networking/variables.tf
variable "app_name"           { type = string }
variable "environment"        { type = string }
variable "vpc_cidr"           { type = string }
variable "availability_zones" { type = list(string) }
variable "is_primary"         { type = bool    default = true }
variable "app_port"           { type = number  default = 8080 }
variable "flow_log_role_arn"  { type = string }
variable "flow_log_group_arn" { type = string }
variable "tags"               { type = map(string) default = {} }
