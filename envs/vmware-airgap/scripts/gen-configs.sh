#!/usr/bin/env bash
# Generate per-node machine configs for VMware airgap deployment.
#
# Produces one .yaml file per node (cp1.yaml, cp2.yaml, ..., wrk1.yaml, ...)
# Each file contains the full machine config with static IP, ready to be
# pasted as user-data in the VMware template.
#
# Usage: ./gen-configs.sh
#
# Prerequisites: talosctl
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$(dirname "${SCRIPT_DIR}")"
# shellcheck source=/dev/null
source "${ENV_DIR}/vars.env"

PATCHES_DIR="${ENV_DIR}/patches"
OUT="${ENV_DIR}/${OUT_DIR}"
mkdir -p "${OUT}"

# ─── Step 1: Generate base configs ─────────────────────────────────────────
echo "==> Generating base Talos config for ${CLUSTER_NAME}..."
talosctl gen config "${CLUSTER_NAME}" "${CLUSTER_ENDPOINT}" \
    --output-dir "${OUT}" \
    --with-docs=false --with-examples=false \
    --kubernetes-version "${KUBERNETES_VERSION}" \
    --force

# ─── Step 2: Generate per-node patches ─────────────────────────────────────
echo "==> Generating per-node patches..."
mkdir -p "${PATCHES_DIR}"

# Convert space-separated IPs to arrays
read -ra CP_ARR <<< "${CP_IPS}"
read -ra WRK_ARR <<< "${WRK_IPS}"

generate_cp_patch() {
    local idx=$1
    local ip=$2
    local name="cp-$((idx + 1))"
    local patch_file="${PATCHES_DIR}/${name}-patch.yaml"

    cat > "${patch_file}" <<YAML
machine:
  network:
    hostname: ${name}
    nameservers:
      - ${DNS}
    interfaces:
      - deviceSelector:
          physical: true
        dhcp: false
        addresses:
          - ${ip}/${NETMASK}
        routes:
          - network: 0.0.0.0/0
            gateway: ${GATEWAY}
        vip:
          ip: ${VIP}
  install:
    disk: ${INSTALL_DISK}
    wipe: true
  features:
    imageCache:
      localEnabled: true
  time:
    disabled: true
  registries:
    mirrors:
      docker.io:
        endpoints: []
      ghcr.io:
        endpoints: []
      registry.k8s.io:
        endpoints: []
cluster:
  network:
    cni:
      name: none
  proxy:
    disabled: true
  discovery:
    enabled: false
  allowSchedulingOnControlPlanes: false
---
apiVersion: v1alpha1
kind: VolumeConfig
name: IMAGECACHE
provisioning:
  diskSelector:
    match: 'system_disk'
YAML
    echo "   ${patch_file}"
}

generate_wrk_patch() {
    local idx=$1
    local ip=$2
    local name="wrk-$((idx + 1))"
    local patch_file="${PATCHES_DIR}/${name}-patch.yaml"

    cat > "${patch_file}" <<YAML
machine:
  network:
    hostname: ${name}
    nameservers:
      - ${DNS}
    interfaces:
      - deviceSelector:
          physical: true
        dhcp: false
        addresses:
          - ${ip}/${NETMASK}
        routes:
          - network: 0.0.0.0/0
            gateway: ${GATEWAY}
  install:
    disk: ${INSTALL_DISK}
    wipe: true
  features:
    imageCache:
      localEnabled: true
  time:
    disabled: true
  registries:
    mirrors:
      docker.io:
        endpoints: []
      ghcr.io:
        endpoints: []
      registry.k8s.io:
        endpoints: []
cluster:
  network:
    cni:
      name: none
  proxy:
    disabled: true
  discovery:
    enabled: false
---
apiVersion: v1alpha1
kind: VolumeConfig
name: IMAGECACHE
provisioning:
  diskSelector:
    match: 'system_disk'
YAML
    echo "   ${patch_file}"
}

for i in "${!CP_ARR[@]}"; do
    generate_cp_patch "${i}" "${CP_ARR[$i]}"
done

for i in "${!WRK_ARR[@]}"; do
    generate_wrk_patch "${i}" "${WRK_ARR[$i]}"
done

# ─── Step 3: Apply patches to produce final configs ────────────────────────
echo ""
echo "==> Patching base configs to produce final per-node configs..."

for i in "${!CP_ARR[@]}"; do
    name="cp-$((i + 1))"
    talosctl machineconfig patch "${OUT}/controlplane.yaml" \
        --patch "@${PATCHES_DIR}/${name}-patch.yaml" \
        -o "${OUT}/${name}.yaml"
    echo "   ${OUT}/${name}.yaml"
done

for i in "${!WRK_ARR[@]}"; do
    name="wrk-$((i + 1))"
    talosctl machineconfig patch "${OUT}/worker.yaml" \
        --patch "@${PATCHES_DIR}/${name}-patch.yaml" \
        -o "${OUT}/${name}.yaml"
    echo "   ${OUT}/${name}.yaml"
done

echo ""
echo "==> Validating generated configs..."
rc=0
for f in "${OUT}"/{cp,wrk}-*.yaml; do
    if talosctl validate -m metal -c "${f}" 2>/dev/null; then
        echo "   OK: ${f}"
    else
        echo "   FAIL: ${f}" >&2
        rc=1
    fi
done

if [ "${rc}" -ne 0 ]; then
    echo "==> Validation failed for one or more configs." >&2
    exit "${rc}"
fi

echo ""
echo "==> Done. Deliverables in ${OUT}/:"
# shellcheck disable=SC2012  # brace expansion + simple listing; find would be heavier
ls -1 "${OUT}"/{cp,wrk}-*.yaml "${OUT}/talosconfig" 2>/dev/null | sed 's/^/   /'
