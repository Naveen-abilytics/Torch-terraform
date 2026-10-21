# Offline plan using Terraform's mock provider.
# Renders the full resource graph without any AWS credentials or API calls:
#
#   terraform test
#
mock_provider "aws" {}

variables {
  aws_region = "us-east-1"
  app_name   = "sample-app"
}

# The mock provider stubs every data source with a random string, so the
# values that must be real IDs are supplied here. The IAM policies are plain
# jsonencode() expressions, so they are asserted directly.
override_data {
  target = data.aws_vpc.default
  values = {
    id = "vpc-0123456789abcdef0"
  }
}

override_data {
  target = data.aws_subnets.default
  values = {
    ids = ["subnet-0123456789abcdef0", "subnet-0fedcba9876543210"]
  }
}

override_data {
  target = data.aws_subnets.fallback
  values = {
    ids = ["subnet-0123456789abcdef0"]
  }
}

# The secret ARN and the repository URL are computed, so they are unknown
# during a plan. Pin them so the injected-value wiring can be asserted.
override_resource {
  override_during = plan
  target          = aws_secretsmanager_secret.app_config
  values = {
    arn = "arn:aws:secretsmanager:us-east-1:008971661427:secret:sample-app/app-config-AbCdEf"
  }
}

override_resource {
  override_during = plan
  target          = aws_ecr_repository.app
  values = {
    repository_url = "012345678901.dkr.ecr.us-east-1.amazonaws.com/sample-app"
  }
}

run "plan" {
  command = plan

  assert {
    condition     = aws_ecs_service.app.desired_count == 1
    error_message = "Expected a single running task."
  }

  assert {
    condition     = aws_ecr_repository.app.name == "sample-app"
    error_message = "Expected the ECR repository to be named after the app."
  }

  assert {
    condition     = aws_ecs_task_definition.app.network_mode == "awsvpc"
    error_message = "Fargate tasks must use awsvpc network mode."
  }

  assert {
    condition     = length(local.subnet_ids) > 0
    error_message = "The service must be placed in at least one subnet."
  }

  assert {
    condition     = aws_ecs_service.app.network_configuration[0].assign_public_ip
    error_message = "The task needs a public IP because there is no load balancer."
  }

  # --- Secrets Manager is the only place the app's config lives -------------
  assert {
    condition     = aws_secretsmanager_secret.app_config.name == "sample-app/app-config"
    error_message = "The app config secret must be named after the app."
  }

  assert {
    condition     = jsondecode(aws_secretsmanager_secret_version.app_config.secret_string)["APP_MESSAGE"] == "Hello from AWS Secrets Manager"
    error_message = "The secret version must carry the app config as JSON."
  }

  # --- the task definition injects the secret, not a plain env var -----------
  assert {
    condition     = length(local.task_secrets) == 2
    error_message = "Every app config key must be injected into the task."
  }

  assert {
    condition     = local.task_secrets[0].name == "APP_MESSAGE"
    error_message = "The task secrets must be sorted by key."
  }

  assert {
    condition     = strcontains(local.task_secrets[0].valueFrom, "::APP_MESSAGE")
    error_message = "Each injected value must point at a JSON key of the secret."
  }

  assert {
    condition     = strcontains(aws_ecs_task_definition.app.container_definitions, "\"secrets\"")
    error_message = "The container definition must use the secrets block, not plain environment variables."
  }

  # --- the ECS agent needs permission to resolve the secret ------------------
  assert {
    condition     = strcontains(aws_iam_role_policy.execution_secrets.policy, "secretsmanager:GetSecretValue")
    error_message = "The execution role must be allowed to read the app config secret."
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.task_secrets.policy, "secretsmanager:GetSecretValue")
    error_message = "The task role must be allowed to read the app config secret."
  }
}
