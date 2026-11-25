#!/usr/bin/env bash
# Deprecate golden AMIs older than N days (default 60, or the value in
# /golden-ami/deprecate-after-days). The current SSM pointer is never
# deprecated. Deprecated AMIs can still be used by existing instances
# but are hidden from new launches (CM-2, SI-2).
#
# Usage:
#   AWS_REGION=us-gov-west-1 OS=rhel9 ENVIRONMENT=dev ./scripts/deprecate-old-amis.sh
set -euo pipefail

OS="${OS:-rhel9}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
AWS_REGION="${AWS_REGION:-us-gov-west-1}"
DAYS="${DEPRECATE_AFTER_DAYS:-}"

if [[ -z "${DAYS}" ]]; then
  DAYS="$(aws ssm get-parameter --region "${AWS_REGION}" --name /golden-ami/deprecate-after-days --query 'Parameter.Value' --output text 2>/dev/null || true)"
fi
DAYS="${DAYS:-60}"

CURRENT="$(aws ssm get-parameter --region "${AWS_REGION}" --name "/golden-ami/${OS}/latest" --query 'Parameter.Value' --output text 2>/dev/null || true)"

# cutoff as ISO-8601 UTC
if date --version >/dev/null 2>&1; then
  CUTOFF="$(date -u -d "-${DAYS} days" +%Y-%m-%dT%H:%M:%SZ)"
else
  CUTOFF="$(date -u -v-"${DAYS}"d +%Y-%m-%dT%H:%M:%SZ)"
fi

echo "Deprecating ${OS} golden AMIs in ${ENVIRONMENT} older than ${DAYS} days (before ${CUTOFF}). Current pointer: ${CURRENT:-none}"

mapfile -t IMAGES < <(aws ec2 describe-images --region "${AWS_REGION}" --owners self \
  --filters "Name=tag:GoldenAMI,Values=true" "Name=tag:OS,Values=${OS}" "Name=tag:Environment,Values=${ENVIRONMENT}" \
  --query 'Images[].[ImageId,CreationDate]' --output text)

for line in "${IMAGES[@]:-}"; do
  [[ -z "${line}" ]] && continue
  id="$(awk '{print $1}' <<<"${line}")"
  created="$(awk '{print $2}' <<<"${line}")"
  if [[ "${id}" == "${CURRENT}" ]]; then
    echo "skip current ${id}"
    continue
  fi
  if [[ "${created}" < "${CUTOFF}" ]]; then
    echo "deprecate ${id} (created ${created})"
    aws ec2 enable-image-deprecation --region "${AWS_REGION}" --image-id "${id}" --deprecate-at "${CUTOFF}"
  else
    echo "keep ${id} (created ${created})"
  fi
done
