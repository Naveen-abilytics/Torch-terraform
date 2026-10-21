variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "app_name" {
  description = "Base name for the app. Used for ECR repo, ECS cluster, task definition, service and log group."
  type        = string
  default     = "sample-app"
}

variable "image_tag" {
  description = "ECR image tag to run. Overridden by CI with the commit SHA."
  type        = string
  default     = "latest"
}

variable "container_port" {
  description = "Port the container listens on."
  type        = number
  default     = 8080
}

variable "desired_count" {
  description = "Number of ECS tasks to run."
  type        = number
  default     = 1
}

variable "task_cpu" {
  description = "Fargate task CPU units. Valid: 256, 512, 1024, 2048, 4096."
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Fargate task memory (MiB). Valid: 512, 1024, 2048, 4096."
  type        = number
  default     = 512
}

variable "allowed_cidr" {
  description = "CIDR allowed to reach the container port directly on the task's public IP."
  type        = string
  default     = "0.0.0.0/0"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the task log group."
  type        = number
  default     = 14
}

variable "ecs_subnet_ids" {
  description = <<-EOT
    Optional. Subnets for the ECS service. Leave empty to use the account's
    existing default VPC subnets (no VPC resources are created either way).
  EOT
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    Environment = "sample"
    ManagedBy   = "terraform"
    Project     = "sample-app"
  }
}
