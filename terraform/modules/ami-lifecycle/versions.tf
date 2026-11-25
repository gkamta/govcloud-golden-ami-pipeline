# Pin the AWS provider below v6. A major bump is a planned change, not a
# surprise Dependabot PR (see .github/dependabot.yml).
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.60, < 6.0"
    }
  }
}
