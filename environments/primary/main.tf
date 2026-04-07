# environments/primary/main.tf
# Primary region (us-east-1) — full production stack

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
    key            = "primary/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "REPLACE_WITH_YOUR_LOCK_TABLE"
    encrypt        = true
  }
}

provider "aws" {
  region = var.primary_region
  default_tags {
    tags = local.common_tags
  }
}

# Secondary provider alias needed for DNS module (Route 53 is global but
# we manage hosted zone records from primary)
provider "aws" {
  alias  = "dr"
  region = var.dr_region
  default_tags {
    tags = local.common_tags
  }
}

# ── Remote state for DR outputs (used by DNS module) ─────────────
data "terraform_remote_state" "dr" {
  backend = "s3"
  config = {
    bucket = "REPLACE_WITH_YOUR_STATE_BUCKET"
    key    = "dr/terraform.tfstate"
    region = "us-east-1"
  }
}

# ── Locals ────────────────────────────────────────────────────────
locals {
  common_tags = {
    Project     = var.app_name
    Environment = "primary"
    ManagedBy   = "terraform"
    Repository  = "aws-multi-region-dr"
    Owner       = var.owner_tag
  }
}

# ── Security (KMS, IAM, Secrets) ─────────────────────────────────
module "security" {
  source = "../../modules/security"

  app_name           = var.app_name
  environment        = "primary"
  aws_region         = var.primary_region
  aws_account_id     = var.aws_account_id
  is_primary         = true
  db_master_username = var.db_master_username
  db_master_password = var.db_master_password
  database_name      = var.database_name
  tags               = local.common_tags
}

# ── Monitoring (CloudWatch log groups needed before VPC flow logs) ─
module "monitoring" {
  source = "../../modules/monitoring"

  app_name                 = var.app_name
  environment              = "primary"
  is_primary               = true
  dr_region                = var.dr_region
  kms_key_arn              = module.security.kms_key_arn
  failover_lambda_role_arn = ""   # Not used in primary; failover Lambda lives in DR
  ecs_cluster_name         = module.compute.ecs_cluster_name
  ecs_service_name         = module.compute.ecs_service_name
  prod_task_count          = var.ecs_desired_count
  alb_arn_suffix           = module.compute.alb_arn
  alert_topic_arn          = module.dns.health_check_alerts_topic_arn

  # These are populated after DR is deployed; use empty strings on first apply
  global_cluster_id        = module.database.global_cluster_id
  dr_cluster_id            = try(data.terraform_remote_state.dr.outputs.aurora_cluster_id, "")
  dr_cluster_arn           = try(data.terraform_remote_state.dr.outputs.aurora_cluster_arn, "")
  primary_health_check_id  = module.dns.primary_health_check_id
  dr_health_check_id       = module.dns.dr_health_check_id

  tags = local.common_tags
}

# ── Networking ────────────────────────────────────────────────────
module "networking" {
  source = "../../modules/networking"

  app_name           = var.app_name
  environment        = "primary"
  vpc_cidr           = var.primary_vpc_cidr
  availability_zones = var.primary_azs
  is_primary         = true
  app_port           = var.app_port
  flow_log_role_arn  = module.security.vpc_flow_logs_role_arn
  flow_log_group_arn = module.monitoring.vpc_flow_logs_group_arn
  tags               = local.common_tags
}

# ── Storage ───────────────────────────────────────────────────────
module "storage" {
  source = "../../modules/storage"

  app_name            = var.app_name
  environment         = "primary"
  aws_account_id      = var.aws_account_id
  is_primary          = true
  kms_key_arn         = module.security.kms_key_arn
  dr_kms_key_arn      = try(data.terraform_remote_state.dr.outputs.kms_key_arn, "")
  dr_bucket_arn       = try(data.terraform_remote_state.dr.outputs.app_bucket_arn, "")
  replication_role_arn = module.security.s3_replication_role_arn
  elb_account_id      = var.elb_service_account_id
  tags                = local.common_tags
}

# ── Database ──────────────────────────────────────────────────────
module "database" {
  source = "../../modules/database"

  app_name                = var.app_name
  environment             = "primary"
  is_primary              = true
  private_data_subnet_ids = module.networking.private_data_subnet_ids
  database_sg_id          = module.networking.database_sg_id
  cache_sg_id             = module.networking.cache_sg_id
  kms_key_arn             = module.security.kms_key_arn
  rds_monitoring_role_arn = module.security.rds_monitoring_role_arn

  aurora_engine_version  = var.aurora_engine_version
  database_name          = var.database_name
  db_master_username     = var.db_master_username
  db_master_password     = var.db_master_password
  aurora_min_acu         = var.primary_aurora_min_acu
  aurora_max_acu         = var.primary_aurora_max_acu
  aurora_instance_count  = var.primary_aurora_instance_count
  backup_retention_days  = var.backup_retention_days
  deletion_protection    = var.deletion_protection

  redis_node_type    = var.primary_redis_node_type
  redis_num_replicas = var.primary_redis_num_replicas
  redis_auth_token   = var.redis_auth_token

  tags = local.common_tags
}

# ── Compute ───────────────────────────────────────────────────────
module "compute" {
  source = "../../modules/compute"

  app_name               = var.app_name
  environment            = "primary"
  aws_region             = var.primary_region
  vpc_id                 = module.networking.vpc_id
  public_subnet_ids      = module.networking.public_subnet_ids
  private_app_subnet_ids = module.networking.private_app_subnet_ids
  alb_sg_id              = module.networking.alb_sg_id
  app_sg_id              = module.networking.app_sg_id
  kms_key_arn            = module.security.kms_key_arn
  ecs_execution_role_arn = module.security.ecs_execution_role_arn
  ecs_task_role_arn      = module.security.ecs_task_role_arn
  lambda_role_arn        = module.security.lambda_role_arn
  acm_certificate_arn    = var.primary_acm_certificate_arn
  alb_logs_bucket        = module.storage.alb_logs_bucket_id
  container_image        = var.container_image
  app_port               = var.app_port
  health_check_path      = var.health_check_path
  task_cpu               = var.task_cpu
  task_memory            = var.task_memory
  ecs_desired_count      = var.ecs_desired_count
  ecs_min_capacity       = var.ecs_min_capacity
  ecs_max_capacity       = var.ecs_max_capacity
  log_retention_days     = var.log_retention_days
  deletion_protection    = var.deletion_protection
  tags                   = local.common_tags
}

# ── Backup ────────────────────────────────────────────────────────
module "backup" {
  source = "../../modules/backup"

  app_name              = var.app_name
  environment           = "primary"
  kms_key_arn           = module.security.kms_key_arn
  dr_vault_arn          = try(data.terraform_remote_state.dr.outputs.backup_vault_arn, "")
  backup_retention_days = var.backup_retention_days
  aurora_cluster_arns   = [module.database.aurora_cluster_arn]
  tags                  = local.common_tags
}

# ── DNS + Failover Records ────────────────────────────────────────
# Route 53 is global; we manage it from primary environment.
# DR ALB details come from remote state (deploy DR first, then re-apply primary).
module "dns" {
  source = "../../modules/dns"

  app_name              = var.app_name
  domain_name           = var.domain_name
  primary_alb_dns_name  = module.compute.alb_dns_name
  primary_alb_zone_id   = module.compute.alb_zone_id
  dr_alb_dns_name       = try(data.terraform_remote_state.dr.outputs.alb_dns_name, module.compute.alb_dns_name)
  dr_alb_zone_id        = try(data.terraform_remote_state.dr.outputs.alb_zone_id,  module.compute.alb_zone_id)
  health_check_path     = var.health_check_path
  kms_key_arn           = module.security.kms_key_arn
  failover_lambda_topic_arn = module.monitoring.failover_trigger_topic_arn
  alert_emails          = var.alert_emails
  pagerduty_endpoint    = var.pagerduty_endpoint
  tags                  = local.common_tags
}

# ── Remote State Bootstrap (first-time only) ─────────────────────
resource "aws_s3_bucket" "terraform_state" {
  bucket        = "${var.app_name}-terraform-state-${var.aws_account_id}"
  force_destroy = false
  tags          = merge(local.common_tags, { Name = "terraform-state" })
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = module.security.kms_key_id
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket                  = aws_s3_bucket.terraform_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "terraform_locks" {
  name         = "${var.app_name}-terraform-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = module.security.kms_key_arn
  }

  tags = merge(local.common_tags, { Name = "terraform-state-locks" })
}
