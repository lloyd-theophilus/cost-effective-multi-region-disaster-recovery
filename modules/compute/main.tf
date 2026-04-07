# modules/compute/main.tf
# ECS Fargate cluster, ALB, task definitions, Lambda workers

# ── Application Load Balancer ─────────────────────────────────────
resource "aws_lb" "main" {
  name               = "${var.app_name}-${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = var.deletion_protection
  enable_http2               = true

  access_logs {
    bucket  = var.alb_logs_bucket
    prefix  = "${var.app_name}-${var.environment}-alb"
    enabled = true
  }

  tags = merge(var.tags, { Name = "${var.app_name}-${var.environment}-alb" })
}

resource "aws_lb_target_group" "app" {
  name        = "${var.app_name}-${var.environment}-tg"
  port        = var.app_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"  # Fargate uses IP mode

  health_check {
    enabled             = true
    path                = var.health_check_path
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30

  tags = merge(var.tags, { Name = "${var.app_name}-${var.environment}-tg" })
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# ── ECS Cluster ───────────────────────────────────────────────────
resource "aws_ecs_cluster" "main" {
  name = "${var.app_name}-${var.environment}"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(var.tags, { Name = "${var.app_name}-${var.environment}-ecs" })
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 80
    capacity_provider = "FARGATE"
  }
  default_capacity_provider_strategy {
    weight            = 20
    capacity_provider = "FARGATE_SPOT"
  }
}

# ── CloudWatch Log Group ──────────────────────────────────────────
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.app_name}-${var.environment}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

# ── ECS Task Definition ───────────────────────────────────────────
resource "aws_ecs_task_definition" "app" {
  family                   = "${var.app_name}-${var.environment}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = var.ecs_execution_role_arn
  task_role_arn            = var.ecs_task_role_arn

  container_definitions = jsonencode([
    {
      name      = var.app_name
      image     = var.container_image
      essential = true
      portMappings = [
        {
          containerPort = var.app_port
          protocol      = "tcp"
        }
      ]
      environment = [
        { name = "APP_ENV",    value = var.environment },
        { name = "APP_PORT",   value = tostring(var.app_port) },
        { name = "AWS_REGION", value = var.aws_region }
      ]
      secrets = [
        { name = "DB_HOST",      valueFrom = "/${var.app_name}/${var.environment}/db/endpoint" },
        { name = "DB_PASSWORD",  valueFrom = "/${var.app_name}/${var.environment}/db/password" },
        { name = "REDIS_HOST",   valueFrom = "/${var.app_name}/${var.environment}/cache/endpoint" },
        { name = "REDIS_AUTH",   valueFrom = "/${var.app_name}/${var.environment}/cache/auth_token" }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:${var.app_port}${var.health_check_path} || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
    }
  ])

  tags = merge(var.tags, { Name = "${var.app_name}-${var.environment}-task-def" })
}

# ── ECS Service ───────────────────────────────────────────────────
resource "aws_ecs_service" "app" {
  name                               = "${var.app_name}-${var.environment}-service"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.app.arn
  desired_count                      = var.ecs_desired_count
  launch_type                        = "FARGATE"
  platform_version                   = "LATEST"
  health_check_grace_period_seconds  = 60
  enable_execute_command             = false

  network_configuration {
    subnets          = var.private_app_subnet_ids
    security_groups  = [var.app_sg_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = var.app_name
    container_port   = var.app_port
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_controller {
    type = "ECS"
  }

  tags = merge(var.tags, { Name = "${var.app_name}-${var.environment}-service" })

  lifecycle {
    ignore_changes = [desired_count]  # Managed by auto-scaling
  }
}

# ── ECS Auto Scaling ──────────────────────────────────────────────
resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = var.ecs_max_capacity
  min_capacity       = var.ecs_min_capacity
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.app_name}-${var.environment}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 65.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

resource "aws_appautoscaling_policy" "memory" {
  name               = "${var.app_name}-${var.environment}-memory-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
    target_value       = 75.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# ── SQS Queues ────────────────────────────────────────────────────
resource "aws_sqs_queue" "main_dlq" {
  name                       = "${var.app_name}-${var.environment}-dlq"
  message_retention_seconds  = 1209600  # 14 days
  kms_master_key_id          = var.kms_key_arn
  tags                       = merge(var.tags, { Name = "${var.app_name}-${var.environment}-dlq" })
}

resource "aws_sqs_queue" "main" {
  name                       = "${var.app_name}-${var.environment}-queue"
  visibility_timeout_seconds = 300
  message_retention_seconds  = 86400
  kms_master_key_id          = var.kms_key_arn

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.main_dlq.arn
    maxReceiveCount     = 3
  })

  tags = merge(var.tags, { Name = "${var.app_name}-${var.environment}-queue" })
}

# ── Lambda Worker ─────────────────────────────────────────────────
data "archive_file" "lambda_placeholder" {
  type        = "zip"
  output_path = "${path.module}/lambda_placeholder.zip"
  source {
    content  = "# placeholder - deploy via CI/CD"
    filename = "handler.py"
  }
}

resource "aws_lambda_function" "worker" {
  function_name = "${var.app_name}-${var.environment}-worker"
  role          = var.lambda_role_arn
  runtime       = "python3.12"
  handler       = "handler.lambda_handler"
  timeout       = 300
  memory_size   = 512

  filename         = data.archive_file.lambda_placeholder.output_path
  source_code_hash = data.archive_file.lambda_placeholder.output_base64sha256

  vpc_config {
    subnet_ids         = var.private_app_subnet_ids
    security_group_ids = [var.app_sg_id]
  }

  environment {
    variables = {
      APP_ENV    = var.environment
      AWS_REGION = var.aws_region
    }
  }

  kms_key_arn = var.kms_key_arn

  tracing_config {
    mode = "Active"
  }

  tags = merge(var.tags, { Name = "${var.app_name}-${var.environment}-worker" })

  lifecycle {
    ignore_changes = [filename, source_code_hash]  # Deployed via CI/CD
  }
}

resource "aws_lambda_event_source_mapping" "sqs" {
  event_source_arn = aws_sqs_queue.main.arn
  function_name    = aws_lambda_function.worker.arn
  batch_size       = 10
  enabled          = true

  function_response_types = ["ReportBatchItemFailures"]
}
