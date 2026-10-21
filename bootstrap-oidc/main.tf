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

  # When the provider already exists (create_oidc_provider = false) it is not
  # managed here, so fall back to its well-known ARN.
  oidc_provider_arn = try(
    aws_iam_openid_connect_provider.github[0].arn,
    "arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"
  )

  github_subjects = [
    "repo:${var.github_org}/${var.github_repo}:branch:${var.github_branch}",
    "repo:${var.github_org}/${var.github_repo}:environment:${var.github_environment}",
  ]

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "GitHubActionsOIDC"
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = local.oidc_provider_arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = local.github_subjects
        }
      }
    }]
  })

  # -------------------------------------------------------------------------
  # Permissions for the CI role. Scoped to ECR / ECS / Logs / the two ECS roles.
  # -------------------------------------------------------------------------
  ci_permissions_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuthToken"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = ["*"]
      },
      {
        Sid    = "ECRRepository"
        Effect = "Allow"
        Action = [
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
        Resource = [local.ecr_repo_arn]
      },
      {
        Sid    = "ECRRepositoryCreate"
        Effect = "Allow"
        Action = [
          "ecr:CreateRepository",
          "ecr:DeleteRepository",
          "ecr:PutLifecyclePolicy",
          "ecr:PutImageScanningConfiguration",
          "ecr:PutEncryptionConfiguration",
        ]
        Resource = [local.ecr_repo_arn]
      },
      {
        Sid    = "ECS"
        Effect = "Allow"
        Action = [
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
        Resource = ["*"]
      },
      {
        Sid      = "LogsCreate"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup"]
        Resource = ["*"]
      },
      {
        Sid    = "LogsWrite"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
          "logs:DescribeLogGroups",
          "logs:DeleteLogGroup",
          "logs:TagResource",
          "logs:ListTagsForResource",
        ]
        Resource = [local.log_group_arn]
      },
      {
        Sid    = "IAMRoleManagement"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:UpdateAssumeRolePolicy",
          "iam:TagRole",
          "iam:UntagRole",
        ]
        Resource = ["*"]
      },
      {
        Sid    = "IAMRolePolicies"
        Effect = "Allow"
        Action = [
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:GetRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:ListRoles",
        ]
        Resource = [local.ecs_role_arn]
      },
      {
        Sid      = "IAMPassRole"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = [local.ecs_role_arn]
      },
    ]
  })
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "github_actions" {
  name                 = var.role_name
  description          = "GitHub Actions OIDC role for the ${var.app_name} ECS deployment."
  assume_role_policy   = local.assume_role_policy
  max_session_duration = 3600
  tags                 = { ManagedBy = "terraform", Project = var.app_name }
}

resource "aws_iam_role_policy" "ci_permissions" {
  name   = "ecs-deploy-permissions"
  role   = aws_iam_role.github_actions.id
  policy = local.ci_permissions_policy
}
