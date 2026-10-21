terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40, < 7.0"
    }
  }

  # Local state on purpose: no S3 bucket, no remote backend.
  # CI persists the state file via the GitHub Actions cache (see .github/workflows/deploy.yml).
  # For a production setup, swap in HCP Terraform / Terraform Cloud (also S3-free).
}
