# ---------------------------------------------------------------------------
# GitHub Actions OIDC federation.
#
# GitHub mints a short-lived JWT (OIDC) and exchanges it for AWS STS
# credentials. No AWS access key ever exists in GitHub secrets.
#
# The trust policy allows exactly two subjects:
#   repo:<org>/<repo>:ref:refs/heads/<branch>   -> the build/plan job
#   repo:<org>/<repo>:environment:<env>         -> the deploy job (post-approval)
#
# Note: GitHub OIDC has no ":branch:" subject. A push to a branch presents
# "repo:<org>/<repo>:ref:refs/heads/<branch>"; a job bound to an environment
# presents "repo:<org>/<repo>:environment:<env>".
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

# Guard against running the bootstrap against the wrong AWS account.
check "expected_account_id" {
  assert {
    condition     = data.aws_caller_identity.current.account_id == var.expected_account_id
    error_message = "Connected to account ${data.aws_caller_identity.current.account_id}, but this bootstrap is pinned to ${var.expected_account_id}."
  }
}

locals {
  account_id = data.aws_caller_identity.current.account_id

  ecr_repo_arn  = "arn:aws:ecr:${var.aws_region}:${local.account_id}:repository/${var.ecr_repository_name}"
  log_group_arn = "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/ecs/${var.app_name}"
  ecs_role_arn  = "arn:aws:iam::${local.account_id}:role/${var.app_name}-*"

  # True only when Terraform actually creates the OIDC provider. This must
  # match the resource count exactly - the two are used together below.
  creates_oidc_provider = var.create_oidc_role && var.create_oidc_provider && var.existing_oidc_provider_arn == ""

  # The provider this role trusts. When it already exists it is referenced by
  # ARN; when Terraform creates it, the ARN is read from the resource.
  oidc_provider_arn = (
    var.existing_oidc_provider_arn != ""
    ? var.existing_oidc_provider_arn
    : (local.creates_oidc_provider
      ? aws_iam_openid_connect_provider.github[0].arn
    : "arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com")
  )

  github_subjects = [
    "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/${var.github_branch}",
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
  count = local.creates_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "github_actions" {
  count = var.create_oidc_role ? 1 : 0

  name                 = var.role_name
  description          = "GitHub Actions OIDC role for the ${var.app_name} ECS deployment."
  assume_role_policy   = local.assume_role_policy
  max_session_duration = 3600
  tags                 = { ManagedBy = "terraform", Project = var.app_name }
}

# One standalone policy, shared by the OIDC role and the optional static user.
resource "aws_iam_policy" "ci_permissions" {
  name        = "ecs-deploy-permissions"
  description = "ECR / ECS / Logs / IAM permissions for the ${var.app_name} CI identity."
  policy      = local.ci_permissions_policy
  tags        = { ManagedBy = "terraform", Project = var.app_name }
}

resource "aws_iam_role_policy_attachment" "ci_role" {
  count = var.create_oidc_role ? 1 : 0

  role       = aws_iam_role.github_actions[0].name
  policy_arn = aws_iam_policy.ci_permissions.arn
}

# ---------------------------------------------------------------------------
# Optional: a scoped IAM user with a long-lived access key, for the
# "static credentials" auth mode. Same permissions as the role above.
# ---------------------------------------------------------------------------

resource "aws_iam_user" "ci" {
  count = var.create_static_user ? 1 : 0

  name = var.static_user_name
  tags = { ManagedBy = "terraform", Project = var.app_name }
}

resource "aws_iam_user_policy_attachment" "ci_user" {
  count = var.create_static_user ? 1 : 0

  user       = aws_iam_user.ci[0].name
  policy_arn = aws_iam_policy.ci_permissions.arn
}

resource "aws_iam_access_key" "ci" {
  count = var.create_static_user ? 1 : 0

  user = aws_iam_user.ci[0].name
}
