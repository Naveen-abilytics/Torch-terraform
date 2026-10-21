variable "aws_region" {
  description = "AWS region to create the CI identities and the credentials secret in."
  type        = string
  default     = "us-east-1"
}

variable "expected_account_id" {
  description = <<-EOT
    Safety guard. The bootstrap refuses to run against a different AWS account
    than the one the pipeline expects.
  EOT
  type        = string
  default     = "008971661427"
}

variable "app_name" {
  description = "Base name for the app. Must match var.app_name in the main stack."
  type        = string
  default     = "sample-app"
}

variable "ecr_repository_name" {
  description = "Must match the ECR repository name created by the main stack."
  type        = string
  default     = "sample-app"
}

variable "ci_credentials_secret_name" {
  description = "Name of the Secrets Manager secret that holds the deploy identity's key pair."
  type        = string
  default     = "sample-app/ci-credentials"
}

variable "ci_deploy_user_name" {
  description = "Name of the IAM user whose key pair the pipeline brokers at runtime."
  type        = string
  default     = "github-actions-ecs-deploy"
}

variable "ci_reader_user_name" {
  description = "Name of the read-only IAM user. Its key is the only secret stored in GitHub."
  type        = string
  default     = "github-actions-secrets-reader"
}
