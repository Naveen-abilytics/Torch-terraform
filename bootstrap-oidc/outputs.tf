output "role_arn" {
  description = "Paste this into the GitHub repository variable AWS_ROLE_ARN."
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
  value       = data.aws_iam_policy_document.assume.json
}

output "account_id" {
  description = "AWS account id."
  value       = local.account_id
}
