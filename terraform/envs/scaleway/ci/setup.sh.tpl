#!/bin/bash
set -euo pipefail

GITEA_URL="http://${public_ip}:3000"
WOODPECKER_HOST="http://${public_ip}:8000"
GITEA_ADMIN="${gitea_admin_user}"
GITEA_PASSWORD="${gitea_admin_password}"
AGENT_SECRET=$(openssl rand -hex 32)
BAO_ADDR="http://127.0.0.1:8200"
BAO_TOKEN=$(cat /opt/talos/kms-output/root-token.txt)
SECRETS_DIR="/opt/talos/kms-output"

# ─── Store CI secrets in OpenBao KV v2 ──────────────────────────────
echo "=== Storing CI secrets in OpenBao KV ==="
curl -sf -X POST "$BAO_ADDR/v1/secret/data/ci" \
  -H "X-Vault-Token: $BAO_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"data\": {
      \"scw_project_id\": \"${scw_project_id}\",
      \"scw_image_access_key\": \"${scw_image_access_key}\",
      \"scw_image_secret_key\": \"${scw_image_secret_key}\",
      \"scw_cluster_access_key\": \"${scw_cluster_access_key}\",
      \"scw_cluster_secret_key\": \"${scw_cluster_secret_key}\"
    }
  }"

# Helper scripts sourced by pipeline steps (path inside containers)
S="/woodpecker/src/kms-output"

cat > "$SECRETS_DIR/load-cluster-env.sh" << 'ENVEOF'
#!/bin/sh
BAO_ADDR="http://127.0.0.1:8200"
BAO_TOKEN=$(cat /woodpecker/src/kms-output/root-token.txt)
CI=$(curl -sf "$BAO_ADDR/v1/secret/data/ci" -H "X-Vault-Token: $BAO_TOKEN")
export SCW_PROJECT_ID=$(echo "$CI" | jq -r '.data.data.scw_project_id')
export SCW_ACCESS_KEY=$(echo "$CI" | jq -r '.data.data.scw_cluster_access_key')
export SCW_SECRET_KEY=$(echo "$CI" | jq -r '.data.data.scw_cluster_secret_key')
export TF_HTTP_PASSWORD=$(cat /woodpecker/src/kms-output/vault-backend-token.txt)
ENVEOF

cat > "$SECRETS_DIR/load-image-env.sh" << 'ENVEOF'
#!/bin/sh
BAO_ADDR="http://127.0.0.1:8200"
BAO_TOKEN=$(cat /woodpecker/src/kms-output/root-token.txt)
CI=$(curl -sf "$BAO_ADDR/v1/secret/data/ci" -H "X-Vault-Token: $BAO_TOKEN")
export SCW_PROJECT_ID=$(echo "$CI" | jq -r '.data.data.scw_project_id')
export SCW_ACCESS_KEY=$(echo "$CI" | jq -r '.data.data.scw_image_access_key')
export SCW_SECRET_KEY=$(echo "$CI" | jq -r '.data.data.scw_image_secret_key')
ENVEOF

chmod +x "$SECRETS_DIR/load-cluster-env.sh" "$SECRETS_DIR/load-image-env.sh"

# ─── Wait for Gitea ─────────────────────────────────────────────────
echo "=== Waiting for Gitea ==="
for i in $(seq 1 120); do
  curl -sf "$GITEA_URL/api/v1/version" >/dev/null && break
  sleep 3
done

# ─── Create Gitea admin user ────────────────────────────────────────
echo "=== Creating Gitea admin user ==="
podman exec --user git ci-gitea gitea admin user create \
  --admin --username "$GITEA_ADMIN" \
  --password "$GITEA_PASSWORD" \
  --email "${gitea_admin_email}" \
  --must-change-password=false || true

# ─── Create confidential OAuth app for Woodpecker ───────────────────
echo "=== Creating OAuth app for Woodpecker ==="
OAUTH_RESPONSE=$(curl -sf -X POST "$GITEA_URL/api/v1/user/applications/oauth2" \
  -u "$GITEA_ADMIN:$GITEA_PASSWORD" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"woodpecker\",
    \"confidential_client\": true,
    \"redirect_uris\": [\"$WOODPECKER_HOST/authorize\"]
  }")

CLIENT_ID=$(echo "$OAUTH_RESPONSE" | jq -r '.client_id')
CLIENT_SECRET=$(echo "$OAUTH_RESPONSE" | jq -r '.client_secret')

# ─── Restart CI pod with real env vars ───────────────────────────────
echo "=== Restarting CI pod with real env vars ==="
podman play kube --down /opt/woodpecker/ci-pod.yaml

sed -i \
  -e "s|PLACEHOLDER_GITEA_URL|$GITEA_URL|g" \
  -e "s|PLACEHOLDER_DOMAIN|${public_ip}|g" \
  -e "s|PLACEHOLDER_WP_HOST|$WOODPECKER_HOST|g" \
  -e "s|PLACEHOLDER_ADMIN|$GITEA_ADMIN|g" \
  -e "s|PLACEHOLDER_CLIENT|$CLIENT_ID|g" \
  -e "s|PLACEHOLDER_SECRET|$CLIENT_SECRET|g" \
  -e "s|PLACEHOLDER_AGENT_SECRET|$AGENT_SECRET|g" \
  /opt/woodpecker/ci-pod.yaml

podman play kube /opt/woodpecker/ci-pod.yaml

# ─── Wait for both services ─────────────────────────────────────────
echo "=== Waiting for Gitea + Woodpecker ==="
for i in $(seq 1 120); do
  G=$(curl -sf -o /dev/null -w "%{http_code}" "$GITEA_URL/api/v1/version" 2>/dev/null || echo "000")
  W=$(curl -sf -o /dev/null -w "%{http_code}" "$WOODPECKER_HOST/healthz" 2>/dev/null || echo "000")
  [ "$G" = "200" ] && ([ "$W" = "200" ] || [ "$W" = "204" ]) && break
  sleep 3
done

# ─── OAuth dance: activate repo in Woodpecker programmatically ──────
echo "=== Activating repo in Woodpecker ==="
LOCAL_GITEA="http://127.0.0.1:3000"
LOCAL_WP="http://127.0.0.1:8000"
GCJ=$(mktemp)

# Step 1: Login to Gitea (get session cookie)
PAGE=$(curl -s -c "$GCJ" "$LOCAL_GITEA/user/login")
CSRF=$(echo "$PAGE" | grep 'name="_csrf"' | grep -o 'value="[^"]*"' | head -1 | cut -d'"' -f2)
curl -s -b "$GCJ" -c "$GCJ" -L "$LOCAL_GITEA/user/login" \
  -d "_csrf=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$CSRF'))")&user_name=$GITEA_ADMIN&password=$GITEA_PASSWORD" \
  -o /dev/null

# Step 2: Get WP authorize redirect → follow to Gitea authorize
WP_REDIR=$(curl -sf -D - "$LOCAL_WP/authorize" -o /dev/null | grep -i "^location:" | sed 's/[Ll]ocation: //' | tr -d '\r\n')
INTERNAL_REDIR=$(echo "$WP_REDIR" | sed "s|$GITEA_URL|$LOCAL_GITEA|")

# Step 3: Follow to Gitea OAuth page (auto-grants or shows form)
AUTH_RESP=$(curl -s -b "$GCJ" -c "$GCJ" -D /tmp/auth_h.txt "$INTERNAL_REDIR" -o /tmp/auth.html)
AUTH_LOC=$(grep -i "^location:" /tmp/auth_h.txt 2>/dev/null | head -1 | sed 's/[Ll]ocation: //' | tr -d '\r\n')

if [ -z "$AUTH_LOC" ]; then
  # Need to submit grant form
  CSRF2=$(grep 'name="_csrf"' /tmp/auth.html | grep -o 'value="[^"]*"' | tail -1 | cut -d'"' -f2)
  CID=$(grep 'name="client_id"' /tmp/auth.html | grep -o 'value="[^"]*"' | cut -d'"' -f2)
  STATE=$(grep 'name="state"' /tmp/auth.html | grep -o 'value="[^"]*"' | cut -d'"' -f2)
  RURI=$(grep 'name="redirect_uri"' /tmp/auth.html | grep -o 'value="[^"]*"' | cut -d'"' -f2)

  AUTH_LOC=$(curl -s -b "$GCJ" -c "$GCJ" -D - \
    "$LOCAL_GITEA/login/oauth/grant" \
    --data-urlencode "_csrf=$CSRF2" \
    --data-urlencode "client_id=$CID" \
    --data-urlencode "state=$STATE" \
    --data-urlencode "redirect_uri=$RURI" \
    -d "scope=&nonce=&granted=true" \
    -o /dev/null | grep -i "^location:" | head -1 | sed 's/[Ll]ocation: //' | tr -d '\r\n')
fi

# Step 4: Follow callback to Woodpecker (get session)
WCJ=$(mktemp)
INTERNAL_CB=$(echo "$AUTH_LOC" | sed "s|$WOODPECKER_HOST|$LOCAL_WP|")
curl -s -c "$WCJ" -L "$INTERNAL_CB" -o /dev/null

# Step 5: Get CSRF token from web-config.js
WP_JWT=$(grep user_sess "$WCJ" | awk '{print $NF}')
WP_CSRF=$(curl -s -b "user_sess=$WP_JWT" "$LOCAL_WP/web-config.js" | grep -o 'WOODPECKER_CSRF = "[^"]*"' | cut -d'"' -f2)

# Step 6: Get personal API token (needs session cookie + CSRF)
WP_TOKEN=$(curl -sf -b "$WCJ" -X POST "$LOCAL_WP/api/user/token" \
  -H "X-CSRF-TOKEN: $WP_CSRF")
echo "$WP_TOKEN" > "$SECRETS_DIR/woodpecker-token.txt"

# Step 7: Create Gitea repo + push code
echo "=== Creating Gitea repo ==="
curl -sf -X POST "$GITEA_URL/api/v1/user/repos" \
  -u "$GITEA_ADMIN:$GITEA_PASSWORD" \
  -H "Content-Type: application/json" \
  -d '{"name": "talos", "description": "Talos Linux platform", "private": false}' || true

cd /tmp && rm -rf talos.git
git clone --bare "${git_repo_url}" talos.git 2>/dev/null && {
  cd talos.git
  git push --mirror "http://$GITEA_ADMIN:$GITEA_PASSWORD@${public_ip}:3000/$GITEA_ADMIN/talos.git" || true
} || echo "WARNING: Could not clone — push manually from local"

# Step 8: Activate repo in Woodpecker
echo "=== Activating repo ==="
curl -sf -X POST "$LOCAL_WP/api/repos?forge_remote_id=1" \
  -H "Authorization: Bearer $WP_TOKEN" || echo "Repo activation failed"

rm -f "$GCJ" "$WCJ"

# ─── Summary ─────────────────────────────────────────────────────────
echo ""
echo "========================================="
echo "  CI Bootstrap Complete"
echo "========================================="
echo "Gitea:      $GITEA_URL"
echo "Woodpecker: $WOODPECKER_HOST"
echo "User:       $GITEA_ADMIN"
echo "Password:   $GITEA_PASSWORD"
echo ""
echo "Secrets: OpenBao KV at secret/ci"
echo "WP API:  $SECRETS_DIR/woodpecker-token.txt"
echo "========================================="
