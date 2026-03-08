#!/usr/bin/env bash
# Build an OCI image cache containing all container images needed for airgap.
#
# Usage: ./build-image-cache.sh [output-path]
#
# Prerequisites: talosctl, Internet access (run on connected machine)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$(dirname "${SCRIPT_DIR}")"
source "${ENV_DIR}/vars.env"

OUTPUT="${1:-${ENV_DIR}/image-cache.oci}"
IMAGES_FILE="${ENV_DIR}/${OUT_DIR}/images.txt"
mkdir -p "${ENV_DIR}/${OUT_DIR}"

echo "==> Listing default Talos ${TALOS_VERSION} images..."
talosctl image default --kubernetes-version "${KUBERNETES_VERSION}" > "${IMAGES_FILE}"

echo "==> Adding Cilium images..."
cat >> "${IMAGES_FILE}" <<EOF
quay.io/cilium/cilium:v${CILIUM_VERSION}
quay.io/cilium/operator-generic:v${CILIUM_VERSION}
quay.io/cilium/hubble-relay:v${CILIUM_VERSION}
EOF

echo "==> Images to cache:"
cat "${IMAGES_FILE}" | sed 's/^/   /'
echo ""

echo "==> Creating image cache at ${OUTPUT}..."
cat "${IMAGES_FILE}" | talosctl image cache-create \
    --image-cache-path "${OUTPUT}" \
    --images=- \
    --platform "linux/${ARCH}"

echo "==> Image cache created: $(du -h "${OUTPUT}" | cut -f1)"
