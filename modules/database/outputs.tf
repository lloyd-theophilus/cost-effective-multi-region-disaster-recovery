# modules/database/outputs.tf
output "aurora_cluster_id"          { value = aws_rds_cluster.aurora.id }
output "aurora_cluster_endpoint"    { value = aws_rds_cluster.aurora.endpoint }
output "aurora_reader_endpoint"     { value = aws_rds_cluster.aurora.reader_endpoint }
output "aurora_cluster_arn"         { value = aws_rds_cluster.aurora.arn }
output "global_cluster_id"          { value = var.is_primary ? aws_rds_global_cluster.main[0].id : var.global_cluster_id }
output "redis_primary_endpoint"     { value = aws_elasticache_replication_group.redis.primary_endpoint_address }
output "redis_reader_endpoint"      { value = aws_elasticache_replication_group.redis.reader_endpoint_address }
output "redis_replication_group_id" { value = aws_elasticache_replication_group.redis.id }
