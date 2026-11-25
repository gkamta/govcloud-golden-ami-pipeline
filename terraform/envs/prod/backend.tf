# Partial backend config: values supplied at init time so the same code is
# reused across accounts/environments.
#   cp backend.hcl.example backend.hcl   # edit
#   terraform init -backend-config=backend.hcl
# CI validation runs `terraform init -backend=false`.
terraform {
  backend "s3" {}
}
