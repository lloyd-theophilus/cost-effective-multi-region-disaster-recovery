# environments/dr/main.tf
# DR region (eu-west-1) — warm standby stack
# Deploy AFTER primary. Primary outputs (global_cluster_id, etc.) are
# pulled via remote state.

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  backend "s3" {
    bucket         = "REPLACE_WITH_YOUR_STATE_BUCKET"
    key            = "dr/terraform.tfstate"
    region         = "us-east-1"   # State bucket is always in primary region
    dynamodb_table = "REPLACE_WITH_YOUR_LOCK_TABLE"
    encrypt        = true
  }
}

provider "aws" {
  region = var.dr_region
  default_tags {
    tags = local.common_tags
  }
}

# ── Remote state from primary (provides global_cluster_id, etc.) ─
data "terraform_remote_state" "primary" {
  backend = "s3"
  config = {
    bucket = "REPLACE_WITH_YOUR_STATE_BUCKET"
    key    = "primary/terraform.tfstate"
    region = "us-east-1"
  }
}

locals {
  common_tags = {
    Project     = var.app_name
    Environment = "dr"
    ManagedBy   = "terraform"
    Repository  = "aws-multi-region-dr"
    Owner       = var.owner_tag
    DRRole      = "warm-standby"
  }

  # Pull from primary state; fallback to var for first apply chicken-egg
  global_cluster_id = try(
    data.terraform_remote_state.primary.outputs.global_cluster_id,
    var.global_cluster_id_override
  )
  primary_backup_vault_arn = try(
    data.terraform_remote_state.primary.outputs.backup_vault_arn,
    ""
  )
}

# ── Security (DR KMS key, IAM roles including failover Lambda) ────
module "security" {
  source = "../../modules/security"

  app_name           = var.app_name
  environment        = "dr"
  aws_region         = var.dr_region
  aws_account_id     = var.aws_account_id
  is_primary         = false
  db_master_username = var.db_master_username
  db_master_password = var.db_master_password
  database_name      = var.database_name
  tags               = local.common_tags
}

# ── Monitoring (log groups, failover Lambda, alarms) ─────────────
module "monitoring" {
  source = "../../modules/monitoring"

  app_name                 = var.app_name
  environment              = "dr"
  is_primary               = false
  dr_region                = var.dr_region
  kms_key_arn              = module.security.kms_key_arn
  failover_lambda_role_arn = module.security.failover_lambda_role_arn

  global_cluster_id = local.global_cluster_id
  dr_cluster_arn    = module.database.aurora_cluster_arn
  dr_cluster_id     = module.database.aurora_cluster_id

  ecs_cluster_name = module.compute.ecs_cluster_name
  ecs_service_name = module.compute.ecs_service_name
  prod_task_count  = var.prod_task_count

  alb_arn_suffix  = module.compute.alb_arn
  alert_topic_arn = module.monitoring.failover_trigger_topic_arn

  tags = local.common_tags
}

# ── Networking ────────────────────────────────────────────────────
module "networking" {
  source = "../../modules/networking"

  app_name           = var.app_name
  environment        = "dr"
  vpc_cidr           = var.dr_vpc_cidr
  availability_zones = var.dr_azs
  is_primary         = false   # single NAT GW in DR to save cost
  app_port           = var.app_port
  flow_log_role_arn  = module.security.vpc_flow_logs_role_arn
  flow_log_group_arn = module.monitoring.vpc_flow_logs_group_arn
  tags               = local.common_tags
}

# ── Storage (destination bucket for CRR) ─────────────────────────
module "storage" {
  source = "../../modules/storage"

  app_name       = var.app_name
  environment    = "dr"
  aws_account_id = var.aws_account_id
  is_primary     = false
  kms_key_arn    = module.security.kms_key_arn

  # DR bucket does NOT initiate replication; it receives it
  dr_bucket_arn        = ""
  replication_role_arn = ""
  elb_service_account_id = var.elb_service_account_id  # eu-west-1
  tags = local.common_tags
}

# ── Database (Aurora secondary cluster + scaled-down Redis) ───────
module "database" {
  source = "../../modules/database"

  app_name                = var.app_name
  environment             = "dr"
  is_primary              = false
  private_data_subnet_ids = module.networking.private_data_subnet_ids
  database_sg_id          = module.networking.database_sg_id
  cache_sg_id             = module.networking.cache_sg_id
  kms_key_arn             = module.security.kms_key_arn
  rds_monitoring_role_arn = module.security.rds_monitoring_role_arn

  aurora_engine_version = var.aurora_engine_version
  database_name         = var.database_name
  db_master_username    = var.db_master_username
  db_master_password    = var.db_master_password
  global_cluster_id     = local.global_cluster_id

  # DR runs minimum Aurora Serverless v2 capacity
  aurora_min_acu        = 0.5
  aurora_max_acu        = var.aurora_max_acu
  aurora_instance_count = 1   # Single reader; scale up on failover

  backup_retention_days = var.backup_retention_days
  deletion_protection   = var.deletion_protection
  skip_final_snapshot   = false

  # Single small Redis node in standby; auto-scaled on failover
  redis_node_type    = var.dr_redis_node_type
  redis_num_replicas = 1
  redis_auth_token   = var.redis_auth_token

  tags = local.common_tags
}

# ── Compute (scaled-down ECS + standby Lambda) ────────────────────
module "compute" {
  source = "../../modules/compute"

  app_name               = var.app_name
  environment            = "dr"
  aws_region             = var.dr_region
  vpc_id                 = module.networking.vpc_id
  public_subnet_ids      = module.networking.public_subnet_ids
  private_app_subnet_ids = module.networking.private_app_subnet_ids
  alb_sg_id              = module.networking.alb_sg_id
  app_sg_id              = module.networking.app_sg_id
  kms_key_arn            = module.security.kms_key_arn
  ecs_execution_role_arn = module.security.ecs_execution_role_arn
  ecs_task_role_arn      = module.security.ecs_task_role_arn
  lambda_role_arn        = module.security.lambda_role_arn
  acm_certificate_arn    = var.dr_acm_certificate_arn
  alb_logs_bucket        = module.storage.alb_logs_bucket_id
  container_image        = var.container_image
  app_port               = var.app_port
  health_check_path      = var.health_check_path
  task_cpu               = var.task_cpu
  task_memory            = var.task_memory

  # Warm standby: run 1 task minimum; scale to prod count on failover
  ecs_desired_count = 1
  ecs_min_capacity  = 1
  ecs_max_capacity  = var.prod_task_count * 2

  log_retention_days  = var.log_retention_days
  deletion_protection = var.deletion_protection
  tags                = local.common_tags
}

# ── Backup Vault (receives copies from primary vault) ─────────────
module "backup" {
  source = "../../modules/backup"

  app_name              = var.app_name
  environment           = "dr"
  kms_key_arn           = module.security.kms_key_arn
  dr_vault_arn          = ""   # DR vault doesn't copy further
  backup_retention_days = var.backup_retention_days
  aurora_cluster_arns   = [module.database.aurora_cluster_arn]
  tags                  = local.common_tags
}
