# Deploy to a personal commercial AWS account

This guide walks you through deploying the demo in **your own commercial AWS account**, in **`us-east-1`**, with partition **`aws`**. You run every command yourself on your machine. Defaults in this repository still target GovCloud (`aws-us-gov`, `us-gov-west-1`); the files and variable values below override those defaults for a commercial test.

This is a **portfolio demo**, not a production or authorized environment. Nothing is applied in AWS until you run the commands here.

**Read the cost warning first.** The VPC endpoints and NAT gateway start billing as soon as `terraform apply` finishes, even if you never launch an instance. Tear the stack down the same day unless you intend to keep paying for it.

## Cost warning

If you leave the stack running, the largest bills are usually **not** the Packer builder. They are the always-on networking:

| Resource | Approximate us-east-1 rate | Approximate monthly cost if left up |
|---|---|---|
| NAT Gateway | $0.045/hour + $0.045/GB processed | ~$33/month, plus data processing |
| Public IPv4 address on the NAT gateway | $0.005/hour | ~$3.65/month |
| 7 interface VPC endpoints (one AZ) | $0.01/hour each | ~$51/month |
| S3 gateway endpoint | no hourly charge | $0 |
| Customer-managed KMS keys (state + AMI) | $1/month per key | ~$2/month |
| DynamoDB lock table (on-demand) | request-based | pennies for this demo |
| S3 state and artifacts | storage + requests | pennies for this demo |

Hourly rates above come from the [VPC pricing](https://aws.amazon.com/vpc/pricing/) and [PrivateLink pricing](https://aws.amazon.com/privatelink/pricing/) pages (NAT Gateway and public IPv4; interface endpoint hourly charge). KMS is from [KMS pricing](https://aws.amazon.com/kms/pricing/). Treat every dollar figure in this document as **approximate** and confirm on those pages before you rely on it.

Together, NAT + the Elastic IP + the seven interface endpoints are about **$0.12/hour**, or a little under **$90/month**, even with Auto Scaling groups at zero. A $10 budget will be crossed in roughly three to four days if you forget to destroy the stack.

The seven interface endpoints this repo creates are `ssm`, `ssmmessages`, `ec2messages`, `ec2`, `sts`, `kms`, and `logs`. The S3 endpoint is a gateway endpoint and does not have that hourly charge. They exist so Packer and the fleet can use SSM Session Manager with no inbound SSH or RDP.

### Cheaper path

The cheapest way to see the Terraform land is:

1. Set the $10 budget in step 2.
2. Apply bootstrap + `terraform/envs/dev` with `asg_desired_capacity = 0` (step 5).
3. Set the GitHub variables (step 6).
4. **Skip the Packer bake** and **run teardown the same day** (step 11).

You will still pay for NAT and the endpoints for however many hours the stack is up. A two-hour apply-and-destroy is typically a few dollars, not tens.

A RHEL bake adds compute, EBS, and a Red Hat license on top of that (see the cost table at the end). The Windows bake is optional and usually more expensive because of the Windows license, a larger builder, and a longer run. Skip Windows unless you specifically want to exercise that path.

---

## What you will set up

1. Confirm tools and sign in with an MFA-backed admin identity (not the root user).
2. Create a $10 monthly cost budget with an email alert.
3. Confirm the commercial Red Hat AMI owner ID.
4. Bootstrap the Terraform state bucket, lock table, and state KMS key.
5. Apply the `dev` environment with commercial settings and Auto Scaling groups at zero.
6. Set GitHub Actions repository variables and the `dev` / `prod` Environments.
7. Optionally dispatch the RHEL 9 bake workflow.
8. Optionally scale the RHEL ASG to 1 and connect with SSM Session Manager (no SSH).
9. Tear everything down in the right order.

---

## 1. Prerequisites

Install these on your machine, or confirm they are already present:

| Tool | Version to use | Why |
|---|---|---|
| [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | 2.x | Every AWS command in this guide |
| [Terraform](https://developer.hashicorp.com/terraform/install) | 1.9.x (CI uses **1.9.8**) | Bootstrap and the `dev` stack |
| [GitHub CLI](https://cli.github.com/) (`gh`) | current | Set repo variables and dispatch workflows |
| [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) | current | `aws ssm start-session` in step 9 |
| Packer 1.14.2 | only if you bake locally; GitHub Actions already pins this | Optional |

You also need:

- A **personal commercial AWS account** you are allowed to spend money in.
- An **IAM Identity Center (SSO) user** or an **IAM user with MFA**, with enough permission to create IAM, VPC, EC2, KMS, S3, SSM, and Budgets resources. **Do not use the account root user**, and do not put long-lived access keys in Git or in GitHub Actions secrets. This repo uses GitHub OIDC instead of access keys in CI.
- The GitHub repo `gkamta/govcloud-golden-ami-pipeline` already pushed, and `gh` authenticated to that account (`gh auth login` if needed).
- A clone of the repo on your machine, on the `main` branch, with this deploy guide in `docs/DEPLOY-COMMERCIAL.md`.

---

## 2. Sign in and check the tools

Prefer IAM Identity Center over static access keys.

```bash
aws --version
terraform version
gh --version
session-manager-plugin --version
```

Success looks like AWS CLI `2.x.x`, Terraform `1.9.x`, and a Session Manager plugin version, not `command not found`.

If you use IAM Identity Center:

```bash
aws configure sso
# SSO start URL and region come from your AWS access portal.
# CLI default region: us-east-1
# CLI default output: json
aws sso login --profile YOUR_PROFILE
export AWS_PROFILE=YOUR_PROFILE
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
```

If you use an IAM user, configure a named profile and **require MFA**. Do not use the root account. A short-lived session from `aws sts get-session-token --serial-number arn:aws:iam::ACCOUNT_ID:mfa/USERNAME --token-code 123456` is safer than leaving permanent keys in the default profile.

Confirm the account, region, and that you are not root:

```bash
aws sts get-caller-identity --region us-east-1
aws configure get region || echo "region is $AWS_REGION"
```

Success looks like:

```json
{
    "UserId": "AROA...:you",
    "Account": "123456789012",
    "Arn": "arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_.../you"
}
```

Write down the 12-digit **Account** value. You will use it in bucket names and as `allowed_account_ids`. The ARN should not be `arn:aws:iam::ACCOUNT:root`.

From here on, run commands from the repository root (`govcloud-golden-ami-pipeline`). Keep `AWS_PROFILE` and `AWS_REGION=us-east-1` set in the same terminal.

---

## 3. Create a $10 monthly budget

Do this **before** `terraform apply`. The Budgets API is reached in `us-east-1`.

Replace `ACCOUNT_ID` and `YOUR_EMAIL` and save these two files somewhere outside Git, or in `/tmp`:

`/tmp/golden-ami-budget.json`:

```json
{
  "BudgetName": "golden-ami-demo-10",
  "BudgetLimit": { "Amount": "10", "Unit": "USD" },
  "BudgetType": "COST",
  "TimeUnit": "MONTHLY"
}
```

`/tmp/golden-ami-budget-notify.json`:

```json
[
  {
    "Notification": {
      "NotificationType": "ACTUAL",
      "ComparisonOperator": "GREATER_THAN",
      "Threshold": 80,
      "ThresholdType": "PERCENTAGE"
    },
    "Subscribers": [
      { "SubscriptionType": "EMAIL", "Address": "YOUR_EMAIL" }
    ]
  },
  {
    "Notification": {
      "NotificationType": "FORECASTED",
      "ComparisonOperator": "GREATER_THAN",
      "Threshold": 100,
      "ThresholdType": "PERCENTAGE"
    },
    "Subscribers": [
      { "SubscriptionType": "EMAIL", "Address": "YOUR_EMAIL" }
    ]
  }
]
```

```bash
aws budgets create-budget \
  --account-id ACCOUNT_ID \
  --budget file:///tmp/golden-ami-budget.json \
  --notifications-with-subscribers file:///tmp/golden-ami-budget-notify.json
```

Success: the command prints no output and exits 0. Confirm:

```bash
aws budgets describe-budget --account-id ACCOUNT_ID --budget-name golden-ami-demo-10 \
  --query 'Budget.{Name:BudgetName,Limit:BudgetLimit,Time:TimeUnit}'
```

You should see `"Name": "golden-ami-demo-10"` and `"Amount": "10"`. AWS will also email you to confirm the budget subscription; click the confirmation link or alerts will not arrive.

**Console alternative:** Billing and Cost Management → Budgets → Create budget → Cost budget → monthly, $10, email at 80% actual and 100% forecasted.

If you get `AccessDeniedException`, the identity you signed in with does not have `budgets:CreateBudget` (often grouped with billing access). Use an admin role, or create the budget in the console while signed in as a billing-capable user.

This budget **does not stop spend**. It only emails you. Teardown is what actually stops the NAT and endpoint charges.

---

## 4. Confirm the commercial RHEL 9 AMI owner

This repo's commercial fallback uses owner **`309956199498`**, which is the official Red Hat account for RHEL AMIs in the commercial partition. Confirm it in your region before you bake or rely on `fallback_to_base_ami`:

```bash
aws ec2 describe-images \
  --region us-east-1 \
  --owners 309956199498 \
  --filters "Name=name,Values=RHEL-9*_HVM-*-x86_64-*" "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].[ImageId,Name,OwnerId]' \
  --output text
```

Success looks like:

```text
ami-0abcdef1234567890	RHEL-9.x_HVM-...-x86_64-...	309956199498
```

If this returns nothing, do not proceed with a RHEL bake until you have identified the current official owner and name filter for `us-east-1`. The GovCloud owner ID is different and will not work here.

---

## 5. Bootstrap the Terraform state backend

The bootstrap stack uses **local** state. It creates the S3 bucket, DynamoDB lock table, and KMS key that every later environment uses. Bucket names are global, so include your account ID.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
STATE_BUCKET="golden-ami-tfstate-${ACCOUNT_ID}"
echo "Account: $ACCOUNT_ID"
echo "State bucket: $STATE_BUCKET"

terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap plan \
  -var="aws_region=us-east-1" \
  -var="state_bucket_name=${STATE_BUCKET}" \
  -var="lock_table_name=terraform-state-lock"
```

A successful plan ends with `Plan: N to add, 0 to change, 0 to destroy.` (N is typically around 8–10 resources: KMS key and alias, S3 bucket plus versioning, encryption, public access block, lifecycle, bucket policy, and the DynamoDB table).

```bash
terraform -chdir=terraform/bootstrap apply \
  -var="aws_region=us-east-1" \
  -var="state_bucket_name=${STATE_BUCKET}" \
  -var="lock_table_name=terraform-state-lock"
```

Type `yes` when prompted. Success ends with:

```text
Apply complete! Resources: N added, 0 changed, 0 destroyed.

Outputs:

lock_table = "terraform-state-lock"
lock_table_arn = "arn:aws:dynamodb:us-east-1:ACCOUNT_ID:table/terraform-state-lock"
state_bucket = "golden-ami-tfstate-ACCOUNT_ID"
state_bucket_arn = "arn:aws:s3:::golden-ami-tfstate-ACCOUNT_ID"
state_kms_key_arn = "arn:aws:kms:us-east-1:ACCOUNT_ID:key/..."
```

Save those output values:

```bash
STATE_BUCKET=$(terraform -chdir=terraform/bootstrap output -raw state_bucket)
STATE_BUCKET_ARN=$(terraform -chdir=terraform/bootstrap output -raw state_bucket_arn)
LOCK_TABLE=$(terraform -chdir=terraform/bootstrap output -raw lock_table)
LOCK_TABLE_ARN=$(terraform -chdir=terraform/bootstrap output -raw lock_table_arn)
STATE_KMS_KEY_ARN=$(terraform -chdir=terraform/bootstrap output -raw state_kms_key_arn)
```

Common errors:

- `BucketAlreadyExists` / `BucketAlreadyOwnedByYou` — pick a unique `state_bucket_name` and re-run the plan.
- `InvalidClientTokenId` or expired SSO — run `aws sso login --profile YOUR_PROFILE` again.
- Wrong region — bootstrap `aws_region` must be `us-east-1` to match the later backend.

---

## 6. Write the commercial `dev` backend and tfvars

```bash
cd terraform/envs/dev
cp backend.hcl.example backend.hcl
cp terraform.tfvars.commercial.example terraform.tfvars
```

`backend.hcl` is gitignored. Edit it so it looks like this, using the bootstrap outputs (do not commit it):

```hcl
bucket         = "golden-ami-tfstate-ACCOUNT_ID"
key            = "govcloud-golden-ami-pipeline/dev/terraform.tfstate"
region         = "us-east-1"
dynamodb_table = "terraform-state-lock"
encrypt        = true
kms_key_id     = "arn:aws:kms:us-east-1:ACCOUNT_ID:key/YOUR_STATE_KEY_ID"
```

`terraform.tfvars` is also gitignored. Start from `terraform.tfvars.commercial.example` and replace every `ACCOUNT_ID`. The important commercial values are:

```hcl
aws_region         = "us-east-1"
expected_partition = "aws"
availability_zone  = "us-east-1a"
allowed_account_ids = ["ACCOUNT_ID"]

environment           = "dev"
vpc_cidr              = "10.50.0.0/16"
private_subnet_cidr   = "10.50.1.0/24"
public_subnet_cidr    = "10.50.0.0/24"
enable_nat_gateway    = true
fallback_to_base_ami  = true

rhel9_instance_type    = "t3.small"
windows_instance_type  = "t3.medium"
asg_min_size           = 0
asg_max_size           = 1
asg_desired_capacity   = 0

artifacts_bucket_name       = "golden-ami-artifacts-dev-ACCOUNT_ID"
github_repository           = "gkamta/govcloud-golden-ami-pipeline"
create_github_oidc_provider = true
state_bucket_arn            = "arn:aws:s3:::golden-ami-tfstate-ACCOUNT_ID"
lock_table_arn              = "arn:aws:dynamodb:us-east-1:ACCOUNT_ID:table/terraform-state-lock"
owner                       = "gkamta"
```

Why these values:

- `expected_partition = "aws"` is a guardrail. If you accidentally point the provider at GovCloud, apply fails instead of creating resources in the wrong partition.
- `enable_nat_gateway = true` lets the Packer builder reach RHUI (and Windows Update, if you bake Windows). A disconnected GovCloud enclave would set this to `false` and use a mirror.
- `fallback_to_base_ami = true` is required for the first apply, because no golden AMI has been published yet. The launch template needs an AMI ID. Combined with `asg_desired_capacity = 0`, Terraform can still apply without launching a billable RHEL or Windows instance.
- `asg_desired_capacity = 0` and `asg_min_size = 0` keep the demo fleets off until you choose to start one. The module defaults are otherwise `min = 1`, `desired = 1`, `max = 2` with `t3.medium` / `t3.large`.
- `create_github_oidc_provider = true` on a first-time account. If this account already has the GitHub OIDC provider (for example from `devsecops-eks-demo`), set it to `false` or apply will fail with `EntityAlreadyExists`.
- `state_bucket_arn` and `lock_table_arn` are added to the CI role so GitHub Actions can use the same backend later.

Return to the repository root after editing:

```bash
cd ../../..
```

---

## 7. Plan and apply the `dev` environment

```bash
terraform -chdir=terraform/envs/dev init -backend-config=backend.hcl
terraform -chdir=terraform/envs/dev validate
terraform -chdir=terraform/envs/dev plan
```

A successful init mentions the S3 backend and DynamoDB lock. A successful plan ends with `Plan: N to add, 0 to change, 0 to destroy.` and should show `partition` resolving to `aws`, a NAT gateway, the seven interface endpoints, and Auto Scaling groups with desired capacity 0.

```bash
terraform -chdir=terraform/envs/dev apply
```

Type `yes`. The first apply often takes several minutes because of the NAT gateway, IAM propagation, and VPC endpoints. Success ends with `Apply complete! Resources: N added, 0 changed, 0 destroyed.` and outputs including:

```text
artifacts_bucket = "golden-ami-artifacts-dev-ACCOUNT_ID"
github_actions_role_arn = "arn:aws:iam::ACCOUNT_ID:role/..."
kms_key_arn = "arn:aws:kms:us-east-1:ACCOUNT_ID:key/..."
packer_instance_profile = "..."
packer_security_group_id = "sg-..."
packer_subnet_id = "subnet-..."
packer_vpc_id = "vpc-..."
partition = "aws"
rhel9_asg_name = "..."
windows2022_asg_name = "..."
golden_ami_parameter_names = { ... }
```

Capture them:

```bash
terraform -chdir=terraform/envs/dev output
```

Common errors:

- Partition guardrail fails — `expected_partition` is still `aws-us-gov`, or `AWS_REGION` is a GovCloud region. Fix `terraform.tfvars` and the backend region, then plan again.
- `EntityAlreadyExists` on `aws_iam_openid_connect_provider` — set `create_github_oidc_provider = false` and apply again.
- `InvalidVpcID.NotFound` or endpoint errors mid-apply — re-run `terraform apply`; some VPC resources eventually become consistent.
- `Error acquiring the state lock` — another Terraform process is running. Do not `force-unlock` unless you are sure no apply is in progress. If the process is dead, unlock with the lock ID Terraform printed, then `plan` to confirm state is healthy.
- `coalesce` / no AMI ID — `fallback_to_base_ami` is false and no golden AMI exists yet. Set it to `true` for the first apply.
- `us-east-1a` has no capacity or the AZ name is wrong — pick another AZ (`us-east-1b`, and so on) and plan again.

You are now paying for NAT and the endpoints. If you only wanted to land the infrastructure, skip to step 11 after you optionally set the GitHub variables, or continue to bake a RHEL AMI.

---

## 8. Set GitHub Actions variables and Environments

The AMI workflows no-op with a notice until `AWS_CI_ROLE_ARN` and `PACKER_SUBNET_ID` are set. Set them from the `dev` outputs, in the repository root, while `gh` is authenticated to `gkamta/govcloud-golden-ami-pipeline`.

```bash
gh variable set AWS_CI_ROLE_ARN --body "$(terraform -chdir=terraform/envs/dev output -raw github_actions_role_arn)"
gh variable set AWS_REGION --body "us-east-1"
gh variable set TF_STATE_BUCKET --body "$(terraform -chdir=terraform/bootstrap output -raw state_bucket)"
gh variable set TF_LOCK_TABLE --body "$(terraform -chdir=terraform/bootstrap output -raw lock_table)"
gh variable set PACKER_VPC_ID --body "$(terraform -chdir=terraform/envs/dev output -raw packer_vpc_id)"
gh variable set PACKER_SUBNET_ID --body "$(terraform -chdir=terraform/envs/dev output -raw packer_subnet_id)"
gh variable set PACKER_SG_ID --body "$(terraform -chdir=terraform/envs/dev output -raw packer_security_group_id)"
gh variable set PACKER_INSTANCE_PROFILE --body "$(terraform -chdir=terraform/envs/dev output -raw packer_instance_profile)"
gh variable set AMI_KMS_KEY_ID --body "$(terraform -chdir=terraform/envs/dev output -raw kms_key_arn)"
gh variable set ARTIFACTS_BUCKET --body "$(terraform -chdir=terraform/envs/dev output -raw artifacts_bucket)"

gh variable list
```

Success: `gh variable list` shows all ten names. `AWS_REGION` must be `us-east-1`. If you leave it unset, the AMI workflow falls back to `us-gov-west-1` and the bake will fail in a commercial account.

Create the GitHub Environments the workflows reference. Required reviewers are optional on a personal repo; if you add them, a bake or apply will wait until you approve it.

```bash
gh api --method PUT repos/gkamta/govcloud-golden-ami-pipeline/environments/dev
gh api --method PUT repos/gkamta/govcloud-golden-ami-pipeline/environments/prod
```

Success returns JSON for each environment, including `"name": "dev"` and `"name": "prod"`. You can also create them in the GitHub UI under Settings → Environments.

---

## 9. Dispatch the RHEL 9 bake (optional)

The workflow file is `.github/workflows/ami-rhel.yml`. Its workflow name is `ami-rhel9`. A bake launches a Packer builder (default instance type in the Packer template is `t3.medium`), runs Ansible STIG + FIPS + OpenSCAP, and publishes the AMI only if the CAT I gate passes. Expect on the order of 20–40 minutes, sometimes longer.

```bash
gh workflow run ami-rhel.yml --ref main -f environment=dev
gh run list --workflow=ami-rhel.yml --limit 3
```

Success: `gh workflow run` exits 0, and `gh run list` shows a new run `in_progress` or `queued` on `main`. Watch it:

```bash
# Replace with the databaseId from gh run list
gh run watch RUN_ID
```

A successful bake job is green. In the log you should see Packer finish with a line similar to `AMIs were created:\n  us-east-1: ami-...`, then the publish script updating SSM. OpenSCAP reports are uploaded as workflow artifacts and also to the artifacts bucket.

Download the scan artifact from the run page, or:

```bash
gh run download RUN_ID --dir /tmp/ami-rhel-artifacts
aws s3 ls "s3://$(terraform -chdir=terraform/envs/dev output -raw artifacts_bucket)/" --recursive
```

Confirm the published AMI and SSM parameter. The RHEL parameter name is `/golden-ami/rhel9/latest`:

```bash
aws ssm get-parameter --name /golden-ami/rhel9/latest --region us-east-1
aws ssm get-parameter --name /golden-ami/rhel9/latest --region us-east-1 \
  --query Parameter.Value --output text
```

Success looks like a parameter `Value` of `ami-` followed by a hex id. Then:

```bash
AMI_ID=$(aws ssm get-parameter --name /golden-ami/rhel9/latest --region us-east-1 --query Parameter.Value --output text)
aws ec2 describe-images --image-ids "$AMI_ID" --region us-east-1 \
  --query 'Images[0].{Id:ImageId,Name:Name,State:State,Encrypted:BlockDeviceMappings[0].Ebs.Encrypted}'
```

Success: `State` is `available`, and the root volume should show as encrypted.

Common errors:

- The job prints a notice and skips the bake — `AWS_CI_ROLE_ARN` or `PACKER_SUBNET_ID` is missing. Re-run step 8 and dispatch again.
- `Not authorized to perform sts:AssumeRoleWithWebIdentity` — the role's trust policy does not match this repo or the GitHub Environment name. Confirm `github_repository = "gkamta/govcloud-golden-ami-pipeline"` and that the workflow used `environment=dev`.
- Packer times out waiting for SSM — the builder cannot reach the `ssm` / `ssmmessages` / `ec2messages` endpoints, the instance profile is wrong, or the instance is still booting. Confirm the GitHub variables match the `dev` outputs, and that apply finished cleanly.
- OpenSCAP CAT I gate fails the bake — that is the gate working. Fix the role or document an exception; do not publish a failing image.
- Region mismatch — `AWS_REGION` is not `us-east-1`, or Packer was pointed at a GovCloud subnet ID.

Do **not** dispatch `ami-windows.yml` yet. See step 10.

---

## 10. Optional: launch one RHEL instance and connect with Session Manager

Only do this after a successful bake, so the launch template can pick up `/golden-ami/rhel9/latest` rather than a vendor base AMI. If you skip the bake and scale up anyway, `fallback_to_base_ami = true` will launch a stock RHEL 9 AMI and you will still pay the RHEL license.

Refresh Terraform so the launch template sees the new AMI, then scale the RHEL group to 1 (the Windows group stays at 0):

```bash
terraform -chdir=terraform/envs/dev apply
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$(terraform -chdir=terraform/envs/dev output -raw rhel9_asg_name)" \
  --region us-east-1 \
  --query 'AutoScalingGroups[0].{Desired:DesiredCapacity,Instances:Instances}'
```

If desired capacity is still 0 after apply (because `asg_desired_capacity` is 0 in tfvars), raise it once:

```bash
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name "$(terraform -chdir=terraform/envs/dev output -raw rhel9_asg_name)" \
  --desired-capacity 1 \
  --region us-east-1
```

Wait until the instance is `InService` and SSM-registered (often a few minutes):

```bash
ASG=$(terraform -chdir=terraform/envs/dev output -raw rhel9_asg_name)
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" --region us-east-1 \
  --query 'AutoScalingGroups[0].Instances'
```

When you have an `InstanceId`:

```bash
INSTANCE_ID=i-xxxxxxxxxxxxxxxxx
aws ssm describe-instance-information --region us-east-1 \
  --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
  --query 'InstanceInformationList[0].{Id:InstanceId,Ping:PingStatus}'
aws ssm start-session --target "$INSTANCE_ID" --region us-east-1
```

Success: `PingStatus` is `Online`, and `start-session` prints `Starting session with SessionId: ...` and drops you into a shell. There is **no SSH** and no inbound security-group rule for port 22; that is intentional. Exit the session with `exit`.

To avoid leaving a RHEL instance running, scale back to zero when you are done:

```bash
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name "$(terraform -chdir=terraform/envs/dev output -raw rhel9_asg_name)" \
  --desired-capacity 0 \
  --region us-east-1
```

Common errors:

- `SessionManagerPlugin is not found` — install the Session Manager plugin from the AWS docs in step 1.
- Instance never appears in SSM — wait for cloud-init, confirm the instance profile, and confirm the three SSM endpoints are available in the subnet. There should be no need to open SSH.
- `TargetNotConnected` — the agent is not registered yet, or the instance is in a public-looking path without the endpoints. This stack is private-plus-endpoints by design.

---

## 11. Optional Windows bake — cost warning

Skip this unless you specifically want to exercise the Windows path. Compared with the RHEL bake it is usually slower and more expensive:

- Windows on-demand pricing is higher than Linux. Confirm current `us-east-1` numbers on the [EC2 On-Demand pricing](https://aws.amazon.com/ec2/pricing/on-demand/) page.
- The Packer Windows builder runs longer (sysprep / EC2Launch, STIG, optional Evaluate-STIG). Thirty minutes to well over an hour is common.
- The Windows demo ASG defaults to `t3.large` in code; the commercial tfvars example uses `t3.medium`, which is still more than the RHEL `t3.small`.
- Keep `asg_desired_capacity = 0` so a Windows instance is not launched from the vendor base AMI just because you applied Terraform.

If you still want to run it:

```bash
gh workflow run ami-windows.yml --ref main -f environment=dev
gh run list --workflow=ami-windows.yml --limit 3
```

The published parameter is `/golden-ami/windows2022/latest`. Evaluate-STIG is a placeholder in this public repo (DISA does not allow redistributing the tool), so treat a Windows bake as an AMI + hardening exercise, not a full STIG certification run.

---

## 12. Teardown (do this the same day)

Terraform does **not** destroy AMIs, snapshots, or SSM parameters created by Packer. Versioned S3 buckets also refuse to delete until every object version and delete marker is gone. Use this order.

### 12.1 Scale the fleets to zero

```bash
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name "$(terraform -chdir=terraform/envs/dev output -raw rhel9_asg_name)" \
  --desired-capacity 0 --region us-east-1 || true
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name "$(terraform -chdir=terraform/envs/dev output -raw windows2022_asg_name)" \
  --desired-capacity 0 --region us-east-1 || true
```

Wait until no instances remain in either group.

### 12.2 Destroy the `dev` environment

```bash
terraform -chdir=terraform/envs/dev destroy
```

Type `yes`. If destroy fails because the artifacts bucket is not empty, empty all versions first (this is irreversible). Repeat the delete step until the bucket has no versions or delete markers left:

```bash
ARTIFACTS=$(terraform -chdir=terraform/envs/dev output -raw artifacts_bucket)

# Write object versions and delete markers to a delete payload (up to 1000 at a time).
aws s3api list-object-versions --bucket "$ARTIFACTS" --region us-east-1 --output json \
  | python3 -c 'import json,sys; data=json.load(sys.stdin); objs=[{"Key":o["Key"],"VersionId":o["VersionId"]} for k in ("Versions","DeleteMarkers") for o in (data.get(k) or [])]; json.dump({"Objects": objs[:1000], "Quiet": True}, sys.stdout); sys.stderr.write(str(len(objs)) + chr(10))' \
  > /tmp/delete-versions.json 2>/tmp/delete-count.txt

cat /tmp/delete-count.txt
# If the count is not 0:
aws s3api delete-objects --bucket "$ARTIFACTS" --region us-east-1 --delete file:///tmp/delete-versions.json
# Re-run the list + delete pair until the count is 0, then re-run terraform destroy.
```

Then re-run `terraform destroy`.

NAT gateways can take several minutes to destroy. When it finishes you should see `Destroy complete! Resources: N destroyed.` NAT and interface endpoint hourly charges stop once those resources are gone (billing is per-hour, partial hours are typically billed).

### 12.3 Deregister Packer AMIs and delete their snapshots

```bash
aws ec2 describe-images --region us-east-1 --owners self \
  --filters "Name=tag:Project,Values=golden-ami" \
  --query 'Images[].{Id:ImageId,Name:Name}'
```

If your images use different tags, filter by name prefix instead (the Packer templates version the AMI name). For each AMI:

```bash
AMI_ID=ami-xxxxxxxxxxxxxxxxx
# Snapshots tied to the AMI:
aws ec2 describe-images --image-ids "$AMI_ID" --region us-east-1 \
  --query 'Images[0].BlockDeviceMappings[].Ebs.SnapshotId' --output text
aws ec2 deregister-image --image-id "$AMI_ID" --region us-east-1
# Then delete each snapshot printed above:
aws ec2 delete-snapshot --snapshot-id snap-xxxxxxxx --region us-east-1
```

You can also delete the SSM parameters if you want a clean account:

```bash
aws ssm delete-parameter --name /golden-ami/rhel9/latest --region us-east-1 || true
aws ssm delete-parameter --name /golden-ami/windows2022/latest --region us-east-1 || true
```

### 12.4 Destroy bootstrap last

Empty the versioned state bucket the same way as the artifacts bucket, then:

```bash
terraform -chdir=terraform/bootstrap destroy \
  -var="aws_region=us-east-1" \
  -var="state_bucket_name=${STATE_BUCKET}" \
  -var="lock_table_name=terraform-state-lock"
```

You need the same variables you used to apply bootstrap. If the KMS keys show a 30-day pending deletion, that is expected; they stop being billable as customer-managed keys once deletion is scheduled, and they remain unusable after the window.

### 12.5 Stop the monthly bake from firing against a dead stack

The RHEL and Windows workflows have a monthly cron. If the GitHub variables still point at deleted subnets, the next scheduled run will fail (or worse, if you only destroyed part of the stack). After teardown, delete the bake-related variables:

```bash
for v in AWS_CI_ROLE_ARN PACKER_VPC_ID PACKER_SUBNET_ID PACKER_SG_ID \
         PACKER_INSTANCE_PROFILE AMI_KMS_KEY_ID ARTIFACTS_BUCKET \
         TF_STATE_BUCKET TF_LOCK_TABLE AWS_REGION; do
  gh variable delete "$v" --yes
done
```

(`--yes` may vary by `gh` version; if it errors, omit it and confirm interactively.)

### 12.6 Optional: delete the budget

```bash
aws budgets delete-budget --account-id ACCOUNT_ID --budget-name golden-ami-demo-10
```

---

## Approximate costs (us-east-1)

Figures are **approximate**, from the official pages linked below and from AWS public price lists as of this writing. Always re-check before you rely on a number.

| Item | Approximate rate | What it means for this demo |
|---|---|---|
| NAT Gateway | $0.045/hour + $0.045/GB processed ([VPC pricing](https://aws.amazon.com/vpc/pricing/)) | ~$33/month if left up, plus data during a bake |
| Public IPv4 (NAT EIP) | $0.005/hour ([VPC pricing](https://aws.amazon.com/vpc/pricing/)) | ~$3.65/month if left up |
| Interface VPC endpoint | $0.01/hour per endpoint per AZ + $0.01/GB for the first 1 PB ([PrivateLink pricing](https://aws.amazon.com/privatelink/pricing/)) | 7 endpoints ≈ $51/month if left up |
| KMS customer-managed key | $1/month per key ([KMS pricing](https://aws.amazon.com/kms/pricing/)) | two keys ≈ $2/month (state + AMI) |
| t3.micro / t3.small / t3.medium Linux | ~$0.0104 / $0.0208 / $0.0416 per hour ([T3](https://aws.amazon.com/ec2/instance-types/t3/), [On-Demand](https://aws.amazon.com/ec2/pricing/on-demand/)) | only while an instance or Packer builder is running |
| t3.small RHEL | about $0.0496/hour in public price lists (~$0.0208 Linux + a RHEL license) | RHEL is billed on a per-vCPU model since 1 July 2024; confirm on the [EC2 On-Demand](https://aws.amazon.com/ec2/pricing/on-demand/) and [RHEL on AWS](https://aws.amazon.com/partners/redhat/) pages |
| t3.medium RHEL (Packer default builder) | about $0.0704/hour in public price lists | a 30-minute bake is well under a dollar for compute, plus license, EBS, and NAT data |
| Windows on-demand | higher than Linux; size-dependent | confirm on the On-Demand page; skip the Windows bake to avoid this |

**Cheaper path (recommended first run):** apply Terraform with ASG capacity 0, do not dispatch Packer, destroy the same day. You avoid RHEL/Windows license hours and packer/fleet compute. You still pay NAT + endpoints for the hours the stack exists.

**Do not leave this running overnight** if you want to stay near the $10 budget. The idle networking alone is about $0.12/hour.

---

## Common errors (quick reference)

| Symptom | Likely cause | What to do |
|---|---|---|
| Partition / guardrail error | `expected_partition` or region still set for GovCloud | Use `aws` and `us-east-1` in tfvars and `backend.hcl` |
| `BucketAlreadyExists` | S3 names are global | Add your account ID to the bucket name |
| `EntityAlreadyExists` for OIDC | Provider already in the account | `create_github_oidc_provider = false` |
| Workflow no-ops | Missing `AWS_CI_ROLE_ARN` or `PACKER_SUBNET_ID` | Re-run the `gh variable set` commands |
| AssumeRoleWithWebIdentity denied | Repo name, branch, or Environment mismatch | Confirm `github_repository` and `-f environment=dev` |
| Bake in the wrong region | `AWS_REGION` GitHub variable unset (defaults to `us-gov-west-1`) | Set it to `us-east-1` |
| Packer cannot reach SSM | Endpoints, instance profile, or boot time | Wait, then re-check outputs vs. GitHub variables |
| `SessionManagerPlugin is not found` | Plugin not installed | Install it from the AWS Systems Manager docs |
| `TargetNotConnected` | Agent not registered | Wait; do not open SSH |
| State lock | Another apply, or a crashed process | Wait, or `force-unlock` only if the process is dead, then plan |
| Destroy fails on S3 | Versioning still has object versions | Delete all versions and delete markers, then destroy again |
| Budget `AccessDenied` | No billing permission | Use an admin/billing identity or the console |
| RHEL image lookup empty | Wrong owner or filter for this partition | Confirm owner `309956199498` in `us-east-1` (step 4) |

---

## What this is not

A successful apply and bake in commercial `us-east-1` proves the Terraform, Packer, and pipeline wiring in a personal account. It is **not** a GovCloud deployment, not an ATO, and not a full DISA STIG baseline. The STIG roles in this repo cover a curated set of real controls. Say that plainly if you describe the project.
