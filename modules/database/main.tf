# modules/database/main.tf
# Aurora PostgreSQL Global Database + ElastiCache Redis

# ── Subnet Groups ────────────────────────────────────────────────
resource "aws_db_subnet_group" "aurora" {
  name        = "${var.app_name}-${var.environment}-aurora-subnet-group"
  subnet_ids  = var.private_data_subnet_ids
  description = "Aurora subnet group for ${var.environment}"
  tags        = merge(var.tags, { Name = "${var.app_name}-${var.environment}-aurora-subnet-group" })
}

resource "aws_elasticache_subnet_group" "redis" {
  name       = "${var.app_name}-${var.environment}-redis-subnet-group"
  subnet_ids = var.private_data_subnet_ids
  tags       = merge(var.tags, { Name = "${var.app_name}-${var.environment}-redis-subnet-group" })
}

# ── Aurora Global Database (created in PRIMARY only) ──────────────
resource "aws_rds_global_cluster" "main" {
  count                     = var.is_primary ? 1 : 0
  global_cluster_identifier = "${var.app_name}-global-cluster"
  engine                    = "aurora-postgresql"
  engine_version            = var.aurora_engine_version
  database_name             = var.database_name
  storage_encrypted         = true
}

# ── Aurora Cluster ────────────────────────────────────────────────
resource "aws_rds_cluster" "aurora" {
  cluster_identifier        = "${var.app_name}-${var.environment}-aurora"
  engine                    = "aurora-postgresql"
  engine_version            = var.aurora_engine_version
  engine_mode               = "provisioned"

  # Attach to global cluster
  global_cluster_identifier = var.is_primary ? aws_rds_global_cluster.main[0].id : var.global_cluster_id

  # Only set credentials on primary; DR inherits from global cluster
  master_username = var.is_primary ? var.db_master_username : null
  master_password = var.is_primary ? var.db_master_password : null
  database_name   = var.is_primary ? var.database_name : null

  db_subnet_group_name   = aws_db_subnet_group.aurora.name
  vpc_security_group_ids = [var.database_sg_id]
  kms_key_id             = var.kms_key_arn
  storage_encrypted      = true

  backup_retention_period      = var.backup_retention_days
  preferred_backup_window      = "02:00-03:00"
  preferred_maintenance_window = "sun:04:00-sun:05:00"

  deletion_protection          = var.deletion_protection
  skip_final_snapshot          = var.skip_final_snapshot
  final_snapshot_identifier    = "${var.app_name}-${var.environment}-final-snapshot"

  enabled_cloudwatch_logs_exports = ["postgresql"]

  serverlessv2_scaling_configuration {
    min_capacity = var.is_primary ? var.aurora_min_acu : 0.5
    max_capacity = var.is_primary ? var.aurora_max_acu : var.aurora_max_acu
  }

  tags = merge(var.tags, { Name = "${var.app_name}-${var.environment}-aurora" })

  lifecycle {
    ignore_changes = [
      # Global cluster manages replication, ignore engine version drifts
      engine_version,
      global_cluster_identifier,
    ]
  }
}

# ── Aurora Cluster Instances ──────────────────────────────────────
resource "aws_rds_cluster_instance" "aurora" {
  count              = var.aurora_instance_count
  identifier         = "${var.app_name}-${var.environment}-aurora-${count.index}"
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = "db.serverlessv2"
  engine             = aws_rds_cluster.aurora.engine
  engine_version     = aws_rds_cluster.aurora.engine_version

  db_subnet_group_name        = aws_db_subnet_group.aurora.name
  publicly_accessible         = false
  auto_minor_version_upgrade  = true
  performance_insights_enabled = var.is_primary

  monitoring_interval = 60
  monitoring_role_arn = var.rds_monitoring_role_arn

  tags = merge(var.tags, {
    Name = "${var.app_name}-${var.environment}-aurora-instance-${count.index}"
    Role = count.index == 0 ? "writer" : "reader"
  })
}

# ── ElastiCache Redis ─────────────────────────────────────────────
resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "${var.app_name}-${var.environment}-redis"
  description          = "Redis cluster for ${var.app_name} ${var.environment}"

  node_type            = var.redis_node_type
  num_cache_clusters   = var.is_primary ? var.redis_num_replicas : 1
  port                 = 6379

  subnet_group_name    = aws_elasticache_subnet_group.redis.name
  security_group_ids   = [var.cache_sg_id]

  at_rest_encryption_enabled  = true
  transit_encryption_enabled  = true
  auth_token                  = var.redis_auth_token
  kms_key_id                  = var.kms_key_arn

  automatic_failover_enabled = var.is_primary && var.redis_num_replicas > 1
  multi_az_enabled           = var.is_primary && var.redis_num_replicas > 1

  snapshot_retention_limit = var.backup_retention_days
  snapshot_window          = "03:00-04:00"
  maintenance_window       = "sun:05:00-sun:06:00"

  parameter_group_name = aws_elasticache_parameter_group.redis.name

  tags = merge(var.tags, { Name = "${var.app_name}-${var.environment}-redis" })
}

resource "aws_elasticache_parameter_group" "redis" {
  family = "redis7"
  name   = "${var.app_name}-${var.environment}-redis-params"

  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"
  }
  parameter {
    name  = "notify-keyspace-events"
    value = ""
  }
  tags = var.tags
}

# ── SSM Parameters for connection info ───────────────────────────
resource "aws_ssm_parameter" "db_endpoint" {
  name  = "/${var.app_name}/${var.environment}/db/endpoint"
  type  = "SecureString"
  value = aws_rds_cluster.aurora.endpoint
  key_id = var.kms_key_arn
  tags  = var.tags
}

resource "aws_ssm_parameter" "db_reader_endpoint" {
  name  = "/${var.app_name}/${var.environment}/db/reader_endpoint"
  type  = "SecureString"
  value = aws_rds_cluster.aurora.reader_endpoint
  key_id = var.kms_key_arn
  tags  = var.tags
}

resource "aws_ssm_parameter" "redis_endpoint" {
  name  = "/${var.app_name}/${var.environment}/cache/endpoint"
  type  = "SecureString"
  value = aws_elasticache_replication_group.redis.primary_endpoint_address
  key_id = var.kms_key_arn
  tags  = var.tags
}
