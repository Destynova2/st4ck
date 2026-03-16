#!/bin/sh
# CI setup sidecar — Gitea + Woodpecker bootstrap.
# KMS + secrets are handled by Terraform (bootstrap/kms/).
set -e

GITEA="http://platform-gitea:3000"
WP="http://platform-woodpecker-server:8001"
OUT="/kms-output"
API="-H Content-Type:application/json"

[ -f /shared/done ] && exec sleep infinity

# Minimal JSON value extractor (handles simple flat objects)
json_val() { sed -n "s/.*\"$1\":\s*\"\\([^\"]*\\)\".*/\\1/p" | head -1; }

log() { echo "[setup] $*"; }

# ─── Wait for dependencies ───────────────────────────────────────────
log "Waiting for KMS bootstrap..."
until [ -f "$OUT/vault-backend-token.txt" ]; do sleep 2; done
log "KMS tokens found"

# Gitea install wizard (creates DB + admin, first boot only)
log "Waiting for Gitea..."
until curl -so /dev/null -w '%{http_code}' "$GITEA/" 2>/dev/null | grep -q 200; do sleep 2; done
log "Installing Gitea..."
curl -sf -X POST "$GITEA/" \
  -d "db_type=sqlite3&db_path=/var/lib/gitea/data/gitea.db" \
  -d "app_name=Gitea&repo_root_path=/var/lib/gitea/git/repositories" \
  -d "lfs_root_path=/var/lib/gitea/data/lfs&run_user=git" \
  -d "domain=localhost&ssh_port=2222&http_port=3000" \
  -d "app_url=$CI_GITEA_URL/&log_root_path=/var/lib/gitea/data/log" \
  -d "admin_name=$CI_ADMIN&admin_passwd=$CI_PASSWORD" \
  -d "admin_confirm_passwd=$CI_PASSWORD&admin_email=admin@ci.local" \
  -d "password_algorithm=pbkdf2" -o /dev/null 2>/dev/null || true
log "Waiting for Gitea API..."
until curl -sf "$GITEA/api/v1/user" -u "$CI_ADMIN:$CI_PASSWORD" >/dev/null 2>&1; do sleep 2; done

# ─── Gitea: OAuth app for Woodpecker ────────────────────────────────
log "Registering OAuth app"
# Clean existing OAuth apps
for oid in $(curl -sf "$GITEA/api/v1/user/applications/oauth2" \
  -u "$CI_ADMIN:$CI_PASSWORD" 2>/dev/null | grep -o '"id":[0-9]*' | cut -d: -f2 || true); do
  curl -sf -X DELETE "$GITEA/api/v1/user/applications/oauth2/$oid" \
    -u "$CI_ADMIN:$CI_PASSWORD" || true
done

OAUTH=$(curl -sf -X POST "$GITEA/api/v1/user/applications/oauth2" \
  -u "$CI_ADMIN:$CI_PASSWORD" -H "Content-Type: application/json" \
  -d "{\"name\":\"woodpecker\",\"confidential_client\":true,\"redirect_uris\":[\"$CI_WP_HOST/authorize\"]}")

cat > /shared/creds.env <<EOF
export WOODPECKER_GITEA_CLIENT=$(echo "$OAUTH" | json_val client_id)
export WOODPECKER_GITEA_SECRET=$(echo "$OAUTH" | json_val client_secret)
EOF

# ─── Wait for Woodpecker ────────────────────────────────────────────
log "Waiting for Woodpecker..."
until curl -sf "$WP/healthz" >/dev/null 2>&1; do sleep 2; done
sleep 2

# ─── OAuth dance → WP API token ─────────────────────────────────────
log "OAuth dance for WP token"

# 1. Login to Gitea
CSRF=$(curl -sc /tmp/gc "$GITEA/user/login" | grep '_csrf' | grep -o 'value="[^"]*"' | head -1 | cut -d'"' -f2)
curl -sb /tmp/gc -c /tmp/gc -L "$GITEA/user/login" \
  --data-urlencode "_csrf=$CSRF" -d "user_name=$CI_ADMIN&password=$CI_PASSWORD" -o /dev/null

# 2. Start WP authorize flow, rewrite external URL to internal
WP_REDIR=$(curl -sfD - "$WP/authorize" -o /dev/null | grep -i '^location:' | sed 's/[Ll]ocation: //' | tr -d '\r\n')
INT_REDIR=$(echo "$WP_REDIR" | sed "s|$CI_OAUTH_URL|$GITEA|")
curl -sb /tmp/gc -c /tmp/gc -D /tmp/ah.txt "$INT_REDIR" -o /tmp/auth.html
AUTH_LOC=$(grep -i '^location:' /tmp/ah.txt 2>/dev/null | head -1 | sed 's/[Ll]ocation: //' | tr -d '\r\n')

# 3. If no redirect, we need to grant authorization
if [ -z "$AUTH_LOC" ]; then
  CSRF2=$(grep '_csrf' /tmp/auth.html | grep -o 'value="[^"]*"' | tail -1 | cut -d'"' -f2)
  CID=$(grep 'client_id' /tmp/auth.html | grep -o 'value="[^"]*"' | cut -d'"' -f2)
  STATE=$(grep 'name="state"' /tmp/auth.html | grep -o 'value="[^"]*"' | cut -d'"' -f2)
  RURI=$(grep 'redirect_uri' /tmp/auth.html | grep -o 'value="[^"]*"' | cut -d'"' -f2)
  AUTH_LOC=$(curl -sb /tmp/gc -c /tmp/gc -D - "$GITEA/login/oauth/grant" \
    --data-urlencode "_csrf=$CSRF2" --data-urlencode "client_id=$CID" \
    --data-urlencode "state=$STATE" --data-urlencode "redirect_uri=$RURI" \
    -d 'scope=&nonce=&granted=true' -o /dev/null \
    | grep -i '^location:' | head -1 | sed 's/[Ll]ocation: //' | tr -d '\r\n')
fi

# 4. Complete callback, extract WP session + CSRF
INT_CB=$(echo "$AUTH_LOC" | sed "s|$CI_WP_HOST|$WP|")
curl -sc /tmp/wc -L "$INT_CB" -o /dev/null
WP_JWT=$(grep user_sess /tmp/wc | awk '{print $NF}')
WP_CSRF=$(curl -s -b "user_sess=$WP_JWT" "$WP/web-config.js" | grep -o 'WOODPECKER_CSRF = "[^"]*"' | cut -d'"' -f2)
WP_TOKEN=$(curl -sf -b /tmp/wc -X POST "$WP/api/user/token" -H "X-CSRF-TOKEN: $WP_CSRF")

# ─── Push code to Gitea ─────────────────────────────────────────────
log "Pushing code"
curl -sf -X POST "$GITEA/api/v1/user/repos" \
  -u "$CI_ADMIN:$CI_PASSWORD" -H "Content-Type: application/json" \
  -d '{"name":"talos","private":false}' >/dev/null || true

cd /tmp
if [ -d /source/.git ]; then
  git clone /source talos-push 2>/dev/null
else
  git clone "$CI_GIT_REPO_URL" talos-push 2>/dev/null
fi
cd talos-push
git remote add gitea "http://$CI_ADMIN:$CI_PASSWORD@platform-gitea:3000/$CI_ADMIN/talos.git" 2>/dev/null || true
git push gitea main --force 2>&1 | tail -2

# ─── Activate repo in Woodpecker + fix webhook URL ──────────────────
log "Activating repo in Woodpecker"
curl -sf -X POST "$WP/api/repos?forge_remote_id=1" \
  -H "Authorization: Bearer $WP_TOKEN" || true
sleep 1

# Patch webhook to use internal DNS (not external URL)
HOOKS=$(curl -sf "$GITEA/api/v1/repos/$CI_ADMIN/talos/hooks" -u "$CI_ADMIN:$CI_PASSWORD")
HOOK_ID=$(echo "$HOOKS" | grep -o '"id":[0-9]*' | tail -1 | cut -d: -f2)
HOOK_URL=$(echo "$HOOKS" | grep -o '"url":"[^"]*"' | tail -1 | cut -d'"' -f4)
HOOK_TOKEN=$(echo "$HOOK_URL" | sed 's/.*access_token=//')

if [ -n "$HOOK_ID" ] && [ -n "$HOOK_TOKEN" ]; then
  curl -sf -X PATCH "$GITEA/api/v1/repos/$CI_ADMIN/talos/hooks/$HOOK_ID" \
    -u "$CI_ADMIN:$CI_PASSWORD" -H "Content-Type: application/json" \
    -d "{\"config\":{\"url\":\"http://platform-woodpecker-server:8001/api/hook?access_token=$HOOK_TOKEN\",\"content_type\":\"json\"}}" >/dev/null
  log "Webhook patched"
else
  log "WARNING: Could not patch webhook (hook_id=$HOOK_ID)"
fi

# ─── Woodpecker secrets ─────────────────────────────────────────────
log "Creating WP secrets"
VB_TOKEN=$(cat "$OUT/vault-backend-token.txt" 2>/dev/null || echo "")
CS_TOKEN=$(cat "$OUT/cluster-secrets-token.txt" 2>/dev/null || echo "")

create_secret() {
  curl -sf -X POST "$WP/api/repos/1/secrets" \
    -H "Authorization: Bearer $WP_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$1\",\"value\":\"$2\",\"events\":[\"push\"]}" >/dev/null \
    && echo "  $1" || echo "  $1 (FAILED)"
}

create_secret scw_project_id         "$CI_SCW_PROJECT_ID"
create_secret scw_image_access_key   "$CI_SCW_IMAGE_ACCESS_KEY"
create_secret scw_image_secret_key   "$CI_SCW_IMAGE_SECRET_KEY"
create_secret scw_cluster_access_key "$CI_SCW_CLUSTER_ACCESS_KEY"
create_secret scw_cluster_secret_key "$CI_SCW_CLUSTER_SECRET_KEY"
create_secret tf_http_password       "$VB_TOKEN"
create_secret vault_token            "$CS_TOKEN"

touch /shared/done
log "=== Platform ready ==="
exec sleep infinity
