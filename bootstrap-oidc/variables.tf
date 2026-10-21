variable "aws_region" {
  description = "AWS region the role is created in (must match the region used by CI)."
  type        = string
  default     = "us-east-1"
}

variable "expected_account_id" {
  description = <<-EOT
    Safety guard. The bootstrap refuses to create the OIDC role against a
    different AWS account than the one the pipeline expects.
  EOT
  type        = string
  default     = "008971661427"
}

variable "github_org" {
  description = "GitHub organisation or user that owns the repo."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name."
  type        = string
}

variable "github_branch" {
  description = "Branch allowed to build images and run terraform plan."
  type        = string
  default     = "main"
}

variable "github_environment" {
  description = "GitHub Environment that is allowed to run terraform apply."
  type        = string
  default     = "production"
}

variable "app_name" {
  description = "Must match var.app_name in the main stack (resource name prefix)."
  type        = string
  default     = "sample-app"
}

variable "ecr_repository_name" {
  description = "Must match the ECR repository name created by the main stack."
  type        = string
  default     = "sample-app"
}

variable "role_name" {
  description = "Name of the IAM role GitHub Actions assumes via OIDC."
  type        = string
  default     = "github-actions-ecs-deploy"
}

variable "create_oidc_provider" {
  description = <<-EOT
    Set to false if the account already has the GitHub OIDC provider registered.
    Terraform will then leave the provider alone and reference the existing one
    by ARN in the role's trust policy. No import is needed in that mode.

    If creating the role fails with "Invalid principal: OIDC provider
    token.actions.githubusercontent.com does not exist", the account does NOT
    have the provider - set this back to true.
  EOT
  type        = bool
  default     = true
}

variable "create_static_user" {
  description = <<-EOT
    Create a scoped IAM user with a long-lived access key, for the
    "static credentials" auth mode (AWS_AUTH_MODE=static). Off by default.
    The key is stored in the Terraform state - it is a sample, not production.
  EOT
  type        = bool
  default     = false
}

variable "static_user_name" {
  description = "Name of the optional static-credentials IAM user."
  type        = string
  default     = "github-actions-ecs"
}
