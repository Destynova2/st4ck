#!/usr/bin/env bash
# Post-deployment bootstrap script for VMware airgap.
#
# Run this from a machine that has network access to the cluster nodes.
#
# Usage: ./bootstrap.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$(dirname "${SCRIPT_DIR}")"
source "${ENV_DIR}/vars.env"

TALOSCONFIG="${ENV_DIR}/${OUT_DIR}/talosconfig"

read -ra CP_ARR <<< "${CP_IPS}"
CP1="${CP_ARR[0]}"

echo "==> Checking connectivity to CP-1 (${CP1})..."
if ! talosctl version --insecure -n "${CP1}" --talosconfig "${TALOSCONFIG}" 2>/dev/null; then
    echo "ERROR: Cannot reach CP-1 at ${CP1}:50000" >&2
    echo "Ensure the VMs are running and network is accessible." >&2
    exit 1
fi
echo "   CP-1 is reachable."

echo ""
echo "==> Bootstrapping etcd on CP-1 (${CP1})..."
echo "    This should only be done ONCE for the entire cluster."
read -rp "    Proceed? [y/N] " confirm
if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

talosctl bootstrap -n "${CP1}" --talosconfig "${TALOSCONFIG}"
echo "   Bootstrap initiated."

echo ""
echo "==> Waiting for Kubernetes API to become available..."
for i in $(seq 1 30); do
    if talosctl kubeconfig /dev/stdout -n "${CP1}" --talosconfig "${TALOSCONFIG}" > /dev/null 2>&1; then
        break
    fi
    echo "   Attempt ${i}/30..."
    sleep 10
done

echo ""
echo "==> Retrieving kubeconfig..."
talosctl kubeconfig "${ENV_DIR}/${OUT_DIR}/kubeconfig" \
    -n "${CP1}" \
    --talosconfig "${TALOSCONFIG}"
echo "   Kubeconfig saved to ${ENV_DIR}/${OUT_DIR}/kubeconfig"

echo ""
echo "==> Cluster status:"
KUBECONFIG="${ENV_DIR}/${OUT_DIR}/kubeconfig" kubectl get nodes -o wide 2>/dev/null || true

echo ""
echo "==> Next steps:"
echo "   1. Install Cilium: kubectl apply -f cilium-manifests.yaml"
echo "   2. Verify nodes become Ready: kubectl get nodes -w"
echo "   3. Check Cilium status: kubectl -n kube-system get pods -l app.kubernetes.io/part-of=cilium"
