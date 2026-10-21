# Offline plan for the OIDC bootstrap, using Terraform's mock provider.
#   terraform test
#
mock_provider "aws" {}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "123456789012"
  }
}

# The account already has the GitHub OIDC provider: Terraform must not try to
# create it and must reference the existing provider by ARN.
run "plan_with_existing_provider" {
  command = plan

  variables {
    aws_region           = "us-east-1"
    github_org           = "acme"
    github_repo          = "demo"
    create_oidc_provider = false
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0
    error_message = "The existing OIDC provider must not be recreated."
  }

  assert {
    condition     = aws_iam_role.github_actions.name == "github-actions-ecs-deploy"
    error_message = "Expected the GitHub Actions role to be created."
  }

  assert {
    condition     = strcontains(aws_iam_role.github_actions.assume_role_policy, "token.actions.githubusercontent.com")
    error_message = "The trust policy must reference the GitHub OIDC provider."
  }

  assert {
    condition     = strcontains(aws_iam_role.github_actions.assume_role_policy, "repo:acme/demo:branch:main")
    error_message = "The trust policy must allow the build branch subject."
  }

  assert {
    condition     = strcontains(aws_iam_role.github_actions.assume_role_policy, "repo:acme/demo:environment:production")
    error_message = "The trust policy must allow the production environment subject."
  }

  assert {
    condition     = strcontains(aws_iam_role.github_actions.assume_role_policy, "sts.amazonaws.com")
    error_message = "The trust policy must pin the audience to sts.amazonaws.com."
  }
}

# Fresh account: Terraform creates the OIDC provider itself.
run "plan_creating_provider" {
  command = plan

  variables {
    aws_region           = "us-east-1"
    github_org           = "acme"
    github_repo          = "demo"
    create_oidc_provider = true
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 1
    error_message = "The OIDC provider should be created when it does not already exist."
  }

  assert {
    condition     = aws_iam_openid_connect_provider.github[0].url == "https://token.actions.githubusercontent.com"
    error_message = "The provider URL must point at GitHub's token endpoint."
  }

  assert {
    condition     = contains(aws_iam_openid_connect_provider.github[0].client_id_list, "sts.amazonaws.com")
    error_message = "The provider must accept the sts.amazonaws.com audience."
  }
}
