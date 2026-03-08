#!/usr/bin/env bash
# Validate that all required container images are present in the image cache.
#
# Compares the images listed in images.txt against the OCI cache contents.
# Run this BEFORE building the OVA to catch missing images early.
#
# Usage: ./validate-cache.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$(dirname "${SCRIPT_DIR}")"
source "${ENV_DIR}/vars.env"

IMAGES_FILE="${ENV_DIR}/${OUT_DIR}/images.txt"
IMAGE_CACHE="${ENV_DIR}/image-cache.oci"

if [[ ! -f "${IMAGES_FILE}" ]]; then
    echo "ERROR: ${IMAGES_FILE} not found. Run build-image-cache.sh first." >&2
    exit 1
fi

if [[ ! -d "${IMAGE_CACHE}" && ! -f "${IMAGE_CACHE}" ]]; then
    echo "ERROR: Image cache not found at ${IMAGE_CACHE}" >&2
    exit 1
fi

echo "==> Validating image cache against ${IMAGES_FILE}..."

TOTAL=0
MISSING=0

while IFS= read -r image; do
    [[ -z "${image}" || "${image}" =~ ^# ]] && continue
    TOTAL=$((TOTAL + 1))

    # Check if the image reference exists in the OCI layout
    # The cache is an OCI layout directory; check index.json for the image ref
    if [[ -d "${IMAGE_CACHE}" ]]; then
        if grep -q "${image}" "${IMAGE_CACHE}/index.json" 2>/dev/null; then
            echo "   OK: ${image}"
        else
            echo "   MISSING: ${image}" >&2
            MISSING=$((MISSING + 1))
        fi
    else
        echo "   SKIP: Cannot inspect non-directory cache format" >&2
    fi
done < "${IMAGES_FILE}"

echo ""
echo "==> Results: ${TOTAL} images checked, ${MISSING} missing"

if [[ ${MISSING} -gt 0 ]]; then
    echo "ERROR: ${MISSING} image(s) missing from cache. Rebuild with build-image-cache.sh." >&2
    exit 1
fi

echo "==> All images present in cache."
