# modules/storage/variables.tf
variable "app_name"           { type = string }
variable "environment"        { type = string }
variable "aws_account_id"     { type = string }
variable "is_primary"         { type = bool    default = true }
variable "kms_key_arn"        { type = string }
variable "dr_kms_key_arn"     { type = string  default = "" }
variable "dr_bucket_arn"      { type = string  default = "" }
variable "replication_role_arn" { type = string  default = "" }
variable "elb_account_id"     { type = string  description = "AWS ELB service account for ALB logs (region-specific)" }
variable "force_destroy"      { type = bool    default = false }
variable "tags"               { type = map(string) default = {} }

# modules/storage/outputs.tf
output "app_bucket_id"        { value = aws_s3_bucket.app.id }
output "app_bucket_arn"       { value = aws_s3_bucket.app.arn }
output "alb_logs_bucket_id"   { value = aws_s3_bucket.alb_logs.id }
output "alb_logs_bucket_arn"  { value = aws_s3_bucket.alb_logs.arn }
