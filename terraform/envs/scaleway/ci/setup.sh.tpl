#!/bin/bash
set -euo pipefail

# ─── Config ───────────────────────────────────────────────────────────
export CI_GITEA_URL="http://${public_ip}:3000"
export CI_OAUTH_URL="http://${public_ip}:3000"
export CI_DOMAIN="${public_ip}"
export CI_WP_HOST="http://${public_ip}:8000"
export CI_ADMIN="${gitea_admin_user}"
export CI_PASSWORD="${gitea_admin_password}"
export CI_AGENT_SECRET=$(openssl rand -hex 32)
export CI_GIT_REPO_URL="${git_repo_url}"
export CI_KMS_DIR="/opt/talos/kms-output"
export CI_SOURCE_DIR="/tmp/empty-source"
export CI_GITEA_DATA_DIR="/opt/woodpecker/gitea-data"
export CI_WP_DATA_DIR="/opt/woodpecker/woodpecker-data"
export CI_PODMAN_SOCK="/run/podman/podman.sock"
export CI_SCW_PROJECT_ID="${scw_project_id}"
export CI_SCW_IMAGE_ACCESS_KEY="${scw_image_access_key}"
export CI_SCW_IMAGE_SECRET_KEY="${scw_image_secret_key}"
export CI_SCW_CLUSTER_ACCESS_KEY="${scw_cluster_access_key}"
export CI_SCW_CLUSTER_SECRET_KEY="${scw_cluster_secret_key}"
export CI_SECRETS_JSON='{"data":{"scw_project_id":"${scw_project_id}","scw_image_access_key":"${scw_image_access_key}","scw_image_secret_key":"${scw_image_secret_key}","scw_cluster_access_key":"${scw_cluster_access_key}","scw_cluster_secret_key":"${scw_cluster_secret_key}"}}'

# ─── Start ────────────────────────────────────────────────────────────
mkdir -p /tmp/empty-source /opt/talos/kms-output
envsubst '${CI_GITEA_URL} ${CI_OAUTH_URL} ${CI_DOMAIN} ${CI_WP_HOST} ${CI_ADMIN} ${CI_PASSWORD} ${CI_AGENT_SECRET} ${CI_GIT_REPO_URL} ${CI_SECRETS_JSON} ${CI_KMS_DIR} ${CI_SOURCE_DIR} ${CI_GITEA_DATA_DIR} ${CI_WP_DATA_DIR} ${CI_PODMAN_SOCK} ${CI_SCW_PROJECT_ID} ${CI_SCW_IMAGE_ACCESS_KEY} ${CI_SCW_IMAGE_SECRET_KEY} ${CI_SCW_CLUSTER_ACCESS_KEY} ${CI_SCW_CLUSTER_SECRET_KEY}' \
  < /opt/woodpecker/platform-pod.yaml > /opt/woodpecker/platform-pod-final.yaml
podman play kube /opt/woodpecker/platform-pod-final.yaml

echo "========================================="
echo "  Platform starting (KMS + CI)"
echo "========================================="
echo "  Logs: podman logs -f platform-setup"
echo "  WP:   http://${public_ip}:8000"
echo "========================================="
