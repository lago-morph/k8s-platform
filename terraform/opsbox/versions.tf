terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    # Configure via -backend-config — do not hardcode here. The workflow
    # supplies bucket/key/region/dynamodb_table, exactly as it does for the
    # base and management modules.
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "k8-platform"
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}
