#!/usr/bin/env bash
# Garage post-deploy setup: layout, buckets, API keys, K8s secrets
# Idempotent — safe to re-run. Requires kubectl access to the cluster.
#
# Peer discovery is handled by [kubernetes_discovery] in garage.toml.
# Admin API calls use a temporary curl pod inside the cluster (no port-forward).
set -euo pipefail

ADMIN_TOKEN="${GARAGE_ADMIN_TOKEN:?Set GARAGE_ADMIN_TOKEN env var (must match admin_token in garage.toml)}"

# ─── Auth setup ──────────────────────────────────────────────────────
CA=$(mktemp) && CERT=$(mktemp) && KEY=$(mktemp)
trap 'rm -f "$CA" "$CERT" "$KEY"' EXIT
echo "$K8S_CA" | base64 -d > "$CA"
echo "$K8S_CERT" | base64 -d > "$CERT"
echo "$K8S_KEY" | base64 -d > "$KEY"
KC="kubectl --server=$K8S_HOST --certificate-authority=$CA --client-certificate=$CERT --client-key=$KEY"
GR="$KC exec garage-0 -n garage -- /garage"

# ─── Wait for pods ───────────────────────────────────────────────────
echo "Waiting for Garage pods to be ready..."
for i in $(seq 1 60); do
  READY=$($KC get pods -n garage -l app=garage -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -c Running || true)
  [ "$READY" -ge 3 ] && break
  echo "  $READY/3 pods running ($i/60)"
  sleep 5
done
if [ "$READY" -lt 3 ]; then
  echo "ERROR: Only $READY/3 Garage pods running after 5 minutes" >&2
  exit 1
fi
# ─── Wait for peer discovery ─────────────────────────────────────────
echo "Waiting for all 3 nodes to be discovered..."
for i in $(seq 1 30); do
  KNOWN=$($GR status 2>&1 | grep -cE '^\w{16}' || true)
  [ "$KNOWN" -ge 3 ] && break
  echo "  $KNOWN/3 nodes known ($i/30)"
  sleep 5
done
if [ "$KNOWN" -lt 3 ]; then
  echo "ERROR: Only $KNOWN/3 Garage nodes discovered after 150s" >&2
  exit 1
fi
echo "All 3 nodes discovered."

# ─── Layout ──────────────────────────────────────────────────────────
echo "Checking cluster layout..."
LAYOUT_VER=$($GR layout show 2>&1 | sed -n 's/.*Current cluster layout version: \([0-9]*\).*/\1/p' || echo "0")

if [ "$LAYOUT_VER" = "0" ]; then
  echo "Assigning layout to all nodes..."
  NODE_IDS=$($GR status 2>&1 | grep -E '^\w{16}' | awk '{print $1}')
  for NODE_ID in $NODE_IDS; do
    $GR layout assign -z dc1 -c 5GB "$NODE_ID" 2>&1 | grep -v INFO || true
  done
  echo "Applying layout version 1..."
  $GR layout apply --version 1 2>&1 | grep -v INFO || true
  echo "Layout applied."
else
  echo "Layout already configured (version $LAYOUT_VER), skipping."
fi

# ─── Buckets ─────────────────────────────────────────────────────────
for BUCKET in velero-backups; do
  if $GR bucket info "$BUCKET" >/dev/null 2>&1; then
    echo "Bucket '$BUCKET' already exists."
  else
    echo "Creating bucket '$BUCKET'..."
    $GR bucket create "$BUCKET" 2>&1 | grep -v INFO || true
  fi
done

# ─── Admin API (in-cluster curl pod) ─────────────────────────────────
# Garage v2.2+ redacts secrets in CLI output, so we use the admin API.
# Uses kubectl run --rm -i --command with a bash array — no shell, no quoting issues.
GARAGE_API="http://garage.garage.svc:3903/v1"

garage_api() {
  local METHOD="$1"
  local ENDPOINT="$2"
  local DATA="${3:-}"
  local CURL_ARGS=(-sf -X "$METHOD"
    -H "Authorization: Bearer $ADMIN_TOKEN"
    -H "Content-Type: application/json")
  [ -n "$DATA" ] && CURL_ARGS+=(-d "$DATA")
  CURL_ARGS+=("${GARAGE_API}/${ENDPOINT}")
  $KC delete pod garage-api-call -n garage --ignore-not-found >/dev/null 2>&1
  $KC run garage-api-call -n garage --rm -i --restart=Never \
    --image=curlimages/curl:8.12.1 --command -- curl "${CURL_ARGS[@]}" 2>/dev/null
}

# ─── API Keys ────────────────────────────────────────────────────────
# Garage never returns the secret of an existing key.
# We check if the K8s secret already has valid credentials; if not, we
# delete and recreate the key to get the secret.
ensure_key() {
  local KEY_NAME="$1"
  local BUCKET="$2"
  local SECRET_NS="$3"
  local SECRET_NAME="$4"
  local ACCESS_KEY SECRET_KEY

  # Check if K8s secret already exists with non-empty credentials
  local EXISTING_CLOUD
  EXISTING_CLOUD=$($KC get secret "$SECRET_NAME" -n "$SECRET_NS" -o jsonpath='{.data.cloud}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  local EXISTING_ACCESS
  EXISTING_ACCESS=$(echo "$EXISTING_CLOUD" | grep "aws_access_key_id=" | cut -d= -f2 || true)

  if [ -n "$EXISTING_ACCESS" ] && $GR key info "$EXISTING_ACCESS" >/dev/null 2>&1; then
    echo "Key '$KEY_NAME' ($EXISTING_ACCESS) already exists and K8s secret is valid."
    return 0
  fi

  # Delete existing key if any (to recreate with known secret)
  if $GR key info "$KEY_NAME" >/dev/null 2>&1; then
    echo "Deleting stale key '$KEY_NAME'..."
    local OLD_KEY_ID
    OLD_KEY_ID=$($GR key info "$KEY_NAME" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep "Key ID:" | awk '{print $NF}')
    # Revoke bucket permissions first
    $GR bucket deny --read --write --owner "$BUCKET" --key "$KEY_NAME" 2>&1 | grep -v INFO || true
    garage_api DELETE "key?id=$OLD_KEY_ID" || true
  fi

  # Create new key via admin API (returns the secret)
  echo "Creating key '$KEY_NAME'..."
  local CREATE_JSON
  CREATE_JSON=$(garage_api POST "key" "{\"name\":\"$KEY_NAME\"}")
  ACCESS_KEY=$(echo "$CREATE_JSON" | tr -d '\n\r ' | sed -n 's/.*"accessKeyId":"\([^"]*\)".*/\1/p')
  SECRET_KEY=$(echo "$CREATE_JSON" | tr -d '\n\r ' | sed -n 's/.*"secretAccessKey":"\([^"]*\)".*/\1/p')

  if [ -z "$ACCESS_KEY" ] || [ -z "$SECRET_KEY" ]; then
    echo "ERROR: Failed to create key '$KEY_NAME'" >&2
    echo "API response: $CREATE_JSON" >&2
    exit 1
  fi

  # Grant permissions
  $GR bucket allow --read --write --owner "$BUCKET" --key "$KEY_NAME" 2>&1 | grep -v INFO || true

  # Create K8s secret
  $KC apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $SECRET_NAME
  namespace: $SECRET_NS
type: Opaque
stringData:
  cloud: |
    [default]
    aws_access_key_id=${ACCESS_KEY}
    aws_secret_access_key=${SECRET_KEY}
EOF

  echo "  Key created: $ACCESS_KEY"
}

ensure_key "velero-key" "velero-backups" "storage" "velero-s3-credentials"

echo "Garage setup complete."
