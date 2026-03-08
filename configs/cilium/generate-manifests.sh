#!/usr/bin/env bash
# Generate Cilium manifests from Helm chart for use as Talos inline manifests
# or for kubectl apply in airgap environments.
#
# Usage: ./generate-manifests.sh [output-file]
#
# Prerequisites: helm v3
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CILIUM_VERSION="${CILIUM_VERSION:-1.17.0}"
OUTPUT="${1:-${SCRIPT_DIR}/cilium-manifests.yaml}"

if ! command -v helm &>/dev/null; then
    echo "ERROR: helm is required. Install from https://helm.sh/docs/intro/install/" >&2
    exit 1
fi

# Add/update Cilium repo
helm repo add cilium https://helm.cilium.io 2>/dev/null || true
helm repo update cilium

# Template the chart
helm template cilium cilium/cilium \
    --version "${CILIUM_VERSION}" \
    --namespace kube-system \
    --values "${SCRIPT_DIR}/values.yaml" \
    > "${OUTPUT}"

echo "Cilium manifests written to ${OUTPUT}"
echo "Image versions included:"
grep -oP 'image:\s*\K\S+' "${OUTPUT}" | sort -u | sed 's/^/  /'
