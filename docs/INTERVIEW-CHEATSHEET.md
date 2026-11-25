# Interview cheat sheet — govcloud-golden-ami-pipeline

Use this the night before and once more 15 minutes before the 12:00 PM ET call. The long explanation is in `docs/WALKTHROUGH.md`. Always say **6+ years**, never 8+. Do not claim this repo was deployed to AWS; it is validated offline.

---

## 2-minute walkthrough (say this out loud)

"I built a GovCloud-oriented golden AMI pipeline that matches the AMI lifecycle on this role. GitHub Actions authenticates to AWS with OIDC — no long-lived keys, and the role is trusted only for this repository.

Terraform creates a private bake VPC. The Packer builder security group has no inbound rules. Packer reaches the instance through SSM Session Manager and VPC endpoints, which is the pattern I'd use in an enclave.

Packer bakes two images: RHEL 9 and Windows Server 2022. Volumes are KMS-encrypted and IMDSv2 is required. On RHEL, Ansible applies a curated set of real STIG IDs, then enables FIPS and reboots to verify it. On Windows, PowerShell applies the matching STIG settings and the image is generalized with EC2Launch v2 sysprep.

Before the AMI is published, OpenSCAP evaluates the DISA STIG profile on RHEL and fails the bake on any CAT I finding. Windows uses Evaluate-STIG when the DISA tool is present; I didn't vendor that tool in a public repo.

A passing image is tagged, versioned, and written to `/golden-ami/<os>/latest`. Terraform launch templates pick up the new AMI and an Auto Scaling instance refresh rolls the fleet. Older AMIs are deprecated, not yanked out from under running instances.

The repo is a portfolio demo. It's been formatted and validated offline — Terraform, Packer, Ansible lint, Checkov, gitleaks — but it has not been applied in a real account yet. I'm ready to run it inside your existing pipeline."

---

## Ten questions the hiring manager may ask about this repo

**1. Why OIDC instead of access keys?**
"There's nothing long-lived to leak or rotate. The trust policy limits `sub` to this repo and the branches or environments we allow, which covers IA-2 and AC-2. I used the same pattern in my EKS DevSecOps demo."

**2. How does Packer reach the builder if the security group has no inbound rules?**
"Session Manager. The instance profile has AmazonSSMManagedInstanceCore, and the VPC has ssm, ssmmessages, and ec2messages endpoints. Packer sets `ssh_interface = session_manager`. On Windows, user data installs OpenSSH so that SSM+SSH path works. We never open 22 or 3389."

**3. What's the difference between this and just running Ansible on a running instance?**
"The AMI is the unit of patching and STIG. We bake, scan, version, and replace instances with a launch-template instance refresh. Ansible on a live host is for drift or a hotfix, and that change still has to land back in the image pipeline the same day. I don't want snowflakes in GovCloud."

**4. Walk me through FIPS.**
"The fips role runs `fips-mode-setup --enable` and sets the crypto policy to FIPS — that's RHEL-09-671010 and RHEL-09-215105. It requires a reboot, so Packer reboots and a verify playbook asserts `/proc/sys/crypto/fips_enabled` is 1 before OpenSCAP runs. I'd rather fail the bake than find FIPS off in production."

**5. What does the scan gate actually fail on?**
"On RHEL, OpenSCAP uses `xccdf_org.ssgproject.content_profile_stig` against `ssg-rhel9-ds.xml`. A Python gate counts failed rules by severity and exits non-zero on any CAT I. That fails Packer, so no AMI is tagged or published. CAT II is reported; we can fail on those too with a flag. Scan reports go to S3 as RMF evidence."

**6. You said Evaluate-STIG is a placeholder. Isn't that a gap?**
"Yes, and I'd say so plainly. Evaluate-STIG is a DISA tool I can't legally drop into a public GitHub repo. The script runs it when it's installed and fails on CAT I, and otherwise writes notes on how to obtain it. The Windows STIG settings are still applied in the image. In your environment I'd install the official tool and set `-RequireTool` so the gate is hard."

**7. How do you roll a new AMI without downtime?**
"The launch template points at the latest tagged golden AMI. The Auto Scaling group has a rolling instance refresh triggered by launch-template changes, with a high min-healthy percentage. Old AMIs are deprecated after the SSM pointer moves, so new launches don't use them, but existing instances keep running until the refresh replaces them."

**8. How is GovCloud different in this repo?**
"Defaults are `us-gov-west-1` and partition `aws-us-gov`. ARNs, endpoints, and accounts are separate from commercial. A Terraform check fails the plan if credentials resolve to the wrong partition. Not every commercial service exists there, so the bake VPC uses a known-good endpoint set. I also parameterized the partition in my EKS demo the same way. I haven't run this bake in a production GovCloud account yet; my government production work has been in Azure Government, and I'm ready to ramp inside your landing zone."

**9. Why not EC2 Image Builder?**
"Both can produce a golden AMI. I used Packer because it lives naturally in Git with Ansible and PowerShell provisioners and is easy to explain file-by-file. Image Builder is AWS-native and handles multi-account distribution well. If the team already runs Image Builder, I'd put the same hardening in versioned components and keep the scan gate and SSM pointer. The important part is a repeatable, scanned, versioned image and a controlled rollout, not the brand of the baker."

**10. What would you do in the first 30 days on Bluewater if this isn't the existing pipeline?**
"Learn the current bake path first — Packer, Image Builder, or something internal — and the account/VPC layout. I'd map what we already have for STIG, scanning, and approvals, then close gaps: OIDC, a real CAT I gate, encrypted AMIs, and a documented rollback. I wouldn't rip out a working pipeline to install this repo. This is the reference I would use to talk about the lifecycle."

---

## Honest gaps (say these yourself if asked)

- This repo has been validated offline. It has not been applied or baked in AWS.
- You have not owned a production Packer or Image Builder factory end-to-end. You can describe and defend this design, and you can work inside theirs from day one.
- The STIG roles are a curated subset, not a complete DISA baseline.
- Evaluate-STIG is a placeholder unless the official tool is installed.
- Confirm Red Hat AMI owner IDs in the target GovCloud partition before a real RHEL bake.

If you get stuck on any question: "I haven't done that exact thing in production, but here's how I'd approach it," then reason out loud.
