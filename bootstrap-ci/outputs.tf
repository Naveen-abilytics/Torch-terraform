output "ci_credentials_secret_arn" {
  description = "ARN of the secret holding the deploy identity's key pair. Set this as the CI_CREDENTIALS_SECRET_ARN repository variable."
  value       = aws_secretsmanager_secret.ci_credentials.arn
}

output "ci_credentials_secret_id" {
  description = "Secret id of the credentials secret."
  value       = aws_secretsmanager_secret.ci_credentials.id
}

output "ci_deploy_user_name" {
  description = "Name of the deploy identity."
  value       = aws_iam_user.ci_deploy.name
}

output "ci_deploy_access_key_id" {
  description = "Access key id of the deploy identity. Stored in Secrets Manager, not in GitHub."
  value       = aws_iam_access_key.ci_deploy.id
}

output "ci_reader_user_name" {
  description = "Name of the read-only identity whose key goes into GitHub Secrets."
  value       = aws_iam_user.ci_reader.name
}

output "ci_reader_access_key_id" {
  description = "Access key id of the read-only identity. This is the value of the SM_READER_ACCESS_KEY_ID GitHub secret."
  value       = aws_iam_access_key.ci_reader.id
}

output "ci_reader_secret_access_key" {
  description = "Secret access key of the read-only identity. This is the value of the SM_READER_SECRET_ACCESS_KEY GitHub secret."
  value       = aws_iam_access_key.ci_reader.secret
  sensitive   = true
}

output "account_id" {
  description = "AWS account id."
  value       = local.account_id
}
