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
}
