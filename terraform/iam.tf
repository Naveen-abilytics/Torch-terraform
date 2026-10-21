# ---------------------------------------------------------------------------
# IAM - two roles:
#   execution role : used by the ECS agent to pull the image, resolve secrets
#                    from Secrets Manager and write logs
#   task role      : handed to the container itself (it can read the app
#                    config secret if it needs to refresh it at runtime)
#
# The assume-role policy is built with jsonencode rather than the
# aws_iam_policy_document data source so it stays a plain Terraform
# expression: that keeps it assertable in the offline mock plan test.
# ---------------------------------------------------------------------------

locals {
  ecs_assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  # The ECS agent resolves the task definition's `secrets` entries by calling
  # Secrets Manager. The managed AmazonECSTaskExecutionRolePolicy does not
  # include that permission, so it is granted explicitly here.
  read_app_config_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadAppConfig"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [aws_secretsmanager_secret.app_config.arn]
    }]
  })
}

resource "aws_iam_role" "execution" {
  name               = "${var.app_name}-execution"
  assume_role_policy = local.ecs_assume_role_policy
  description        = "ECS task execution role for ${var.app_name}: pulls the ECR image, resolves Secrets Manager values and ships logs to CloudWatch."
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "${var.app_name}-read-app-config"
  role   = aws_iam_role.execution.name
  policy = local.read_app_config_policy
}

resource "aws_iam_role" "task" {
  name               = "${var.app_name}-task"
  assume_role_policy = local.ecs_assume_role_policy
  description        = "ECS task role for ${var.app_name}. Can read the app config secret; no other AWS access."
  tags               = var.tags
}

resource "aws_iam_role_policy" "task_secrets" {
  name   = "${var.app_name}-read-app-config"
  role   = aws_iam_role.task.name
  policy = local.read_app_config_policy
}
