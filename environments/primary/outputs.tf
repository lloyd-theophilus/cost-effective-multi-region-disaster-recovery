# environments/primary/outputs.tf

output "vpc_id"                { value = module.networking.vpc_id }
output "alb_dns_name"          { value = module.compute.alb_dns_name }
output "alb_zone_id"           { value = module.compute.alb_zone_id }
output "alb_arn"               { value = module.compute.alb_arn }
output "ecs_cluster_name"      { value = module.compute.ecs_cluster_name }
output "ecs_service_name"      { value = module.compute.ecs_service_name }
output "aurora_cluster_id"     { value = module.database.aurora_cluster_id }
output "aurora_cluster_arn"    { value = module.database.aurora_cluster_arn }
output "aurora_endpoint"       { value = module.database.aurora_cluster_endpoint }
output "global_cluster_id"     { value = module.database.global_cluster_id }
output "kms_key_arn"           { value = module.security.kms_key_arn }
output "app_bucket_arn"        { value = module.storage.app_bucket_arn }
output "backup_vault_arn"      { value = module.backup.vault_arn }
output "failover_topic_arn"    { value = module.monitoring.failover_trigger_topic_arn }
output "terraform_state_bucket" { value = aws_s3_bucket.terraform_state.id }
output "terraform_lock_table"  { value = aws_dynamodb_table.terraform_locks.name }
