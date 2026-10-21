output "role_arn" {
  description = "OIDC role. Paste into the GitHub repository variable AWS_ROLE_ARN."
  value       = aws_iam_role.github_actions.arn
}

output "role_name" {
  description = "Name of the OIDC role."
  value       = aws_iam_role.github_actions.name
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC identity provider."
  value       = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

output "trust_policy_json" {
  description = "Trust policy, in case you prefer to paste it into the console instead of running this bootstrap."
  value       = local.assume_role_policy
}

output "ci_policy_arn" {
  description = "ARN of the shared CI permissions policy (attached to the role and the optional user)."
  value       = aws_iam_policy.ci_permissions.arn
}

output "static_user_name" {
  description = "Name of the static-credentials IAM user (null when create_static_user is false)."
  value       = var.create_static_user ? aws_iam_user.ci[0].name : null
}

output "static_access_key_id" {
  description = "Static access key id for the CI user (null when create_static_user is false)."
  value       = var.create_static_user ? aws_iam_access_key.ci[0].id : null
}

output "static_secret_access_key" {
  description = "Static secret access key for the CI user (null when create_static_user is false)."
  value       = var.create_static_user ? aws_iam_access_key.ci[0].secret : null
  sensitive   = true
}

output "account_id" {
  description = "AWS account id."
  value       = local.account_id
}
