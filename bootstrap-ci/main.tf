# ---------------------------------------------------------------------------
# CI identity bootstrap - AWS Secrets Manager edition.
#
# There is no OIDC here. The pipeline authenticates like this:
#
#   GitHub secret (low privilege)  ->  reads ONE secret from Secrets Manager
#     ->  that secret holds the deploy identity's key pair
#       ->  the pipeline uses the deploy identity for everything else
#
# Two identities are created here:
#
#   ci_reader  : read-only. Its key lives in GitHub Secrets and can only read
#                the ci_credentials secret. It cannot deploy anything.
#   ci_deploy  : the real deploy identity. Its key lives in AWS Secrets
#                Manager, so it never appears in GitHub and never enters the
#                CI Terraform state.
#
# This module is applied ONCE, locally, with admin credentials. Its state file
# stays on the operator's machine and is git-ignored.
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

  # The app-config secret is created by the main stack, so its ARN is not known
  # here. The name prefix keeps the grant scoped to this project.
  app_config_secret_arn_pattern = "arn:aws:secretsmanager:${var.aws_region}:${local.account_id}:secret:${var.app_name}/app-config-*"

  # Secrets Manager appends a random six-character suffix to the ARN, so the
  # credentials secret is addressed by a name pattern. Writing it out here
  # (rather than reading it off the resource) keeps the policy a known value
  # at plan time, which is what makes it assertable offline.
  ci_credentials_arn_pattern = "arn:aws:secretsmanager:${var.aws_region}:${local.account_id}:secret:${var.ci_credentials_secret_name}-*"

  # -------------------------------------------------------------------------
  # Permissions for the deploy identity.
  # -------------------------------------------------------------------------
  ci_deploy_policy = jsonencode({
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
      {
        Sid    = "AppConfigSecret"
        Effect = "Allow"
        Action = [
          "secretsmanager:CreateSecret",
          "secretsmanager:PutSecretValue",
          "secretsmanager:UpdateSecret",
          "secretsmanager:DeleteSecret",
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
          "secretsmanager:TagResource",
        ]
        Resource = [local.app_config_secret_arn_pattern]
      },
    ]
  })

  # -------------------------------------------------------------------------
  # The reader is deliberately tiny: it may read exactly one secret and
  # nothing else. If this key leaks, the blast radius is one secret value.
  # -------------------------------------------------------------------------
  ci_reader_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadCiCredentials"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = [local.ci_credentials_arn_pattern]
      Condition = {
        StringEquals = {
          "secretsmanager:SecretTag/Project" = var.app_name
        }
      }
    }]
  })
}

# ---------------------------------------------------------------------------
# The secret the pipeline reads at runtime. It holds the deploy identity's
# key pair, so the deploy key never appears in GitHub.
# ---------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "ci_credentials" {
  name        = var.ci_credentials_secret_name
  description = "AWS key pair the pipeline brokers at runtime. Contains the ${var.ci_deploy_user_name} identity."
  tags        = { ManagedBy = "terraform", Project = var.app_name }
}

resource "aws_iam_user" "ci_deploy" {
  name = var.ci_deploy_user_name
  tags = { ManagedBy = "terraform", Project = var.app_name }
}

resource "aws_iam_access_key" "ci_deploy" {
  user = aws_iam_user.ci_deploy.name
}

resource "aws_iam_policy" "ci_deploy" {
  name        = "${var.app_name}-ci-deploy"
  description = "Deploy permissions for ${var.ci_deploy_user_name}."
  policy      = local.ci_deploy_policy
  tags        = { ManagedBy = "terraform", Project = var.app_name }
}

resource "aws_iam_user_policy_attachment" "ci_deploy" {
  user       = aws_iam_user.ci_deploy.name
  policy_arn = aws_iam_policy.ci_deploy.arn
}

resource "aws_secretsmanager_secret_version" "ci_credentials" {
  secret_id = aws_secretsmanager_secret.ci_credentials.id
  secret_string = jsonencode({
    access_key_id     = aws_iam_access_key.ci_deploy.id
    secret_access_key = aws_iam_access_key.ci_deploy.secret
  })
}

# ---------------------------------------------------------------------------
# The reader. Its key is the ONLY thing that ever lives in GitHub.
# ---------------------------------------------------------------------------
resource "aws_iam_policy" "ci_reader" {
  name        = "${var.app_name}-ci-reader"
  description = "Read-only access to the CI credentials secret. Nothing else."
  policy      = local.ci_reader_policy
  tags        = { ManagedBy = "terraform", Project = var.app_name }
}

resource "aws_iam_user" "ci_reader" {
  name = var.ci_reader_user_name
  tags = { ManagedBy = "terraform", Project = var.app_name }
}

resource "aws_iam_access_key" "ci_reader" {
  user = aws_iam_user.ci_reader.name
}

resource "aws_iam_user_policy_attachment" "ci_reader" {
  user       = aws_iam_user.ci_reader.name
  policy_arn = aws_iam_policy.ci_reader.arn
}
