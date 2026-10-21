terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40, < 7.0"
    }
  }

  # One-time bootstrap, run by an AWS admin with local credentials.
  # Deliberately NOT part of the main stack's state.
}
