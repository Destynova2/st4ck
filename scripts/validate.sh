#!/usr/bin/env bash
# Validate all generated machine configs across environments.
#
# Usage: ./scripts/validate.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ERRORS=0

validate_config() {
    local file="$1"
    local mode="${2:-metal}"
    if talosctl validate -m "${mode}" -c "${file}" 2>/dev/null; then
        echo "  OK: ${file}"
    else
        echo "  FAIL: ${file}" >&2
        ERRORS=$((ERRORS + 1))
    fi
}

echo "==> Validating VMware airgap configs..."
for f in "${ROOT_DIR}"/envs/vmware-airgap/_out/{cp,wrk}-*.yaml; do
    [[ -f "${f}" ]] && validate_config "${f}" "metal"
done

echo ""
echo "==> Validating Outscale configs..."
for f in "${ROOT_DIR}"/envs/cloud/outscale/terraform/generated/*.yaml; do
    [[ -f "${f}" ]] && validate_config "${f}" "cloud"
done

echo ""
echo "==> Validating Scaleway configs..."
for f in "${ROOT_DIR}"/envs/cloud/scaleway/terraform/generated/*.yaml; do
    [[ -f "${f}" ]] && validate_config "${f}" "cloud"
done

echo ""
if [[ ${ERRORS} -gt 0 ]]; then
    echo "==> ${ERRORS} config(s) FAILED validation."
    exit 1
else
    echo "==> All configs valid."
fi
