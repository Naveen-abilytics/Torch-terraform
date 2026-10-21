output "ecr_repository_url" {
  description = "ECR repository URL. The image tag is appended by CI."
  value       = aws_ecr_repository.app.repository_url
}

output "ecr_repository_name" {
  description = "ECR repository name."
  value       = aws_ecr_repository.app.name
}

output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.app.name
}

output "ecs_service_name" {
  description = "ECS service name."
  value       = aws_ecs_service.app.name
}

output "ecs_task_definition_arn" {
  description = "ARN of the task definition."
  value       = aws_ecs_task_definition.app.arn
}

output "ecs_execution_role_arn" {
  description = "ARN of the ECS task execution role."
  value       = aws_iam_role.execution.arn
}

output "ecs_task_role_arn" {
  description = "ARN of the ECS task role."
  value       = aws_iam_role.task.arn
}

output "log_group_name" {
  description = "CloudWatch log group for the task."
  value       = aws_cloudwatch_log_group.app.name
}

output "subnet_ids" {
  description = "Default VPC subnets the tasks run in."
  value       = local.subnet_ids
}

output "app_config_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the app's runtime configuration."
  value       = aws_secretsmanager_secret.app_config.arn
}

output "app_config_secret_id" {
  description = "Secret id of the app configuration secret."
  value       = aws_secretsmanager_secret.app_config.id
}

output "public_url_command" {
  description = "Command to print the public URL of the running task."
  value = join(" ", [
    "aws ecs list-tasks --cluster",
    aws_ecs_cluster.app.name,
    "--service-name",
    aws_ecs_service.app.name,
    "--query 'taskArns[0]' --output text",
  ])
}
