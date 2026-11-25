# Walkthrough: git push to a running, patched instance

Read this in order. It follows the pipeline the way a bake actually runs, not the way the folders are arranged on disk. For each step you will see what happens, which file to open, why it is designed that way, what usually breaks, and a sentence you can say in the interview.

This repository is a **portfolio demo validated offline**. Nothing here has been applied or baked in a real AWS account until you do that yourself.

---

## 0. The big picture

```text
GitHub Actions  --OIDC-->  IAM role
        |                      |
        |                      v
        |              Packer launches a builder
        |              in a private subnet
        |              (no inbound SG, SSM only)
        |                      |
        |                      v
        |              Ansible / PowerShell hardens
        |              + FIPS (RHEL) + scan gate
        |                      |
        |                      v
        |              AMI tagged, encrypted, published
        |              to /golden-ami/<os>/latest
        |                      |
        +-------->  Launch template + ASG instance refresh
                    Old AMIs deprecated
```

---

## 1. OIDC authentication (no access keys)

**What it does.** When the bake or Terraform workflow runs, GitHub issues a short-lived OIDC token. AWS STS exchanges that token for temporary credentials for one IAM role. There is no long-lived access key stored in GitHub secrets.

**Where to look.**

`terraform/modules/iam-oidc/main.tf` — the trust policy:

```hcl
actions = ["sts:AssumeRoleWithWebIdentity"]
# ...
condition {
  test     = "StringLike"
  variable = "token.actions.githubusercontent.com:sub"
  values   = [for s in var.allowed_subjects : "repo:${var.github_repository}:${s}"]
}
```

The default repository is `gkamta/govcloud-golden-ami-pipeline`, and allowed subjects are `main`, pull requests, and the `dev` / `prod` GitHub Environments.

The workflow side is in `.github/workflows/ami-rhel.yml` and `.github/workflows/terraform.yml`:

```yaml
permissions:
  id-token: write
# ...
uses: aws-actions/configure-aws-credentials@...
with:
  role-to-assume: ${{ vars.AWS_CI_ROLE_ARN }}
```

**Why.** IA-2 and IA-5 / AC-2: there is nothing long-lived to leak or rotate. The condition keys mean a fork or a different repo cannot assume this role.

**What goes wrong.** `Not authorized to perform sts:AssumeRoleWithWebIdentity` usually means the OIDC provider is missing in the account, `create_github_oidc_provider` should be true on the first apply, the `sub` does not match (wrong repo name or branch), or `AWS_CI_ROLE_ARN` is unset. Also confirm you are in the GovCloud partition — commercial credentials will not work there.

**How to say it in the interview.** "The pipeline never stores AWS access keys. GitHub OIDC hands the workflow a short-lived role that is trusted only for this repository and these branches, which is the same pattern I used in my EKS DevSecOps demo."

---

## 2. Build infrastructure (private VPC, no inbound, SSM endpoints)

**What it does.** Before Packer can launch anything, Terraform creates a small bake VPC: a private subnet, a security group with **no inbound rules**, an instance profile that includes `AmazonSSMManagedInstanceCore`, interface endpoints for SSM / EC2 / STS / KMS / Logs, an S3 gateway endpoint, a KMS CMK, and an artifacts bucket. A NAT gateway is optional and on by default in dev so the builder can reach RHUI or Windows Update; prod defaults it off for an enclave-style bake.

**Where to look.** `terraform/modules/packer-build-infra/main.tf`:

```hcl
# Builder security group: NO inbound rules. Packer uses SSM, not SSH/WinRM ports.
resource "aws_security_group" "builder" {
  description = "Packer builder - no inbound; SSM Session Manager only"
```

and the endpoint list in `variables.tf`:

```hcl
default = ["ssm", "ssmmessages", "ec2messages", "ec2", "sts", "kms", "logs"]
```

The environment root (`terraform/envs/dev/main.tf`) wires this module together with KMS, the GitHub OIDC role, and the AMI lifecycle parameters. `expected_partition` defaults to `aws-us-gov` and a `check "partition_guardrail"` fails the plan if you point commercial credentials at a GovCloud stack.

**Why.** SC-7 (boundary protection): the builder is not reachable from the internet, and management traffic stays on VPC endpoints. SC-12 / SC-28: volumes, AMIs, and scan reports are encrypted with a rotating CMK.

**What goes wrong.** Packer hangs on SSH if the instance profile is missing, the SSM endpoints are missing (especially `ssmmessages`), private DNS on the endpoints is off, or the security group cannot reach those endpoints on 443. In a no-NAT prod bake, dnf or Windows Update will also fail unless you have a mirrored repo.

**How to say it in the interview.** "The Packer builder lives in a private subnet with no inbound security-group rules. I reach it through SSM Session Manager and VPC endpoints, which is the pattern I'd use in a GovCloud enclave."

---

## 3. Packer launches the builder

**What it does.** Packer starts a temporary EC2 instance from a trusted RHEL 9 or Windows Server 2022 base AMI, in that private subnet, with IMDSv2 required and the root volume KMS-encrypted. It connects with `ssh_interface = "session_manager"` so it does not need port 22 or 3389. Windows user data first installs OpenSSH Server so that SSM+SSH path works.

**Where to look.** `packer/rhel9/rhel9.pkr.hcl`:

```hcl
associate_public_ip_address = false
encrypt_boot                = true
# IMDSv2 required, hop limit 1
metadata_options {
  http_tokens                 = "required"
  http_put_response_hop_limit = 1
}
communicator  = "ssh"
ssh_interface = "session_manager"
```

Windows: `packer/windows2022/windows2022.pkr.hcl` plus `scripts/windows-userdata.ps1` (installs OpenSSH and starts the SSM agent).

Region and partition variables default to `us-gov-west-1` / `aws-us-gov`. You can pass a commercial region for a fallback demo. For offline validation we run `packer validate -var source_ami=ami-0123456789abcdef0` so Packer does not call AWS.

**Why.** The AMI is the security baseline (CM-2). Encrypting the snapshot and requiring IMDSv2 means the gold image is born with those controls, not patched later.

**What goes wrong.** Wrong `ssh_username` (`ec2-user` vs `cloud-user` on some RHEL AMIs). Windows user data did not finish before Packer tried to connect — look at `C:\Windows\Temp\packer-userdata.log` and the instance screenshot or serial console. Missing KMS grants on the CI role or the instance role will fail `encrypt_boot`. If `source_ami` is empty, the name filter / owner IDs must be valid **in that partition**; confirm the Red Hat owner ID in GovCloud before a real bake.

**How to say it in the interview.** "Packer bakes the image in place, with IMDSv2 and KMS encryption on from the start, and it talks to the builder only through Session Manager."

---

## 4. Ansible hardening (and Windows PowerShell)

**What it does.** On RHEL, the Ansible provisioner runs `ansible/site-rhel.yml`: `common` (packages, chronyd, OpenSCAP tools), `ssm_agent`, and `rhel_stig`. The STIG role applies a curated set of **real** RHEL 9 STIG IDs — not a made-up list. Examples: `gpgcheck=1` (RHEL-09-214015 / 214025), `PermitRootLogin no` (RHEL-09-255045), `PermitEmptyPasswords no` (RHEL-09-255040), SSH idle timeout (RHEL-09-255100), Ctrl-Alt-Delete disabled (RHEL-09-211045 / 211050), auditd enabled (RHEL-09-653015), legal banner (RHEL-09-211020).

On Windows, Packer runs `scripts/windows-stig.ps1` (same settings as the `windows_stig` Ansible role) so the bake does not depend on inbound WinRM: Guest disabled (WN22-SO-000010), lockout 3 / 15 / 15 (WN22-AC-000010/020/030), blank-password restriction, secure-channel signing, legal banner, and `RestrictNullSessAccess` (WN22-SO-000250).

**Where to look.** `ansible/roles/rhel_stig/tasks/main.yml` and `ansible/roles/rhel_stig/templates/99-stig.conf.j2`:

```text
# RHEL-09-255045 — do not permit direct root logons over SSH
PermitRootLogin no
# RHEL-09-255100 — terminate unresponsive SSH sessions after 10 minutes
ClientAliveInterval 600
```

Roles are written to be **idempotent**: a second run should not keep changing the host. After the AMI exists, `ansible/inventories/aws_ec2.yml` can target running instances by tag over the `amazon.aws.aws_ssm` connection.

**Why.** CM-6 and CM-2: the approved settings live in Git and are baked in, not clicked on a running server. Mapping each task to a STIG ID also gives you RMF evidence (the scan in step 6 proves it).

**What goes wrong.** Ansible cannot find the builder if the SSM connection or Python interpreter is wrong (`ansible_python_interpreter=/usr/bin/python3` is set in the Packer provisioner). A drop-in under `/etc/ssh/sshd_config.d/` will not apply if a later file overrides it — we use `99-stig.conf` so it wins. On Windows, a failed sysprep later is usually leftover specialize state, not these registry keys; still, test a launch from the AMI in a non-prod account first.

**How to say it in the interview.** "Terraform builds the infrastructure; Ansible or PowerShell hardens the guest. I bake a curated set of real STIG IDs into the image so compliance is the default, then I scan to prove it."

---

## 5. FIPS mode (RHEL)

**What it does.** The `fips` role runs `fips-mode-setup --enable` and `update-crypto-policies --set FIPS` if the kernel is not already in FIPS. That requires a reboot. The role drops `/var/tmp/fips-reboot-required`, Packer reboots, and `ansible/fips-verify.yml` asserts `/proc/sys/crypto/fips_enabled` is `1` and the policy is `FIPS`.

**Where to look.** `ansible/roles/fips/tasks/main.yml` and the reboot provisioner in `packer/rhel9/rhel9.pkr.hcl`:

```hcl
provisioner "shell" {
  expect_disconnect = true
  inline = [
    "if [ -f /var/tmp/fips-reboot-required ]; then rm -f /var/tmp/fips-reboot-required; sudo reboot; else echo 'No FIPS reboot required'; fi",
  ]
}
```

**Why.** RHEL-09-671010 and RHEL-09-215105, which support SC-13 / SC-8. In a DoD or GovCloud conversation, FIPS has to be in the image, not "we'll turn it on later," because it changes the kernel and crypto stack.

**What goes wrong.** If you skip the reboot, the verify playbook fails. Some tools misbehave under FIPS; that is why verify runs **before** the scan gate and why this belongs in the bake, not on first boot of a production instance. Enabling FIPS on an already-registered system can also be painful — another reason we do it in Packer.

**How to say it in the interview.** "FIPS is enabled in the image build and verified after reboot, because it is a kernel-level change. I would rather fail the bake than discover it is off in production."

---

## 6. Scan gate (OpenSCAP / Evaluate-STIG)

**What it does.** On RHEL, `scripts/scan-rhel-openscap.sh` runs:

```bash
oscap xccdf eval \
  --profile xccdf_org.ssgproject.content_profile_stig \
  --results ... --report ... \
  /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml
```

`scripts/gate-oscap.py` parses the XCCDF results and **exits non-zero on any CAT I (high) failure**. That fails the Packer provisioner, so no AMI is published. CAT II failures are reported but do not fail the gate unless `FAIL_ON_CAT2=true`.

On Windows, `scripts/scan-windows-evaluate-stig.ps1` runs DISA Evaluate-STIG if the tool is installed. The tool is **not vendored** in this public repo (DISA distribution rules). If it is missing, the script writes a notes artifact explaining how to obtain it and, by default, does not fail the bake. In a real NAVSEA environment you would install the tool and set `-RequireTool`.

Artifacts land under `/var/tmp/scan-artifacts` (or `C:\scan-artifacts`) and are copied to the artifacts bucket when one is configured.

**Why.** RA-5 and SA-11: you do not promote an image you have not scanned. The gate is the difference between "we ran a STIG role" and "we have evidence, and a CAT I finding blocks the release."

**What goes wrong.** `openscap-scanner` or `scap-security-guide` missing — the `common` role should have installed them. Profile or content path differences between SSG versions. A CAT I you have not automated yet will (correctly) fail the bake; document an official exception or fix the role, do not lower the gate. For Evaluate-STIG, "not installed" is expected on this public demo.

**How to say it in the interview.** "The image is not published until OpenSCAP evaluates the DISA STIG profile and the gate shows zero CAT I findings. A failed scan fails the bake, which is the point of the gate."

---

## 7. AMI tag, version, and share

**What it does.** Packer names the AMI `golden-ami-<os>-<env>-<timestamp>` and tags it `GoldenAMI=true`, `OS=rhel9|windows2022`, `Environment=dev|prod`, `Partition=aws-us-gov`. The GitHub workflow also stamps a `BuildUrl` tag pointing at the run. The snapshot is KMS-encrypted because `encrypt_boot = true`. Sharing to other accounts would be an extra Packer `ami_users` / `ami_org_arns` setting or a post-build `modify-image-attribute`; this demo keeps the AMI in-account and points every workload account at the SSM parameter once you extend the launch template.

**Where to look.** The `tags` block in `packer/rhel9/rhel9.pkr.hcl` and the `create-tags` step in `.github/workflows/ami-rhel.yml`.

**Why.** CM-2: you must be able to answer "which image is approved, and who built it?" without digging through the console.

**What goes wrong.** A tag typo means the launch-template data source cannot find the AMI (`tag:GoldenAMI=true` plus `tag:OS` and `tag:Environment`). KMS key policy must allow the destination account if you later share encrypted AMIs — that is the usual surprise in multi-account sharing.

**How to say it in the interview.** "Every golden AMI is versioned in the name and tagged so Terraform can look up the latest approved image by OS and environment, not by a hard-coded AMI ID."

---

## 8. Publish the SSM parameter

**What it does.** After a successful bake, `scripts/publish-ami-ssm.sh` writes the new AMI ID to `/golden-ami/<os>/latest`. Terraform creates those parameters in `terraform/modules/ami-lifecycle` and **ignores later value changes**, so the pipeline and Terraform do not overwrite each other.

**Where to look.**

```hcl
name  = "/golden-ami/${each.key}/latest"
lifecycle {
  ignore_changes = [value]
}
```

and:

```bash
aws ssm put-parameter --name "${PARAMETER}" --type String --value "${AMI_ID}" --overwrite
```

**Why.** CM-2: there is a single pointer to the current approved image. Operators, pipelines, and (if you choose) other accounts can read one parameter instead of guessing.

**What goes wrong.** The CI role is missing `ssm:PutParameter` on that ARN (the OIDC module is wired to `module.ami_lifecycle.parameter_arns`). A typo in `OS=` publishes under the wrong path. Parameter store is regional — use the same region as the bake.

**How to say it in the interview.** "The bake pipeline publishes the AMI ID to `/golden-ami/rhel9/latest` after the scan gate passes, and Terraform leaves that value alone so the pipeline owns the pointer."

---

## 9. Launch template and Auto Scaling instance refresh

**What it does.** `terraform/modules/launch-template-asg` resolves the AMI (explicit ID, then the latest tagged golden AMI, then — in dev only — a vendor base AMI so the stack can still be planned before the first bake). It creates a launch template with IMDSv2, hop limit 1, KMS-encrypted root volume, and no public IP. The Auto Scaling group is configured with a **rolling instance refresh** triggered when the launch template changes, so a new golden AMI rolls the fleet forward instead of anyone SSHing in to patch.

**Where to look.** `terraform/modules/launch-template-asg/main.tf`:

```hcl
instance_refresh {
  strategy = "Rolling"
  preferences {
    min_healthy_percentage = var.refresh_min_healthy_percentage
    instance_warmup        = var.refresh_instance_warmup
  }
  triggers = ["launch_template"]
}
```

Dev and prod each declare a RHEL 9 fleet and a Windows Server 2022 fleet in `terraform/envs/*/main.tf`. Prod sets `fallback_to_base_ami = false` and `enable_nat_gateway = false`.

**Why.** Patching becomes "bake a new image and roll," which is the AMI lifecycle this job description is asking about (SI-2, CM-3). You do not log in and patch snowflakes.

**What goes wrong.** First apply in prod with no golden AMI and no fallback will fail the AMI lookup — bake dev first, or pass `ami_id`. An instance refresh that is too aggressive can drop capacity; we keep `min_healthy_percentage` at 90. If instances never become healthy, check the SG (no inbound is fine if SSM is the access path), the instance profile, and whether the Windows AMI was sysprep'd correctly (step 3 / 10 in your own troubleshooting).

**How to say it in the interview.** "When a new golden AMI is published, the launch template picks it up and the Auto Scaling group does a rolling instance refresh. Patching is replacing the image, not logging into servers."

---

## 10. Deprecation

**What it does.** `scripts/deprecate-old-amis.sh` lists AMIs tagged `GoldenAMI=true` for that OS and environment, skips the AMI currently in `/golden-ami/<os>/latest`, and calls `ec2 enable-image-deprecation` on images older than 60 days (or the value in `/golden-ami/deprecate-after-days`). The AMI bake workflow runs this after publishing.

**Where to look.** `scripts/deprecate-old-amis.sh` and the `deprecate_after_days` parameter in `terraform/modules/ami-lifecycle`.

**Why.** CM-2 / SI-2: old images should not keep being launched. Deprecation hides them from new launches without immediately breaking instances that are still running from them.

**What goes wrong.** Forgetting to skip the current pointer would deprecate the AMI you just published. `--deprecate-at` must be a valid timestamp. The CI role needs `ec2:EnableImageDeprecation`. Deregistering too early will break existing launch templates that still reference the old ID — deprecate first, deregister later, after the fleet has moved.

**How to say it in the interview.** "Once the new AMI is the SSM pointer, older golden AMIs are deprecated so they drop out of new launches, but running instances are not yanked out from under the mission owner."

---

## 11. Documentation and evidence

**What it does.** Scan XML/HTML reports are the RMF evidence pack (SA-11, RA-5). They are uploaded to the artifacts bucket next to the bake. Architecture and control mapping live in Git and should be updated in the same PR as a Terraform or role change, so the docs do not rot. This walkthrough, `docs/stig-and-scanning.md`, `docs/controls-mapping.md`, and `docs/ami-lifecycle.md` are that documentation.

**Where to look.** `docs/controls-mapping.md` for the NIST 800-53 mapping, `scripts/scan-rhel-openscap.sh` for how the report is produced, and the S3 upload provisioner in the Packer file.

**Why.** The job description explicitly requires system documentation. Reviewers and the next engineer on call should be able to follow the system without a hallway conversation. Generating or attaching evidence from the same pipeline that built the image is stronger than a screenshot taken later.

**What goes wrong.** Reports left only on the builder instance disappear when Packer terminates it — that is why we copy them to S3 before teardown. Docs updated in a different PR than the code change will drift.

**How to say it in the interview.** "The scan report is kept with the bake as ATO evidence, and the design notes live in Git next to the Terraform, so documentation changes with the pipeline instead of going stale."

---

## How the pieces sit on disk

| Path | Role |
|---|---|
| `terraform/modules/iam-oidc` | GitHub OIDC provider + Packer/CI role |
| `terraform/modules/kms` | CMK for AMIs, EBS, artifacts, logs |
| `terraform/modules/packer-build-infra` | Bake VPC, endpoints, no-inbound SG, instance profile, artifacts bucket |
| `terraform/modules/ami-lifecycle` | SSM pointers + deprecation policy parameter |
| `terraform/modules/launch-template-asg` | Launch template + ASG instance refresh |
| `terraform/envs/dev` and `prod` | Separate state (S3 + DynamoDB); prod is stricter |
| `terraform/bootstrap` | One-time state bucket and lock table |
| `packer/rhel9`, `packer/windows2022` | Bake definitions |
| `ansible/roles/*` | Idempotent hardening |
| `scripts/*` | Scan gate, SSM publish, deprecation |
| `.github/workflows/*` | lint, bake, terraform plan/apply |
