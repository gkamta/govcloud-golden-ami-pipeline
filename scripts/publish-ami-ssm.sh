#!/usr/bin/env bash
# After a successful scan gate, tag the AMI and publish its ID to
# /golden-ami/<os>/latest so the launch-template module / operators can
# find the current approved image (CM-2).
#
# Usage:
#   AWS_REGION=us-gov-west-1 OS=rhel9 ENVIRONMENT=dev AMI_ID=ami-0123 \
#     ./scripts/publish-ami-ssm.sh
set -euo pipefail

: "${AMI_ID:?AMI_ID is required}"
: "${OS:?OS is required (rhel9 or windows2022)}"
: "${ENVIRONMENT:?ENVIRONMENT is required}"
AWS_REGION="${AWS_REGION:-us-gov-west-1}"
PARAMETER="/golden-ami/${OS}/latest"

aws ssm put-parameter \
  --region "${AWS_REGION}" \
  --name "${PARAMETER}" \
  --type String \
  --value "${AMI_ID}" \
  --overwrite

echo "Published ${AMI_ID} to ${PARAMETER} (${AWS_REGION}, env=${ENVIRONMENT})."
