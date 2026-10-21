# ---------------------------------------------------------------------------
# ECS - Fargate cluster, task definition and service.
#
# No load balancer: the task gets a public IP and the container port is
# published directly. No VPC, no S3, no database anywhere in this stack.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.app_name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_ecs_cluster" "app" {
  name = var.app_name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = var.tags
}

locals {
  # Each key in var.app_config is injected as its own environment variable in
  # the container. ECS resolves the value from Secrets Manager at task start.
  task_secrets = [
    for key in sort(keys(var.app_config)) : {
      name      = key
      valueFrom = "${aws_secretsmanager_secret.app_config.arn}::${key}"
    }
  ]
}

resource "aws_ecs_task_definition" "app" {
  family                   = var.app_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  tags                     = var.tags

  container_definitions = jsonencode([
    {
      name      = var.app_name
      image     = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
      essential = true

      portMappings = [
        {
          name          = "http"
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
        }
      ]

      environment = [
        {
          name  = "PORT"
          value = tostring(var.container_port)
        },
        {
          name  = "SERVICE_NAME"
          value = var.app_name
        },
      ]

      # Values come from AWS Secrets Manager, resolved by the ECS agent using
      # the execution role. They are never in the task definition itself.
      secrets = local.task_secrets

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

resource "aws_security_group" "app" {
  name        = "${var.app_name}-sg"
  description = "Public HTTP access to the ${var.app_name} ECS tasks."
  vpc_id      = data.aws_vpc.default.id
  tags        = var.tags

  ingress {
    description = "Application HTTP port from the internet (public task IP)."
    from_port   = var.container_port
    to_port     = var.container_port
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  egress {
    description = "Outbound for image pull, logs and AWS APIs."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_service" "app" {
  name             = var.app_name
  cluster          = aws_ecs_cluster.app.id
  task_definition  = aws_ecs_task_definition.app.arn
  desired_count    = var.desired_count
  launch_type      = "FARGATE"
  platform_version = "LATEST"

  # Lets a single-task service roll without needing room for two tasks.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 1

  network_configuration {
    subnets          = local.subnet_ids
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = true
  }

  tags = var.tags

  depends_on = [
    aws_ecr_repository.app,
    aws_cloudwatch_log_group.app,
  ]
}
