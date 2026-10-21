<#
.SYNOPSIS
  One-command setup for the Secrets Manager credential brokering pipeline.

.DESCRIPTION
  Applies the bootstrap-ci/ Terraform module, which creates:

    github-actions-secrets-reader  read-only identity. Its key is the ONLY
                                   secret stored in GitHub, and it can read
                                   nothing except the credentials secret.
    github-actions-ecs-deploy      the real deploy identity. Its key pair is
                                   written to AWS Secrets Manager, so it never
                                   appears in GitHub and never enters the CI
                                   Terraform state.

  Then it uploads the reader key pair to GitHub as repository secrets and
  points the workflow at the credentials secret with the repository variable
  CI_CREDENTIALS_SECRET_ARN.

  The deploy key is never printed and never leaves AWS.

.EXAMPLE
  .\scripts\register-ci-identity.ps1

.EXAMPLE
  .\scripts\register-ci-identity.ps1 -ShowReaderKey
#>
param(
  [string]$Repo = "Naveen-abilytics/Torch-terraform",
  [string]$BootstrapDir = "",
  [string]$Profile = "default",
  [switch]$SkipApply,
  [switch]$ShowReaderKey
)

$ErrorActionPreference = "Stop"

if (-not $BootstrapDir) {
  $BootstrapDir = Join-Path (Split-Path -Parent $PSScriptRoot) "bootstrap-ci"
}
if (-not (Test-Path -LiteralPath $BootstrapDir)) {
  throw "Bootstrap directory not found: $BootstrapDir"
}

# --- locate the tools --------------------------------------------------------
function Resolve-Command($Name, $Candidates) {
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $found = $Candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $found) { throw "$Name not found on PATH." }
  return $found
}

$gh = Resolve-Command "gh" @(
  "$env:LOCALAPPDATA\Microsoft\WinGet\Links\gh.exe",
  "$env:ProgramFiles\GitHub CLI\gh.exe",
  "$env:LOCALAPPDATA\Programs\GitHub CLI\gh.exe"
)
$tf = Resolve-Command "terraform" @(
  "$env:ProgramFiles\Terraform\terraform.exe",
  "$env:LOCALAPPDATA\Programs\Terraform\terraform.exe"
)
$aws = Resolve-Command "aws" @(
  "$env:LOCALAPPDATA\Programs\Amazon\AWSCLI\aws.exe",
  "$env:ProgramFiles\Amazon\AWSCLI\aws.exe"
)

# --- authenticate to GitHub --------------------------------------------------
$cred = @("protocol=https", "host=github.com", "") | git credential fill 2>$null
$token = (($cred | Where-Object { $_ -like "password=*" }) -replace '^password=', '').Trim()
if (-not $token) { throw "No GitHub token in the credential manager. Run 'git push' once to store one." }
$env:GH_TOKEN = $token
$env:GH_HOST = "github.com"

$who = & $gh api user --jq .login 2>&1
if ($LASTEXITCODE -ne 0) { throw "gh authentication failed: $who" }
Write-Host "GitHub : $who"

# --- check the AWS identity --------------------------------------------------
$account = & $aws sts get-caller-identity --query Account --output text 2>&1
if ($LASTEXITCODE -ne 0) {
  throw @"
No usable AWS credentials.

The bootstrap needs an *admin* key (to create the IAM users, policies and the
Secrets Manager secret). Log in first:

  aws configure            # or: aws login
  aws sts get-caller-identity

then re-run this script.
"@
}
$account = $account.Trim()
Write-Host "AWS    : $account"
if ($account -ne "008971661427") {
  throw "This bootstrap is pinned to account 008971661427, but the active credentials belong to $account. Refusing to continue."
}

# --- apply the bootstrap -----------------------------------------------------
if (-not $SkipApply) {
  Write-Host ""
  Write-Host "==> Applying bootstrap-ci"
  Push-Location $BootstrapDir
  try {
    & $tf init -no-color -input=false 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "terraform init failed in $BootstrapDir" }
    & $tf apply -auto-approve -no-color -input=false 2>&1 | Write-Host
    if ($LASTEXITCODE -ne 0) { throw "terraform apply failed in $BootstrapDir" }
  }
  finally {
    Pop-Location
  }
}

# --- read the outputs --------------------------------------------------------
Push-Location $BootstrapDir
try {
  $secretArn = (& $tf output -raw ci_credentials_secret_arn 2>$null)
  $readerKeyId = (& $tf output -raw ci_reader_access_key_id 2>$null)
  $readerSecretKey = (& $tf output -raw ci_reader_secret_access_key 2>$null)
}
finally {
  Pop-Location
}
$secretArn = $secretArn.Trim()
$readerKeyId = $readerKeyId.Trim()
$readerSecretKey = $readerSecretKey.Trim()

if (-not $secretArn -or -not $readerKeyId -or -not $readerSecretKey) {
  throw @"
Could not read the bootstrap outputs. Run it by hand and check:

  cd $BootstrapDir
  terraform output ci_credentials_secret_arn
  terraform output ci_reader_access_key_id
  terraform output -raw ci_reader_secret_access_key
"@
}

Write-Host ""
Write-Host "Credentials secret : $secretArn"
Write-Host "Reader key id      : $readerKeyId"

# --- upload the reader key (the only GitHub secret) --------------------------
$readerKeyId | & $gh secret set SM_READER_ACCESS_KEY_ID --repo $Repo --body -
if ($LASTEXITCODE -ne 0) { throw "Failed to set SM_READER_ACCESS_KEY_ID" }
Write-Host "Secret SM_READER_ACCESS_KEY_ID set."

$readerSecretKey | & $gh secret set SM_READER_SECRET_ACCESS_KEY --repo $Repo --body -
if ($LASTEXITCODE -ne 0) { throw "Failed to set SM_READER_SECRET_ACCESS_KEY" }
Write-Host "Secret SM_READER_SECRET_ACCESS_KEY set."

# --- point the workflow at the credentials secret ----------------------------
& $gh variable set CI_CREDENTIALS_SECRET_ARN --repo $Repo --body "$secretArn" | Out-Null
Write-Host "Variable CI_CREDENTIALS_SECRET_ARN set."

& $gh variable set AWS_REGION --repo $Repo --body "us-east-1" | Out-Null
& $gh variable set ECR_REPOSITORY --repo $Repo --body "sample-app" | Out-Null

# --- report ------------------------------------------------------------------
Write-Host ""
Write-Host "Repository variables:"
& $gh variable list --repo $Repo | ForEach-Object { "  $_" }
Write-Host "Repository secrets (names only):"
& $gh secret list --repo $Repo | ForEach-Object { "  $($_.name)" }

Write-Host ""
Write-Host "The deploy key pair lives only in AWS Secrets Manager. It was never printed."
Write-Host "Next: add a required reviewer to the 'production' environment in the GitHub UI."

if ($ShowReaderKey) {
  Write-Host ""
  Write-Host "=== reader key (low privilege, already uploaded) ==="
  Write-Host "SM_READER_ACCESS_KEY_ID     = $readerKeyId"
  Write-Host "SM_READER_SECRET_ACCESS_KEY = $readerSecretKey"
  Write-Host "=================================================="
}
