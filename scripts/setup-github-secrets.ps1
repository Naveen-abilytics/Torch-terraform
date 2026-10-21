<#
.SYNOPSIS
  Switch the pipeline to the static-secret auth method (Method B), end to end.

.DESCRIPTION
  Runs the one-time bootstrap in static mode, which creates a *scoped* IAM user
  with an access key, then uploads that key pair to GitHub Actions as secrets
  and flips the AWS_AUTH_MODE repository variable to "static".

  The key that is uploaded is the scoped CI user created by the bootstrap - not
  your personal admin key. The script deliberately does NOT read a key out of
  %USERPROFILE%\.aws\credentials, because uploading an admin key to CI would
  hand the whole account to every workflow run.

  GitHub secrets are write-only: they are encrypted with the repository's
  public key and can never be read back. Use -ShowCredentials if you want the
  key printed for your own records.

  Requires:
    - AWS admin credentials for the target account (aws configure / aws login)
    - the GitHub CLI (gh) and a token that can write repo secrets
    - Terraform on PATH

.EXAMPLE
  .\scripts\setup-github-secrets.ps1

.EXAMPLE
  .\scripts\setup-github-secrets.ps1 -ShowCredentials

.EXAMPLE
  .\scripts\setup-github-secrets.ps1 -SkipBootstrap
#>
param(
  [string]$Repo = "Naveen-abilytics/Torch-terraform",
  [string]$BootstrapDir = "",
  [string]$AccessKeyId = "",
  [string]$SecretAccessKey = "",
  [switch]$SkipBootstrap,
  [switch]$ShowCredentials,
  [switch]$Force
)

$ErrorActionPreference = "Stop"

if (-not $BootstrapDir) {
  $BootstrapDir = Join-Path (Split-Path -Parent $PSScriptRoot) "bootstrap-oidc"
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

Write-Host "gh         : $gh"
Write-Host "terraform  : $tf"
Write-Host "aws        : $aws"

# --- authenticate to GitHub --------------------------------------------------
$cred = @("protocol=https", "host=github.com", "") | git credential fill 2>$null
$token = (($cred | Where-Object { $_ -like "password=*" }) -replace '^password=', '').Trim()
if (-not $token) { throw "No GitHub token in the credential manager. Run 'git push' once to store one." }
$env:GH_TOKEN = $token
$env:GH_HOST = "github.com"

$who = & $gh api user --jq .login 2>&1
if ($LASTEXITCODE -ne 0) { throw "gh authentication failed: $who" }
Write-Host "GitHub     : $who"

# --- check the AWS identity --------------------------------------------------
$account = & $aws sts get-caller-identity --query Account --output text 2>&1
if ($LASTEXITCODE -ne 0) {
  throw @"
No usable AWS credentials.

The bootstrap needs an *admin* key (to create the IAM user, policy and access
key). Log in first:

  aws configure            # or: aws login
  aws sts get-caller-identity

then re-run this script.
"@
}
$account = $account.Trim()
Write-Host "AWS account: $account"

if ($account -ne "008971661427") {
  throw "This bootstrap is pinned to account 008971661427, but the active credentials belong to $account. Refusing to continue."
}

# --- run the bootstrap in static mode ----------------------------------------
if (-not $SkipBootstrap) {
  Write-Host ""
  Write-Host "==> Applying the bootstrap (static mode)"

  Push-Location $BootstrapDir
  try {
    & $tf init -no-color -input=false 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "terraform init failed in $BootstrapDir" }

    $applyArgs = @(
      "apply", "-auto-approve", "-no-color", "-input=false",
      "-var=create_oidc_role=false",
      "-var=create_oidc_provider=false",
      "-var=create_static_user=true"
    )
    if ($Force) { $applyArgs += "-replace" }

    & $tf @applyArgs 2>&1 | Write-Host
    if ($LASTEXITCODE -ne 0) { throw "terraform apply failed in $BootstrapDir" }
  }
  finally {
    Pop-Location
  }
}

# --- read the scoped key pair out of the bootstrap outputs --------------------
if (-not $AccessKeyId -or -not $SecretAccessKey) {
  Push-Location $BootstrapDir
  try {
    $AccessKeyId = (& $tf output -raw static_access_key_id 2>$null)
    $SecretAccessKey = (& $tf output -raw static_secret_access_key 2>$null)
  }
  finally {
    Pop-Location
  }
  if ($AccessKeyId) { $AccessKeyId = $AccessKeyId.Trim() }
  if ($SecretAccessKey) { $SecretAccessKey = $SecretAccessKey.Trim() }
}

if (-not $AccessKeyId -or -not $SecretAccessKey) {
  throw @"
Could not read the CI key pair from the bootstrap outputs.

Run the bootstrap yourself and check its outputs:

  cd $BootstrapDir
  terraform output static_access_key_id
  terraform output -raw static_secret_access_key

then re-run with:

  .\scripts\setup-github-secrets.ps1 -AccessKeyId AKIA... -SecretAccessKey ...
"@
}

Write-Host ""
Write-Host "CI user   : github-actions-ecs"
Write-Host "Access key: $AccessKeyId"

# --- upload the secrets ------------------------------------------------------
$AccessKeyId | & $gh secret set AWS_ACCESS_KEY_ID --repo $Repo --body -
if ($LASTEXITCODE -ne 0) { throw "Failed to set AWS_ACCESS_KEY_ID" }
Write-Host "Secret AWS_ACCESS_KEY_ID set."

$SecretAccessKey | & $gh secret set AWS_SECRET_ACCESS_KEY --repo $Repo --body -
if ($LASTEXITCODE -ne 0) { throw "Failed to set AWS_SECRET_ACCESS_KEY" }
Write-Host "Secret AWS_SECRET_ACCESS_KEY set."

# --- switch the auth mode ---------------------------------------------------
& $gh variable set AWS_AUTH_MODE --repo $Repo --body "static" | Out-Null
Write-Host "Variable AWS_AUTH_MODE = static"

& $gh variable set AWS_REGION --repo $Repo --body "us-east-1" | Out-Null
& $gh variable set ECR_REPOSITORY --repo $Repo --body "sample-app" | Out-Null

# --- report -----------------------------------------------------------------
Write-Host ""
Write-Host "Repository variables:"
& $gh variable list --repo $Repo | ForEach-Object { "  $_" }
Write-Host "Repository secrets (names only):"
& $gh secret list --repo $Repo | ForEach-Object { "  $($_.name)" }

if ($ShowCredentials) {
  Write-Host ""
  Write-Host "=== CI credentials (store them somewhere safe) ==="
  Write-Host "AWS_ACCESS_KEY_ID     = $AccessKeyId"
  Write-Host "AWS_SECRET_ACCESS_KEY = $SecretAccessKey"
  Write-Host "=================================================="
}
else {
  Write-Host ""
  Write-Host "The secret key was never printed. Re-run with -ShowCredentials if you need a copy."
}
