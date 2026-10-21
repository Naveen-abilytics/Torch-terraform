# ---------------------------------------------------------------------------
# IAM - two roles:
#   execution role : used by the ECS agent to pull the image and write logs
#   task role      : handed to the container itself (no AWS access needed)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name                 = "${var.app_name}-execution"
  assume_role_policy   = data.aws_iam_policy_document.ecs_assume_role.json
  description          = "ECS task execution role for ${var.app_name}: pulls the ECR image and ships logs to CloudWatch."
  permissions_boundary = null
  tags                 = var.tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name               = "${var.app_name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
  description        = "ECS task role for ${var.app_name}. Intentionally policy-free: the sample app makes no AWS API calls."
  tags               = var.tags
}
