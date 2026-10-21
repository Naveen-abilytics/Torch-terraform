# Offline plan for the OIDC bootstrap, using Terraform's mock provider.
#   terraform test
#
mock_provider "aws" {}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "008971661427"
  }
}

# The account already has the GitHub OIDC provider: Terraform must not try to
# create it and must reference the existing provider by ARN.
run "plan_with_existing_provider" {
  command = plan

  variables {
    aws_region           = "us-east-1"
    github_org           = "acme"
    expected_account_id  = "008971661427"
    github_repo          = "demo"
    create_oidc_provider = false
    create_oidc_role     = true
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0
    error_message = "The existing OIDC provider must not be recreated."
  }

  assert {
    condition     = length(aws_iam_role.github_actions) == 1
    error_message = "Expected the GitHub Actions role to be created."
  }

  assert {
    condition     = aws_iam_role.github_actions[0].name == "github-actions-ecs-deploy"
    error_message = "Expected the GitHub Actions role to be created."
  }

  assert {
    condition     = strcontains(aws_iam_role.github_actions[0].assume_role_policy, "token.actions.githubusercontent.com")
    error_message = "The trust policy must reference the GitHub OIDC provider."
  }

  assert {
    condition     = strcontains(aws_iam_role.github_actions[0].assume_role_policy, "repo:acme/demo:ref:refs/heads/main")
    error_message = "The trust policy must allow the build branch subject (repo:ORG/REPO:ref:refs/heads/BRANCH)."
  }

  assert {
    condition     = !strcontains(aws_iam_role.github_actions[0].assume_role_policy, ":branch:")
    error_message = "GitHub OIDC has no ':branch:' subject - a branch push presents ':ref:refs/heads/BRANCH'."
  }

  assert {
    condition     = strcontains(aws_iam_role.github_actions[0].assume_role_policy, "repo:acme/demo:environment:production")
    error_message = "The trust policy must allow the production environment subject."
  }

  assert {
    condition     = strcontains(aws_iam_role.github_actions[0].assume_role_policy, "sts.amazonaws.com")
    error_message = "The trust policy must pin the audience to sts.amazonaws.com."
  }
}

# An explicitly supplied provider ARN must be used verbatim in the trust
# policy, and Terraform must not try to create the provider.
run "plan_with_explicit_provider_arn" {
  command = plan

  variables {
    aws_region                 = "us-east-1"
    github_org                 = "acme"
    expected_account_id        = "008971661427"
    github_repo                = "demo"
    create_oidc_role           = true
    create_oidc_provider       = true
    existing_oidc_provider_arn = "arn:aws:iam::008971661427:oidc-provider/token.actions.githubusercontent.com"
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0
    error_message = "An existing provider ARN must not trigger provider creation."
  }

  assert {
    condition     = strcontains(aws_iam_role.github_actions[0].assume_role_policy, "arn:aws:iam::008971661427:oidc-provider/token.actions.githubusercontent.com")
    error_message = "The trust policy must use the supplied provider ARN."
  }
}

# Static-credentials mode: an IAM user with an access key, sharing the same
# scoped policy as the OIDC role.
run "plan_with_static_user" {
  command = plan

  variables {
    aws_region           = "us-east-1"
    github_org           = "acme"
    github_repo          = "demo"
    create_oidc_role     = false
    create_oidc_provider = false
    create_static_user   = true
  }

  assert {
    condition     = length(aws_iam_user.ci) == 1
    error_message = "The static CI user should be created."
  }

  assert {
    condition     = length(aws_iam_access_key.ci) == 1
    error_message = "An access key should be generated for the static CI user."
  }

  assert {
    condition     = length(aws_iam_user_policy_attachment.ci_user) == 1
    error_message = "The static user must get the scoped CI policy attached."
  }

  assert {
    condition     = aws_iam_policy.ci_permissions.name == "ecs-deploy-permissions"
    error_message = "The shared scoped policy must exist."
  }

  assert {
    condition     = length(aws_iam_role.github_actions) == 0
    error_message = "Static mode must not create an OIDC role."
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0
    error_message = "Static mode must not touch the OIDC provider."
  }
}

# Fresh account: Terraform creates the OIDC provider itself.
run "plan_creating_provider" {
  command = plan

  variables {
    aws_region           = "us-east-1"
    github_org           = "acme"
    expected_account_id  = "008971661427"
    github_repo          = "demo"
    create_oidc_provider = true
    create_oidc_role     = true
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
