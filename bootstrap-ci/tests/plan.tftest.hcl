# Offline plan for the CI identity bootstrap, using Terraform's mock provider.
#   terraform test
#
# The assertions only touch values that are known at plan time. Anything
# computed by the provider (ARNs, key ids) is unknown during a plan, so the
# checks target the arguments and the policy documents instead.
#
mock_provider "aws" {}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "008971661427"
  }
}

run "plan" {
  command = plan

  variables {
    aws_region = "us-east-1"
  }

  # --- the credentials secret ------------------------------------------------
  assert {
    condition     = aws_secretsmanager_secret.ci_credentials.name == "sample-app/ci-credentials"
    error_message = "The credentials secret must use the expected name."
  }

  assert {
    condition     = aws_secretsmanager_secret.ci_credentials.tags["Project"] == "sample-app"
    error_message = "The credentials secret must carry the Project tag the reader's policy checks."
  }

  # --- the two identities ----------------------------------------------------
  assert {
    condition     = aws_iam_user.ci_deploy.name == "github-actions-ecs-deploy"
    error_message = "The deploy identity must be created."
  }

  assert {
    condition     = aws_iam_user.ci_reader.name == "github-actions-secrets-reader"
    error_message = "The read-only identity must be created."
  }

  assert {
    condition     = aws_iam_access_key.ci_deploy.user == "github-actions-ecs-deploy"
    error_message = "The deploy identity needs an access key."
  }

  assert {
    condition     = aws_iam_access_key.ci_reader.user == "github-actions-secrets-reader"
    error_message = "The read-only identity needs an access key."
  }

  # --- the reader must be able to read exactly one secret and nothing else ---
  assert {
    condition     = strcontains(aws_iam_policy.ci_reader.policy, "secretsmanager:GetSecretValue")
    error_message = "The reader must be allowed to read the credentials secret."
  }

  assert {
    condition     = strcontains(aws_iam_policy.ci_reader.policy, "secret:sample-app/ci-credentials-*")
    error_message = "The reader must be scoped to the credentials secret by name."
  }

  assert {
    condition     = !strcontains(aws_iam_policy.ci_reader.policy, "iam:")
    error_message = "The reader must not have any IAM permissions."
  }

  assert {
    condition     = !strcontains(aws_iam_policy.ci_reader.policy, "secretsmanager:CreateSecret")
    error_message = "The reader must not be allowed to create secrets."
  }

  assert {
    condition     = !strcontains(aws_iam_policy.ci_reader.policy, "secretsmanager:PutSecretValue")
    error_message = "The reader must not be allowed to write secrets."
  }

  assert {
    condition     = !strcontains(aws_iam_policy.ci_reader.policy, "secretsmanager:DeleteSecret")
    error_message = "The reader must not be allowed to delete secrets."
  }

  # --- the deploy identity manages the app-config secret ---------------------
  assert {
    condition     = strcontains(aws_iam_policy.ci_deploy.policy, "secretsmanager:CreateSecret")
    error_message = "The deploy identity must be allowed to create the app-config secret."
  }

  assert {
    condition     = strcontains(aws_iam_policy.ci_deploy.policy, "secretsmanager:GetSecretValue")
    error_message = "The deploy identity must be allowed to read the app-config secret."
  }

  assert {
    condition     = strcontains(aws_iam_policy.ci_deploy.policy, "secret:sample-app/app-config-*")
    error_message = "The app-config grant must be scoped by secret name."
  }
}
