#!/usr/bin/env bash
# Configure Kubernetes apiServer OIDC via talosctl patch.
# Requires: ROOT_CA, TALOSCONFIG, CP_NODES (comma-separated IPs)
#
# Usage:
#   ROOT_CA="<pem>" TALOSCONFIG="/path/to/talosconfig" CP_NODES="1.2.3.4,5.6.7.8,9.10.11.12" \
#     bash scripts/setup-oidc.sh
set -euo pipefail

: "${ROOT_CA:?Set ROOT_CA env var (PEM-encoded Root CA certificate)}"
: "${TALOSCONFIG:?Set TALOSCONFIG env var (path to talosconfig file)}"
: "${CP_NODES:?Set CP_NODES env var (comma-separated control plane IPs)}"

PATCH_FILE=$(mktemp)
trap 'rm -f "$PATCH_FILE"' EXIT

# Generate the Talos machine config patch
cat > "$PATCH_FILE" <<YAML
machine:
  files:
    - content: |
$(echo "$ROOT_CA" | sed 's/^/        /')
      permissions: 0644
      path: /var/etc/kubernetes/oidc-ca.pem
      op: create
cluster:
  apiServer:
    extraArgs:
      oidc-issuer-url: "https://hydra-public.identity.svc:4444/"
      oidc-client-id: "kubernetes"
      oidc-username-claim: "sub"
      oidc-groups-claim: "groups"
      oidc-ca-file: "/var/etc/kubernetes/oidc-ca.pem"
    extraVolumes:
      - hostPath: /var/etc/kubernetes
        mountPath: /var/etc/kubernetes
        readOnly: true
YAML

echo "=== Kubernetes OIDC Configuration ==="
echo "Applying OIDC patch to control plane nodes: $CP_NODES"
echo ""

# Apply patch to all CP nodes
talosctl --talosconfig "$TALOSCONFIG" \
  patch mc --nodes "$CP_NODES" \
  --patch @"$PATCH_FILE"

echo ""
echo "Patch applied. apiServer will restart on each control plane node."
echo "Wait ~60s for all apiServer pods to restart."
echo ""
echo "To verify:"
echo "  kubectl get --raw /.well-known/openid-configuration"
echo ""
echo "To login with OIDC (requires kubelogin plugin):"
echo "  kubectl oidc-login setup --oidc-issuer-url=https://hydra-public.identity.svc:4444/ --oidc-client-id=kubernetes"
