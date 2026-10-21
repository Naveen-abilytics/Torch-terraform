<#
.SYNOPSIS
  Configures the GitHub side of the build pipeline.

.DESCRIPTION
  Sets the repository variables the workflow reads, using a token from the Git
  Credential Manager (the same one git already uses for push). No secret is
  written to disk by this script.

  The pipeline holds no AWS credentials. It brokers them out of AWS Secrets
  Manager at runtime, so all this script needs to do is point the workflow at
  the secret that holds the deploy key:

    .\scripts\setup-github-env.ps1 -CiCredentialsSecretArn arn:aws:secretsmanager:us-east-1:008971661427:secret:sample-app/ci-credentials-AbCdEf

  The pipeline builds and pushes an image; it never deploys. There is therefore
  no deployment environment and no approval gate. Pass -CreateEnvironment only
  if you later add a deploy job and want the environment to exist.

.EXAMPLE
  .\scripts\setup-github-env.ps1
#>
param(
  [string]$Repo = "Naveen-abilytics/Torch-terraform",
  [string]$Environment = "production",
  [string]$AwsRegion = "us-east-1",
  [string]$EcrRepository = "sample-app",
  [string]$CiCredentialsSecretArn = "",
  [switch]$CreateEnvironment
)

$ErrorActionPreference = "Stop"

function Get-GitHubToken {
  $cred = @("protocol=https", "host=github.com", "") | git credential fill 2>$null
  $token = (($cred | Where-Object { $_ -like "password=*" }) -replace '^password=', '').Trim()
  if (-not $token) { throw "No GitHub token in the credential manager. Run 'git push' once to store one." }
  return $token
}

$headers = @{
  Authorization          = "Bearer $(Get-GitHubToken)"
  Accept                 = "application/vnd.github+json"
  "X-GitHub-Api-Version" = "2022-11-28"
  "User-Agent"           = "setup-github-env"
}

function Invoke-Gh {
  param([string]$Method, [string]$Uri, $Body)
  $params = @{ Method = $Method; Uri = $Uri; Headers = $headers }
  if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 8); $params.ContentType = "application/json" }
  try {
    return @{ Ok = $true; Data = (Invoke-RestMethod @params) }
  } catch {
    $detail = $_.ErrorDetails.Message
    if (-not $detail) { $detail = $_.Exception.Message }
    return @{ Ok = $false; Data = $detail }
  }
}

$api = "https://api.github.com/repos/$Repo"

# --- environment -----------------------------------------------------------
# Only needed once a deploy job exists. The current pipeline builds and pushes
# an image and never deploys, so the environment is off by default.
if ($CreateEnvironment) {
  $r = Invoke-Gh -Method Put -Uri "$api/environments/$Environment" -Body @{}
  if ($r.Ok) {
    Write-Host "Environment '$Environment' ready (id $($r.Data.id))."
    Write-Host "To gate deployments on it, add a required reviewer in the UI:"
    Write-Host "  Repo -> Settings -> Environments -> $Environment -> Deployment protection rules -> Required reviewers"
  } else {
    Write-Host "Environment '$Environment' FAILED: $($r.Data)"
  }
} else {
  Write-Host "Skipping the '$Environment' environment: this pipeline does not deploy."
  Write-Host "Pass -CreateEnvironment to create it anyway."
}

# --- repository variables --------------------------------------------------
$vars = @(
  @{ name = "AWS_REGION";     value = $AwsRegion },
  @{ name = "ECR_REPOSITORY"; value = $EcrRepository }
)
if ($CiCredentialsSecretArn) {
  $vars += @{ name = "CI_CREDENTIALS_SECRET_ARN"; value = $CiCredentialsSecretArn }
}

foreach ($v in $vars) {
  $existing = Invoke-Gh -Method Get -Uri "$api/actions/variables/$($v.name)"
  if ($existing.Ok) {
    $r = Invoke-Gh -Method Patch -Uri "$api/actions/variables/$($v.name)" -Body @{ name = $v.name; value = $v.value }
    $msg = if ($r.Ok) { "updated" } else { "FAILED: $($r.Data)" }
  } else {
    $r = Invoke-Gh -Method Post -Uri "$api/actions/variables" -Body @{ name = $v.name; value = $v.value }
    $msg = if ($r.Ok) { "created" } else { "FAILED: $($r.Data)" }
  }
  Write-Host "Variable $($v.name) -> $msg"
}

# --- report ----------------------------------------------------------------
$r = Invoke-Gh -Method Get -Uri "$api/actions/variables"
if ($r.Ok) { Write-Host "Variables now: $(@($r.Data.variables | ForEach-Object { $_.name }) -join ', ')" }
