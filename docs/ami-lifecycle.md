# AMI lifecycle

1. **Bake** — Packer launches a builder in the private subnet, hardens it, and scans it.
2. **Gate** — CAT I findings fail the build; no AMI is published.
3. **Tag and version** — The AMI name includes the OS, environment, and a timestamp. Tags include `GoldenAMI=true`, `OS`, and `Environment`.
4. **Publish** — `scripts/publish-ami-ssm.sh` writes the AMI ID to `/golden-ami/<os>/latest`.
5. **Roll forward** — The `launch-template-asg` module looks up the latest tagged AMI (or the SSM pointer via a later apply) and an Auto Scaling **instance refresh** replaces instances.
6. **Deprecate** — `scripts/deprecate-old-amis.sh` calls `ec2 enable-image-deprecation` on older golden AMIs, never on the current SSM pointer.

Patch cadence is a monthly GitHub Actions cron plus a manual `workflow_dispatch` for an out-of-band critical CVE (SI-2).
