<#
.SYNOPSIS
  Writes the correct OIDC trust policy onto the GitHub Actions role, directly
  through the AWS API.

.DESCRIPTION
  The AWS console's "GitHub Actions" trust-policy template is often published
  with its placeholders mangled - "token.actions" and "sts" get stripped, which
  leaves condition keys like "://githubusercontent.com:aud" that STS can never
  match. The symptom is:

      Could not assume role with OIDC:
      Not authorized to perform sts:AssumeRoleWithWebIdentity

  This script uploads the policy from bootstrap-oidc/trust-policy.json, which
  is generated from the same values Terraform uses, and then verifies it.

  The role itself is managed by Terraform - this is a fast, surgical fix that
  does not require a full apply. A later 'terraform apply' will produce the
  identical policy, so the two will not drift.

.EXAMPLE
  .\scripts\fix-oidc-trust-policy.ps1
#>
param(
  [string]$RoleName = "github-actions-ecs-deploy",
  [string]$PolicyPath = "",
  [string]$Profile = "default"
)

$ErrorActionPreference = "Stop"

if (-not $PolicyPath) {
  $PolicyPath = Join-Path (Split-Path -Parent $PSScriptRoot) "bootstrap-oidc\trust-policy.json"
}
if (-not (Test-Path -LiteralPath $PolicyPath)) {
  throw "Trust policy file not found: $PolicyPath"
}

$aws = Get-Command aws -ErrorAction SilentlyContinue
if (-not $aws) {
  $candidates = @(
    "$env:LOCALAPPDATA\Programs\Amazon\AWSCLI\aws.exe",
    "$env:ProgramFiles\Amazon\AWSCLI\aws.exe"
  ) | Where-Object { Test-Path $_ }
  if ($candidates.Count -eq 0) { throw "The AWS CLI (aws) was not found on PATH." }
  $aws = $candidates[0]
}

$account = (& $aws sts get-caller-identity --query Account --output text 2>&1)
if ($LASTEXITCODE -ne 0) { throw "No usable AWS credentials. Run 'aws configure' or 'aws login' first." }
$account = $account.Trim()
Write-Host "AWS account: $account"
if ($account -ne "008971661427") {
  throw "Expected account 008971661427 but the active credentials belong to $account. Refusing to continue."
}

# --- sanity check the file before uploading it -------------------------------
$policy = Get-Content -LiteralPath $PolicyPath -Raw | ConvertFrom-Json
$statement = $policy.Statement[0]
$federated = $statement.Principal.Federated
$aud = $statement.Condition.StringEquals."token.actions.githubusercontent.com:aud"
$sub = $statement.Condition.StringLike."token.actions.githubusercontent.com:sub"

$problems = @()
if ($federated -notlike "arn:aws:iam::${account}:oidc-provider/token.actions.githubusercontent.com") {
  $problems += "Principal.Federated is not this account's GitHub provider: $federated"
}
if (-not $statement.Condition.StringEquals."token.actions.githubusercontent.com:aud") {
  $problems += "the aud condition key is missing or malformed (must be token.actions.githubusercontent.com:aud)"
}
if ($aud -ne "sts.amazonaws.com") { $problems += "aud must be sts.amazonaws.com (got '$aud')" }
if (-not $statement.Condition.StringLike."token.actions.githubusercontent.com:sub") {
  $problems += "the sub condition key is missing or malformed (must be token.actions.githubusercontent.com:sub)"
}
if ($problems.Count -gt 0) {
  throw "The trust policy file is malformed:`n  - " + ($problems -join "`n  - ")
}

Write-Host ""
Write-Host "Policy to apply:"
Write-Host "  Federated : $federated"
Write-Host "  aud       : $aud"
Write-Host "  sub       : $($sub -join ', ')"

# --- upload ------------------------------------------------------------------
& $aws iam update-assume-role-policy `
  --role-name $RoleName `
  --policy-document "file://$PolicyPath" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "update-assume-role-policy failed" }
Write-Host ""
Write-Host "Trust policy updated on role '$RoleName'."

# --- verify ------------------------------------------------------------------
$applied = (& $aws iam get-role --role-name $RoleName --query 'Role.AssumeRolePolicyDocument' --output json 2>&1 | ConvertFrom-Json)
$appliedStatement = $applied.Statement[0]
Write-Host ""
Write-Host "Verified on the live role:"
Write-Host "  Federated : $($appliedStatement.Principal.Federated)"
Write-Host "  aud       : $($appliedStatement.Condition.StringEquals.'token.actions.githubusercontent.com:aud')"
Write-Host "  sub       : $($appliedStatement.Condition.StringLike.'token.actions.githubusercontent.com:sub' -join ', ')"
