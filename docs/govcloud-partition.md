# GovCloud partition notes

AWS GovCloud is a separate partition (`aws-us-gov`) from commercial AWS (`aws`).

| Thing | GovCloud | Commercial (fallback) |
|---|---|---|
| Partition | `aws-us-gov` | `aws` |
| Regions | `us-gov-west-1`, `us-gov-east-1` | e.g. `us-west-2` |
| ARN prefix | `arn:aws-us-gov:...` | `arn:aws:...` |
| Endpoints | `*.amazonaws-us-gov.com` | `*.amazonaws.com` |
| Accounts | Separate; commercial credentials do not work | Separate |

This repo defaults every region variable to `us-gov-west-1` and `expected_partition` to `aws-us-gov`. For a commercial demo, set `aws_region = "us-west-2"` and `expected_partition = "aws"` in `terraform.tfvars` and the matching Packer variables.

The Terraform `check "partition_guardrail"` fails the plan if your credentials resolve to the wrong partition, so a commercial profile cannot accidentally apply a GovCloud stack.

Service availability and feature sets differ. Confirm the GovCloud services list before you design, and use FIPS endpoints in an authorized environment.
