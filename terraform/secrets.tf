# ---------------------------------------------------------------------------
# AWS Secrets Manager - the app's configuration.
#
# The values are written to a secret by Terraform and injected into the ECS
# task at runtime through the task definition's `secrets` block. The container
# therefore never sees a baked-in value, and nothing sensitive is ever passed
# on the command line, in the image, or in a plain environment variable.
#
# The value lives in the Terraform state, so treat the state file as a secret.
# CI persists the state in the GitHub Actions cache (repo-scoped, encrypted at
# rest by GitHub). For a real deployment, use an encrypted remote backend.
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "app_config" {
  name        = "${var.app_name}/app-config"
  description = "Runtime configuration for ${var.app_name}, injected into the ECS task."

  # The value is managed by Terraform. The version below carries the payload.
  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "app_config" {
  secret_id     = aws_secretsmanager_secret.app_config.id
  secret_string = jsonencode(var.app_config)
}
