# modules/backup/main.tf
# AWS Backup vaults, plans, and selections

resource "aws_backup_vault" "main" {
  name        = "${var.app_name}-${var.environment}-backup-vault"
  kms_key_arn = var.kms_key_arn
  tags        = merge(var.tags, { Name = "${var.app_name}-${var.environment}-backup-vault" })
}

resource "aws_backup_plan" "main" {
  name = "${var.app_name}-${var.environment}-backup-plan"

  rule {
    rule_name         = "daily-backup"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 2 * * ? *)"  # 02:00 UTC daily

    start_window      = 60
    completion_window = 180

    lifecycle {
      delete_after = var.backup_retention_days
    }

    copy_action {
      destination_vault_arn = var.dr_vault_arn
      lifecycle {
        delete_after = var.dr_backup_retention_days
      }
    }
  }

  rule {
    rule_name         = "weekly-backup"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 3 ? * SUN *)"  # 03:00 UTC every Sunday

    start_window      = 60
    completion_window = 300

    lifecycle {
      delete_after = 90
    }
  }

  tags = var.tags
}

resource "aws_backup_selection" "rds" {
  iam_role_arn = aws_iam_role.backup.arn
  name         = "${var.app_name}-${var.environment}-rds-selection"
  plan_id      = aws_backup_plan.main.id

  resources = var.aurora_cluster_arns

  condition {}
}

resource "aws_backup_selection" "efs" {
  count        = length(var.efs_arns) > 0 ? 1 : 0
  iam_role_arn = aws_iam_role.backup.arn
  name         = "${var.app_name}-${var.environment}-efs-selection"
  plan_id      = aws_backup_plan.main.id
  resources    = var.efs_arns
}

resource "aws_iam_role" "backup" {
  name = "${var.app_name}-${var.environment}-backup-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "backup_restore" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}
