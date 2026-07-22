# Minimal infrastructure root that consumes remote state created by this project.
#
# Prerequisites:
#   1. ./scripts/create-terraform-state.sh -b <bucket> -r <region>
#   2. Copy generated/backend.hcl here (or pass its path to init)
#
#   terraform init -backend-config=../../generated/backend.hcl
#   terraform plan
#   terraform apply

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Values are injected via -backend-config (generated/backend.hcl)
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type        = string
  description = "AWS region for example resources"
  default     = "eu-central-1"
}

variable "project_name" {
  type        = string
  description = "Name tag / prefix for example resources"
  default     = "tfstate-demo"
}

# Example resource — replace with your real infrastructure
resource "aws_ssm_parameter" "demo" {
  name  = "/${var.project_name}/bootstrap-marker"
  type  = "String"
  value = "managed-by-terraform-via-remote-state"

  tags = {
    ManagedBy = "terraform"
    Project   = var.project_name
  }
}

output "demo_parameter_arn" {
  description = "ARN of the demo SSM parameter (proof that remote state works)"
  value       = aws_ssm_parameter.demo.arn
}

output "demo_parameter_name" {
  value = aws_ssm_parameter.demo.name
}
