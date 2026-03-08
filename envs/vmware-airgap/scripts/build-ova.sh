#!/usr/bin/env bash
# Build a custom OVA image with embedded image cache for airgap deployment.
#
# Usage: ./build-ova.sh
#
# Prerequisites: docker, talosctl, image-cache.oci already built
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$(dirname "${SCRIPT_DIR}")"
source "${ENV_DIR}/vars.env"

IMAGE_CACHE="${ENV_DIR}/image-cache.oci"
OVA_OUT="${ENV_DIR}/${OUT_DIR}"
mkdir -p "${OVA_OUT}"

if [[ ! -d "${IMAGE_CACHE}" && ! -f "${IMAGE_CACHE}" ]]; then
    echo "ERROR: Image cache not found at ${IMAGE_CACHE}" >&2
    echo "Run build-image-cache.sh first." >&2
    exit 1
fi

echo "==> Building OVA with Imager ${IMAGER_IMAGE}..."
echo "    Architecture: ${ARCH}"
echo "    Image cache:  ${IMAGE_CACHE}"
echo "    Schematic:    ${ENV_DIR}/schematic.yaml"
echo ""

docker run --rm -t \
    -v "${OVA_OUT}:/out" \
    -v "${IMAGE_CACHE}:/image-cache.oci:ro" \
    -v /dev:/dev --privileged \
    "${IMAGER_IMAGE}" vmware \
        --arch "${ARCH}" \
        --image-cache /image-cache.oci \
        --system-extension-image "ghcr.io/siderolabs/vmtoolsd-guest-agent:latest"

OVA_FILE="${OVA_OUT}/vmware-${ARCH}.ova"
if [[ -f "${OVA_FILE}" ]]; then
    echo "==> OVA built successfully: ${OVA_FILE} ($(du -h "${OVA_FILE}" | cut -f1))"
else
    echo "ERROR: OVA file not found at expected path ${OVA_FILE}" >&2
    ls -la "${OVA_OUT}/"
    exit 1
fi
