#!/bin/bash
set -euo pipefail

PUBLIC_IP="${public_ip}"
WORKDIR="/opt/woodpecker"

mkdir -p "$WORKDIR" /opt/talos/kms-output /tmp/empty-source

# Wait for tofu to be installed by cloud-init
echo "Waiting for tofu..."
for i in $(seq 1 60); do
  command -v tofu >/dev/null 2>&1 && break
  echo "  attempt $i/60..." && sleep 5
done
command -v tofu >/dev/null 2>&1 || { echo "ERROR: tofu not found"; exit 1; }

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

echo "Waiting for platform setup to complete..."
for i in $(seq 1 120); do
  podman logs platform-tofu-setup 2>&1 | grep -q '\[setup\] ===' && break
  sleep 5
done

# Export tokens for remote access
mkdir -p /opt/talos/kms-output
podman cp platform-tofu-setup:/kms-output/. /opt/talos/kms-output/

echo "========================================="
echo "  Platform ready"
echo "========================================="
echo "  WP:    http://$PUBLIC_IP:8000"
echo "  Gitea: http://$PUBLIC_IP:3000"
echo "========================================="
