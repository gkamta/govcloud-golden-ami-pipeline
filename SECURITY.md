# Security

This repository is a **portfolio demo**. It has been validated offline (fmt, lint, `terraform validate`, `packer fmt/validate`). It has **not** been applied or baked in a real AWS account.

- Do not commit AWS keys, `.tfvars`, `backend.hcl`, or private key material.
- GitHub Actions authenticates to AWS with **OIDC**, not long-lived access keys.
- Report issues by opening a GitHub issue on `gkamta/govcloud-golden-ami-pipeline`.
- Secret scanning uses the pinned gitleaks CLI with `.gitleaks.toml`.
