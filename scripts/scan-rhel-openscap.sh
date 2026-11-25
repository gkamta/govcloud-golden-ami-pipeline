#!/usr/bin/env bash
# OpenSCAP gate for a RHEL 9 golden image.
#
# Evaluates the scap-security-guide DISA STIG profile
# (xccdf_org.ssgproject.content_profile_stig) against the local system,
# writes XML + HTML artifacts, and fails the bake if any CAT I (high)
# rule is still failing (RA-5, SA-11, CM-6).
#
# Usage (as root, on the Packer builder):
#   SCAN_DIR=/var/tmp/scan-artifacts ./scripts/scan-rhel-openscap.sh
# Optional: FAIL_ON_CAT2=true to also fail on medium findings.
set -euo pipefail

SCAN_DIR="${SCAN_DIR:-/var/tmp/scan-artifacts}"
PROFILE="${OSCAP_PROFILE:-xccdf_org.ssgproject.content_profile_stig}"
CONTENT="${OSCAP_CONTENT:-/usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml}"
FAIL_ON_CAT2="${FAIL_ON_CAT2:-false}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "${SCAN_DIR}"

if ! command -v oscap >/dev/null 2>&1; then
  echo "openscap-scanner is not installed. The common Ansible role should have installed it." >&2
  exit 2
fi
if [[ ! -f "${CONTENT}" ]]; then
  echo "SCAP content not found at ${CONTENT}. Install the scap-security-guide package." >&2
  exit 2
fi

RESULTS="${SCAN_DIR}/oscap-results.xml"
REPORT="${SCAN_DIR}/oscap-report.html"
SUMMARY="${SCAN_DIR}/oscap-summary.txt"

set +e
oscap xccdf eval \
  --profile "${PROFILE}" \
  --results "${RESULTS}" \
  --report "${REPORT}" \
  "${CONTENT}"
oscap_rc=$?
set -e
# oscap: 0 = all pass, 1 = error, 2 = one or more rules failed.
if [[ "${oscap_rc}" -eq 1 ]]; then
  echo "oscap returned an error (exit 1). See ${RESULTS}." >&2
  exit 1
fi

gate_args=("${SCRIPT_DIR}/gate-oscap.py" "${RESULTS}" "${SUMMARY}")
if [[ "${FAIL_ON_CAT2}" == "true" ]]; then
  gate_args+=(--fail-on-cat2)
fi
set +e
python3 "${gate_args[@]}"
gate_rc=$?
set -e

if [[ "${gate_rc}" -eq 10 ]]; then
  echo "GATE FAILED: one or more CAT I (high) STIG findings remain. The AMI will not be published." >&2
  exit 1
fi
if [[ "${gate_rc}" -eq 11 ]]; then
  echo "GATE FAILED: FAIL_ON_CAT2=true and CAT II findings remain." >&2
  exit 1
fi
if [[ "${gate_rc}" -ne 0 ]]; then
  echo "GATE FAILED: unexpected gate exit ${gate_rc}." >&2
  exit 1
fi
echo "GATE PASSED: no CAT I findings. Artifacts written under ${SCAN_DIR}."
