#!/bin/bash
set -euo pipefail

PUBLIC_IP="${public_ip}"
ADMIN="${gitea_admin_user}"
PASSWORD="${gitea_admin_password}"
AGENT_SECRET=$(openssl rand -hex 32)
WORKDIR="/opt/woodpecker"

mkdir -p "$WORKDIR" /opt/talos/kms-output /tmp/empty-source

# ─── Idempotent: clean up any partial state from a previous failed run ──
podman pod rm -f platform 2>/dev/null || true
podman secret rm platform-secrets 2>/dev/null || true

# ─── Generate ConfigMap YAML (only ConfigMaps — podman --configmap rejects Secret) ──
cat > "$WORKDIR/configmap.yaml" <<CFGEOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: platform-config
data:
  CI_GITEA_URL: "http://$PUBLIC_IP:3000"
  CI_OAUTH_URL: "http://$PUBLIC_IP:3000"
  CI_DOMAIN: "$PUBLIC_IP"
  CI_WP_HOST: "http://$PUBLIC_IP:8000"
  CI_ADMIN: "$ADMIN"
  CI_GIT_REPO_URL: "${git_repo_url}"
  CI_SCW_PROJECT_ID: "${scw_project_id}"
CFGEOF

# ─── Generate Secret YAML (separate — concatenated into pod manifest below) ──
cat > "$WORKDIR/secrets.yaml" <<SECEOF
apiVersion: v1
kind: Secret
metadata:
  name: platform-secrets
type: Opaque
stringData:
  CI_PASSWORD: "$PASSWORD"
  CI_AGENT_SECRET: "$AGENT_SECRET"
  CI_SCW_IMAGE_ACCESS_KEY: "${scw_image_access_key}"
  CI_SCW_IMAGE_SECRET_KEY: "${scw_image_secret_key}"
  CI_SCW_CLUSTER_ACCESS_KEY: "${scw_cluster_access_key}"
  CI_SCW_CLUSTER_SECRET_KEY: "${scw_cluster_secret_key}"
SECEOF

# ─── Generate seal key ──────────────────────────────────────────────
openssl rand -out "$WORKDIR/unseal.key" 32
cat >> "$WORKDIR/configmap.yaml" <<SEALEOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: bao-seal-key
binaryData:
  unseal.key: $(base64 < "$WORKDIR/unseal.key" | tr -d '\n')
SEALEOF

# ─── Patch source path + vault-backend image and concatenate pod + secret ──
VAULT_BACKEND_IMAGE="docker.io/gherynos/vault-backend@sha256:fb654a3f344ec38edf93e31b95c81a531d3a22178e31d00c25fef2b3dcbffa03"
sed -e "s|__SOURCE_DIR__|/opt/talos/repo|g" \
    -e "s|__VAULT_BACKEND_IMAGE__|$VAULT_BACKEND_IMAGE|g" \
  /opt/talos/repo/bootstrap/platform-pod.yaml > "$WORKDIR/platform-pod.yaml"

# Append Secret as a separate YAML doc; podman play kube reads multi-doc.
{ cat "$WORKDIR/platform-pod.yaml"; echo '---'; cat "$WORKDIR/secrets.yaml"; } \
  > "$WORKDIR/pod-with-secrets.yaml"

podman play kube "$WORKDIR/pod-with-secrets.yaml" \
  --configmap="$WORKDIR/configmap.yaml"

# ─── Wait for setup sidecar to finish (or hit the gitea CSRF fallback) ──
echo "Waiting for platform setup..."
for i in $(seq 1 120); do
  if podman logs platform-tofu-setup 2>&1 | grep -q '\[setup\] ==='; then
    break
  fi
  # Fallback: gitea_install told us CSRF failed and dropped pending-user file.
  # Create the admin via gitea CLI directly, then restart the sidecar.
  if podman exec platform-tofu-setup test -f /shared/gitea-pending-user 2>/dev/null; then
    echo "[setup-fallback] gitea CSRF failed — creating admin via gitea CLI"
    PENDING=$(podman exec platform-tofu-setup cat /shared/gitea-pending-user)
    PU=$(echo "$PENDING" | cut -d: -f1)
    PP=$(echo "$PENDING" | cut -d: -f2)
    PE=$(echo "$PENDING" | cut -d: -f3)
    podman exec -u git platform-gitea gitea admin user create \
      --username "$PU" --password "$PP" --email "$PE" \
      --admin --must-change-password=false || \
      echo "[setup-fallback] user creation returned non-zero (may already exist)"
    podman exec platform-tofu-setup rm -f /shared/gitea-pending-user
    podman restart platform-tofu-setup
  fi
  sleep 5
done

# ─── Export tokens ───────────────────────────────────────────────────
mkdir -p /opt/talos/kms-output
podman cp platform-tofu-setup:/kms-output/. /opt/talos/kms-output/

echo "========================================="
echo "  Platform ready"
echo "========================================="
echo "  WP:    http://$PUBLIC_IP:8000"
echo "  Gitea: http://$PUBLIC_IP:3000"
echo "========================================="
