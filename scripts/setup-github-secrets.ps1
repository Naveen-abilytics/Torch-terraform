<#
.SYNOPSIS
  Registers the AWS credentials in GitHub Actions using the static-secret method.

.DESCRIPTION
  Stores the AWS access key pair as GitHub Actions *secrets* and switches the
  pipeline to AWS_AUTH_MODE=static. Secrets are write-only: they are encrypted
  with the repository's public key and can never be read back.

  The key pair is taken from, in order of preference:
    1. the -AccessKeyId / -SecretAccessKey parameters
    2. the current profile in %USERPROFILE%\.aws\credentials
    3. an interactive prompt

  Requires the GitHub CLI (gh) and a token that can write repo secrets.
  The token is read from the Git Credential Manager, the same one git uses to push.

.EXAMPLE
  .\scripts\setup-github-secrets.ps1

.EXAMPLE
  .\scripts\setup-github-secrets.ps1 -AccessKeyId AKIA... -SecretAccessKey wJal...
#>
param(
  [string]$Repo = "Naveen-abilytics/Torch-terraform",
  [string]$Profile = "default",
  [string]$AccessKeyId = "",
  [string]$SecretAccessKey = "",
  [switch]$KeepOidc
)

$ErrorActionPreference = "Stop"

# --- locate gh --------------------------------------------------------------
$gh = Get-Command gh -ErrorAction SilentlyContinue
if (-not $gh) {
  $candidates = @(
    "$env:LOCALAPPDATA\Microsoft\WinGet\Links\gh.exe",
    "$env:ProgramFiles\GitHub CLI\gh.exe",
    "$env:LOCALAPPDATA\Programs\GitHub CLI\gh.exe"
  ) | Where-Object { Test-Path $_ }
  if ($candidates.Count -eq 0) { throw "GitHub CLI (gh) not found. Install it with: winget install --id GitHub.cli" }
  $gh = $candidates[0]
}
Write-Host "Using gh: $($gh.Source)"

# --- authenticate -----------------------------------------------------------
$cred = @("protocol=https", "host=github.com", "") | git credential fill 2>$null
$token = (($cred | Where-Object { $_ -like "password=*" }) -replace '^password=', '').Trim()
if (-not $token) { throw "No GitHub token in the credential manager. Run 'git push' once to store one." }
$env:GH_TOKEN = $token
$env:GH_HOST = "github.com"

$who = & $gh.Source api user --jq .login 2>&1
if ($LASTEXITCODE -ne 0) { throw "gh authentication failed: $who" }
Write-Host "Authenticated as $who"

# --- resolve the AWS key pair ----------------------------------------------
if (-not $AccessKeyId -or -not $SecretAccessKey) {
  $credsFile = Join-Path $env:USERPROFILE ".aws\credentials"
  if (Test-Path $credsFile) {
    $ini = Get-Content $credsFile -Raw
    $section = "[$Profile]"
    $match = [regex]::Match($ini, "(?ms)^\s*\[$([regex]::Escape($Profile))\]\s*(.*?)(?=^\s*\[|\z)")
    if ($match.Success) {
      $id = ([regex]::Match($match.Groups[1].Value, "(?m)^\s*aws_access_key_id\s*=\s*(\S+)")).Groups[1].Value
      $sec = ([regex]::Match($match.Groups[1].Value, "(?m)^\s*aws_secret_access_key\s*=\s*(\S+)")).Groups[1].Value
      if ($id -and $sec) {
        $AccessKeyId = $id
        $SecretAccessKey = $sec
        Write-Host "Read key pair from profile '$Profile' in $credsFile"
      }
    }
  }
}

if (-not $AccessKeyId -or -not $SecretAccessKey) {
  Write-Host "Enter the AWS key pair (from the bootstrap output, or your IAM user)."
  $AccessKeyId = Read-Host "AWS access key id"
  $SecretAccessKey = Read-Host "AWS secret access key" -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecretAccessKey)
  $SecretAccessKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

if (-not $AccessKeyId -or -not $SecretAccessKey) { throw "No AWS key pair available." }

# --- push the secrets -------------------------------------------------------
$AccessKeyId | & $gh.Source secret set AWS_ACCESS_KEY_ID --repo $Repo --body -
if ($LASTEXITCODE -ne 0) { throw "Failed to set AWS_ACCESS_KEY_ID" }
Write-Host "Secret AWS_ACCESS_KEY_ID set."

$SecretAccessKey | & $gh.Source secret set AWS_SECRET_ACCESS_KEY --repo $Repo --body -
if ($LASTEXITCODE -ne 0) { throw "Failed to set AWS_SECRET_ACCESS_KEY" }
Write-Host "Secret AWS_SECRET_ACCESS_KEY set."

# --- switch the auth mode ---------------------------------------------------
& $gh.Source variable set AWS_AUTH_MODE --repo $Repo --body "static" | Out-Null
Write-Host "Variable AWS_AUTH_MODE = static"

if (-not $KeepOidc) {
  & $gh.Source variable set AWS_ROLE_ARN --repo $Repo --body "arn:aws:iam::008971661427:role/github-actions-ecs-deploy" | Out-Null
  Write-Host "Variable AWS_ROLE_ARN left in place (unused while AWS_AUTH_MODE=static)."
}

# --- report -----------------------------------------------------------------
Write-Host ""
Write-Host "Current repository variables:"
& $gh.Source variable list --repo $Repo | ForEach-Object { "  $_" }
Write-Host "Current repository secrets (names only):"
& $gh.Source secret list --repo $Repo | ForEach-Object { "  $($_.name)" }
