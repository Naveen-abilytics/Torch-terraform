terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40, < 7.0"
    }
  }

  # Local state on purpose. This module is applied ONCE by an operator with
  # admin credentials, from their own machine. The state file holds the deploy
  # identity's access key, so it is git-ignored and must never be committed.
  # For a team, move it to an encrypted remote backend.
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      ManagedBy = "terraform"
      Project   = var.app_name
    }
  }
}
