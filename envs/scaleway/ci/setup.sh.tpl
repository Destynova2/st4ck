#!/bin/bash
set -euo pipefail

PUBLIC_IP="${public_ip}"
WORKDIR="/opt/woodpecker"

mkdir -p "$WORKDIR" /opt/talos/kms-output /tmp/empty-source

cd /opt/talos/repo/bootstrap

tofu init -input=false

tofu apply -auto-approve \
  -var="source_dir=/tmp/empty-source" \
  -var="bootstrap_dir=$WORKDIR" \
  -var="gitea_url=http://$PUBLIC_IP:3000" \
  -var="oauth_url=http://$PUBLIC_IP:3000" \
  -var="domain=$PUBLIC_IP" \
  -var="wp_host=http://$PUBLIC_IP:8000" \
  -var="admin_user=${gitea_admin_user}" \
  -var="admin_password=${gitea_admin_password}" \
  -var="git_repo_url=${git_repo_url}" \
  -var="scw_project_id=${scw_project_id}" \
  -var="scw_image_access_key=${scw_image_access_key}" \
  -var="scw_image_secret_key=${scw_image_secret_key}" \
  -var="scw_cluster_access_key=${scw_cluster_access_key}" \
  -var="scw_cluster_secret_key=${scw_cluster_secret_key}"

echo "========================================="
echo "  Platform starting"
echo "========================================="
echo "  Setup: podman logs -f platform-tofu-setup"
echo "  WP:    http://$PUBLIC_IP:8000"
echo "========================================="
