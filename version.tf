terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}
provider "aws" {
  region     = "ap-northeast-3"
  access_key = "<access-key>"
  secret_key = "<secret-key>"

  default_tags {
    tags = {
      Name = "EcsClusterFargateRozan"
    }
  }
}
