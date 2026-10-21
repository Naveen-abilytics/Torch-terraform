# ---------------------------------------------------------------------------
# IAM - two roles:
#   execution role : used by the ECS agent to pull the image and write logs
#   task role      : handed to the container itself (no AWS access needed)
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
}

resource "aws_iam_role" "execution" {
  name               = "${var.app_name}-execution"
  assume_role_policy = local.ecs_assume_role_policy
  description        = "ECS task execution role for ${var.app_name}: pulls the ECR image and ships logs to CloudWatch."
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name               = "${var.app_name}-task"
  assume_role_policy = local.ecs_assume_role_policy
  description        = "ECS task role for ${var.app_name}. Intentionally policy-free: the sample app makes no AWS API calls."
  tags               = var.tags
}
