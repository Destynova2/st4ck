#!/bin/bash
set -euo pipefail

PUBLIC_IP="${public_ip}"
ADMIN="${gitea_admin_user}"
PASSWORD="${gitea_admin_password}"
AGENT_SECRET=$(openssl rand -hex 32)
WORKDIR="/opt/woodpecker"

mkdir -p "$WORKDIR" /opt/talos/kms-output /tmp/empty-source

# ─── Generate ConfigMap YAML ─────────────────────────────────────────
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
  CI_PASSWORD: "$PASSWORD"
  CI_AGENT_SECRET: "$AGENT_SECRET"
  CI_GIT_REPO_URL: "${git_repo_url}"
  CI_SCW_PROJECT_ID: "${scw_project_id}"
  CI_SCW_IMAGE_ACCESS_KEY: "${scw_image_access_key}"
  CI_SCW_IMAGE_SECRET_KEY: "${scw_image_secret_key}"
  CI_SCW_CLUSTER_ACCESS_KEY: "${scw_cluster_access_key}"
  CI_SCW_CLUSTER_SECRET_KEY: "${scw_cluster_secret_key}"
CFGEOF

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

# ─── Patch source path and start ────────────────────────────────────
sed 's|__SOURCE_DIR__|/tmp/empty-source|g' \
  "$WORKDIR/platform-pod.yaml" > "$WORKDIR/platform-pod-final.yaml"

podman play kube "$WORKDIR/platform-pod-final.yaml" \
  --configmap="$WORKDIR/configmap.yaml"

echo "========================================="
echo "  Platform starting"
echo "========================================="
echo "  Setup: podman logs -f platform-tofu-setup"
echo "  WP:    http://$PUBLIC_IP:8000"
echo "========================================="
