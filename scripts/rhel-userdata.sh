#!/bin/bash
# Packer builder user data for RHEL 9.
#
# Why this exists: Red Hat's official RHEL AMIs do not ship the AWS Systems
# Manager (SSM) agent. Packer connects to the builder through a Session
# Manager tunnel (ssh_interface = "session_manager"), and there is no inbound
# SSH, so without the agent the instance never registers with SSM and Packer
# times out waiting for SSH.
#
# This installs the agent from the regional AWS-hosted bucket (reached over
# the NAT gateway), then starts it. In a disconnected enclave, install the RPM
# from an internal mirror or bake it into the base image instead.
set -euo pipefail

TOKEN=$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
REGION=$(curl -sS -H "X-aws-ec2-metadata-token: ${TOKEN}" \
  http://169.254.169.254/latest/meta-data/placement/region)

if ! systemctl list-unit-files | grep -q '^amazon-ssm-agent'; then
  dnf install -y \
    "https://s3.${REGION}.amazonaws.com/amazon-ssm-${REGION}/latest/linux_amd64/amazon-ssm-agent.rpm"
fi

systemctl enable --now amazon-ssm-agent
