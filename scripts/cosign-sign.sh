#!/bin/sh
# Sign a container image with Cosign using the platform keypair.
# Usage: cosign-sign.sh <image-ref>
#
# Requires:
#   - COSIGN_KEY: path to cosign private key PEM (or K8s secret via k8s://security/cosign-private-key)
#   - COSIGN_PASSWORD: empty string (keys are not password-protected)
#   - cosign binary in PATH
#
# Example (CI pipeline):
#   COSIGN_KEY=k8s://security/cosign-private-key \
#   COSIGN_PASSWORD="" \
#   ./scripts/cosign-sign.sh harbor.storage.svc.cluster.local/myapp:v1.0
#
# Example (local with kubeconfig):
#   export KUBECONFIG=~/.kube/talos-scaleway
#   kubectl -n security get secret cosign-private-key -o jsonpath='{.data.cosign\.key}' | base64 -d > /tmp/cosign.key
#   COSIGN_KEY=/tmp/cosign.key COSIGN_PASSWORD="" cosign sign --key $COSIGN_KEY "$IMAGE"

set -eu

IMAGE="${1:?Usage: cosign-sign.sh <image-ref>}"

command -v cosign >/dev/null 2>&1 || { echo "ERROR: cosign not found in PATH"; exit 1; }
test -n "${COSIGN_KEY:-}" || { echo "ERROR: COSIGN_KEY not set"; exit 1; }

export COSIGN_PASSWORD="${COSIGN_PASSWORD:-}"

echo "Signing $IMAGE..."
cosign sign --key "$COSIGN_KEY" --yes "$IMAGE"
echo "Verifying signature..."
cosign verify --key "$COSIGN_KEY" "$IMAGE" | head -3
echo "Image signed and verified."
