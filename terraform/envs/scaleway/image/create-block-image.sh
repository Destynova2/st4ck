#!/usr/bin/env bash
# Create a block storage snapshot + image from the QCOW2 in S3.
# Called by Terraform local-exec. Requires: scw CLI.
set -euo pipefail

IMAGE_NAME="talos-${TALOS_VERSION}-block"

# Check if image already exists
existing=$(scw instance image list name="${IMAGE_NAME}" -o json 2>/dev/null | python3 -c "import sys,json; imgs=json.load(sys.stdin); print(imgs[0]['id'] if imgs else '')" 2>/dev/null || echo "")
if [ -n "$existing" ]; then
  echo "Block image ${IMAGE_NAME} already exists (${existing}), skipping."
  exit 0
fi

echo "Importing QCOW2 as block snapshot..."
SNAP_ID=$(scw block snapshot import-from-object-storage \
  zone="${SCW_DEFAULT_ZONE}" \
  name="${IMAGE_NAME}" \
  bucket="${BUCKET_NAME}" \
  key="scaleway-amd64.qcow2" \
  size=10GB \
  -o json | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

echo "Block snapshot created: ${SNAP_ID}"

# Wait for snapshot to be available
echo "Waiting for snapshot to be ready..."
scw block snapshot wait "${SNAP_ID}" zone="${SCW_DEFAULT_ZONE}"

echo "Creating instance image from block snapshot..."
scw instance image create \
  name="${IMAGE_NAME}" \
  snapshot-id="${SNAP_ID}" \
  arch=x86_64

echo "Block image ${IMAGE_NAME} created successfully."
