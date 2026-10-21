# ---------------------------------------------------------------------------
# Networking: we create NO VPC, subnet, route table or NAT resources.
#
# ECS/Fargate tasks are bound to a VPC by the API, so we reuse the account's
# pre-existing default VPC and its default public subnets through data
# sources. Nothing in this stack provisions network infrastructure.
# ---------------------------------------------------------------------------

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_subnets" "fallback" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

locals {
  subnet_ids = length(var.ecs_subnet_ids) > 0 ? var.ecs_subnet_ids : (
    length(data.aws_subnets.default.ids) > 0 ? data.aws_subnets.default.ids : data.aws_subnets.fallback.ids
  )
}
