variable "aws_region" {
  description = "AWS region the role is created in (must match the region used by CI)."
  type        = string
  default     = "us-east-1"
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
    Set to false if the account already has the GitHub OIDC provider.
    In that case import it first:
      terraform import aws_iam_openid_connect_provider.github \
        arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com
  EOT
  type        = bool
  default     = true
}
