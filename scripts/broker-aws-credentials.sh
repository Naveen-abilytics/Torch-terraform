#!/usr/bin/env bash
#
# Broker AWS credentials out of AWS Secrets Manager.
#
# The pipeline holds exactly one low-privilege credential in GitHub: the
# "reader" key, which can read nothing except the CI credentials secret. This
# script uses that key to fetch the real deploy key pair from Secrets Manager
# and writes it to the runner's shared credentials file, so every later step
# (terraform, docker, the aws cli) picks it up automatically.
#
# Nothing is echoed: the deploy secret key never appears in the job log.
#
# Required environment:
#   AWS_ACCESS_KEY_ID              the reader key id      (from a GitHub secret)
#   AWS_SECRET_ACCESS_KEY          the reader secret key  (from a GitHub secret)
#   CI_CREDENTIALS_SECRET_ARN      the secret to read     (from a repo variable)
#
# Optional:
#   AWS_REGION                     default us-east-1
#   AWS_BROKER_PROFILE             profile name to write, default "default"

set -euo pipefail

readonly PROFILE="${AWS_BROKER_PROFILE:-default}"
readonly AWS_SHARED_DIR="${HOME}/.aws"

fail() {
  echo "::error::$1" >&2
  exit 1
}

# --- validate the inputs -----------------------------------------------------
if [ -z "${CI_CREDENTIALS_SECRET_ARN:-}" ]; then
  fail "CI_CREDENTIALS_SECRET_ARN is not set. Run scripts/setup-github-env.ps1 to create it."
fi

if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  fail "The reader credentials are missing. Expected the GitHub secrets SM_READER_ACCESS_KEY_ID and SM_READER_SECRET_ACCESS_KEY."
fi

if ! command -v aws >/dev/null 2>&1; then
  fail "The AWS CLI is not available on this runner."
fi

if ! command -v jq >/dev/null 2>&1; then
  fail "jq is not available on this runner."
fi

export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"

# Stop the AWS CLI from picking up a stale profile while we use the reader key.
export AWS_PROFILE=""

# --- fetch the deploy key pair ------------------------------------------------
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

echo "::group::Brokering AWS credentials from Secrets Manager"
echo "secret   : $CI_CREDENTIALS_SECRET_ARN"
echo "region   : $AWS_REGION"

if ! aws secretsmanager get-secret-value \
      --secret-id "$CI_CREDENTIALS_SECRET_ARN" \
      --query SecretString \
      --output text > "$workdir/secret.json" 2> "$workdir/err.txt"; then
  echo "::endgroup::"
  cat "$workdir/err.txt" >&2
  fail "Could not read $CI_CREDENTIALS_SECRET_ARN with the reader key. Check that the reader's policy still allows it."
fi

deploy_key_id="$(jq -r '.access_key_id // empty' < "$workdir/secret.json")"
deploy_secret_key="$(jq -r '.secret_access_key // empty' < "$workdir/secret.json")"

if [ -z "$deploy_key_id" ] || [ -z "$deploy_secret_key" ]; then
  echo "::endgroup::"
  fail "The secret $CI_CREDENTIALS_SECRET_ARN did not contain access_key_id and secret_access_key."
fi

# --- write the shared credentials file ---------------------------------------
# 0600 and a private directory: the runner is shared with other steps.
umask 077
mkdir -p "$AWS_SHARED_DIR"
chmod 700 "$AWS_SHARED_DIR"

cat > "$AWS_SHARED_DIR/credentials" <<EOF
[$PROFILE]
aws_access_key_id = $deploy_key_id
aws_secret_access_key = $deploy_secret_key
EOF
chmod 600 "$AWS_SHARED_DIR/credentials"

cat > "$AWS_SHARED_DIR/config" <<EOF
[profile $PROFILE]
region = $AWS_REGION
EOF
chmod 600 "$AWS_SHARED_DIR/config"

rm -f "$workdir/secret.json"

# --- verify the identity we ended up with ------------------------------------
identity="$(aws sts get-caller-identity --profile "$PROFILE" --output json 2>/dev/null || echo '{}')"
identity_arn="$(echo "$identity" | jq -r '.Arn // "unknown"')"
identity_account="$(echo "$identity" | jq -r '.Account // "unknown"')"

echo "::endgroup::"
echo "Brokered identity : $identity_arn"
echo "Account           : $identity_account"
echo "Access key id     : $deploy_key_id"
