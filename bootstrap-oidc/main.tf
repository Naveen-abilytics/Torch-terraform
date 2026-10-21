# ---------------------------------------------------------------------------
# GitHub Actions OIDC federation.
#
# GitHub mints a short-lived JWT (OIDC) and exchanges it for AWS STS
# credentials. No AWS access key ever exists in GitHub secrets.
#
# The trust policy allows exactly two subjects:
#   repo:<org>/<repo>:branch:<branch>       -> the build/plan job
#   repo:<org>/<repo>:environment:<env>      -> the deploy job (post-approval)
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  ecr_repo_arn  = "arn:aws:ecr:${var.aws_region}:${local.account_id}:repository/${var.ecr_repository_name}"
  log_group_arn = "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/ecs/${var.app_name}"
  ecs_role_arn  = "arn:aws:iam::${local.account_id}:role/${var.app_name}-*"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "assume" {
  statement {
    sid     = "GitHubActionsOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type = "Federated"
      identifiers = [
        var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_org}/${var.github_repo}:branch:${var.github_branch}",
        "repo:${var.github_org}/${var.github_repo}:environment:${var.github_environment}",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name                 = var.role_name
  description          = "GitHub Actions OIDC role for the ${var.app_name} ECS deployment."
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  max_session_duration = 3600
  tags                 = { ManagedBy = "terraform", Project = var.app_name }
}

# ---------------------------------------------------------------------------
# Permissions for the CI role. Scoped to ECR / ECS / Logs / the two ECS roles.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ci_permissions" {
  statement {
    sid    = "ECRAuthToken"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ECRRepository"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:ListImages",
      "ecr:TagResource",
    ]
    resources = [local.ecr_repo_arn]
  }

  statement {
    sid    = "ECRRepositoryCreate"
    effect = "Allow"
    actions = [
      "ecr:CreateRepository",
      "ecr:DeleteRepository",
      "ecr:PutLifecyclePolicy",
      "ecr:PutImageScanningConfiguration",
      "ecr:PutEncryptionConfiguration",
    ]
    resources = [local.ecr_repo_arn]
  }

  statement {
    sid    = "ECS"
    effect = "Allow"
    actions = [
      "ecs:CreateCluster",
      "ecs:DeleteCluster",
      "ecs:DescribeClusters",
      "ecs:UpdateCluster",
      "ecs:RegisterTaskDefinition",
      "ecs:DeregisterTaskDefinition",
      "ecs:DescribeTaskDefinition",
      "ecs:CreateService",
      "ecs:UpdateService",
      "ecs:DeleteService",
      "ecs:DescribeServices",
      "ecs:ListTasks",
      "ecs:DescribeTasks",
      "ecs:RunTask",
      "ecs:StopTask",
      "ecs:TagResource",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "LogsCreate"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "LogsWrite"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
      "logs:DescribeLogGroups",
      "logs:DeleteLogGroup",
      "logs:TagResource",
      "logs:ListTagsForResource",
    ]
    resources = [local.log_group_arn]
  }

  statement {
    sid    = "IAMRoleManagement"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "IAMRolePolicies"
    effect = "Allow"
    actions = [
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListRoles",
    ]
    resources = [local.ecs_role_arn]
  }

  statement {
    sid    = "IAMPassRole"
    effect = "Allow"
    actions = [
      "iam:PassRole",
    ]
    resources = [local.ecs_role_arn]
  }
}

resource "aws_iam_role_policy" "ci_permissions" {
  name   = "ecs-deploy-permissions"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.ci_permissions.json
}
