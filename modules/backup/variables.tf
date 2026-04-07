# modules/backup/variables.tf
variable "app_name"                  { type = string }
variable "environment"               { type = string }
variable "kms_key_arn"               { type = string }
variable "dr_vault_arn"              { type = string  default = "" }
variable "backup_retention_days"     { type = number  default = 30 }
variable "dr_backup_retention_days"  { type = number  default = 14 }
variable "aurora_cluster_arns"       { type = list(string) default = [] }
variable "efs_arns"                  { type = list(string) default = [] }
variable "tags"                      { type = map(string)  default = {} }

# modules/backup/outputs.tf
output "vault_arn"  { value = aws_backup_vault.main.arn }
output "vault_name" { value = aws_backup_vault.main.name }
output "plan_id"    { value = aws_backup_plan.main.id }
