# NIST 800-53 / RMF mapping (selected)

| Control | How this repo demonstrates it |
|---|---|
| IA-2 / IA-5 | GitHub OIDC, no long-lived access keys; IAM instance roles; SSH root login disabled |
| AC-2 | OIDC trust limited to this repository and allowed subjects; short-lived sessions |
| AC-3 / AC-6 | Least-privilege CI role; Ctrl-Alt-Delete disabled; no inbound security groups |
| AC-7 | Windows account lockout threshold/duration |
| AC-8 | Legal banners on RHEL and Windows |
| AU-8 / AU-12 | chronyd; auditd enabled; VPC Flow Logs |
| SC-7 | Private subnet, no inbound SG, VPC endpoints, optional no-NAT enclave |
| SC-8 / SC-13 | FIPS mode and FIPS crypto policy on RHEL |
| SC-12 / SC-28 | KMS CMK with rotation for EBS, AMIs, artifacts, and logs; IMDSv2 required |
| CM-2 / CM-3 / CM-6 | Golden AMI as the approved baseline; Terraform plan review; STIG settings baked in |
| RA-5 / SA-11 | OpenSCAP / Evaluate-STIG scan gate before the AMI is published |
| SI-2 | Monthly AMI rebuild cron + deprecation of old images |
| SI-7 | dnf gpgcheck enabled |
