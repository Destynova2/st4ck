#!/bin/sh
# CI setup sidecar — Gitea + Woodpecker bootstrap.
# KMS + secrets are handled by Terraform (bootstrap/kms/).
set -e

GITEA="http://platform-gitea:3000"
WP="http://platform-woodpecker-server:8000"
OUT="/kms-output"
API="-H Content-Type:application/json"

[ -f /shared/done ] && exec sleep infinity

# Write agent secret early so WP server + agent can start
printf '%s' "$CI_AGENT_SECRET" > /shared/agent-secret 2>/dev/null || true

# Minimal JSON value extractor (handles simple flat objects)
json_val() { sed -n "s/.*\"$1\":\s*\"\\([^\"]*\\)\".*/\\1/p" | head -1; }

log() { echo "[setup] $*"; }

# ─── Wait for OpenBao (self-init handles everything) ─────────────────
log "Waiting for OpenBao..."
BAO="http://127.0.0.1:8200"
until curl -sf "$BAO/v1/sys/health" >/dev/null 2>&1; do sleep 2; done
log "OpenBao ready"

# Authenticate via userpass (created by self-init)
log "Authenticating to OpenBao..."
BAO_TOKEN=$(curl -sf -X POST "$BAO/v1/auth/userpass/login/bootstrap-admin" \
  -d "{\"password\":\"$CI_PASSWORD\"}" | json_val client_token)

if [ -z "$BAO_TOKEN" ]; then
  log "ERROR: Failed to authenticate to OpenBao"
  exit 1
fi

# Create vault-backend token
VB_TOKEN=$(curl -sf -X POST "$BAO/v1/auth/token/create" \
  -H "X-Vault-Token: $BAO_TOKEN" \
  -d '{"policies":["vault-backend"],"no_parent":true,"period":"768h"}' | json_val client_token)
printf '%s' "$VB_TOKEN" > "$OUT/vault-backend-token.txt"

# Create cluster-secrets read-only token
CS_TOKEN=$(curl -sf -X POST "$BAO/v1/auth/token/create" \
  -H "X-Vault-Token: $BAO_TOKEN" \
  -d '{"policies":["cluster-secrets-ro"],"no_parent":true,"period":"768h"}' | json_val client_token)
printf '%s' "$CS_TOKEN" > "$OUT/cluster-secrets-token.txt"

# Create transit auto-unseal token
TR_TOKEN=$(curl -sf -X POST "$BAO/v1/auth/token/create" \
  -H "X-Vault-Token: $BAO_TOKEN" \
  -d '{"policies":["autounseal"],"no_parent":true,"period":"768h"}' | json_val client_token)
printf '%s' "$TR_TOKEN" > "$OUT/transit-token.txt"

# Generate cluster secrets (identity + storage)
gen_hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }
gen_b64() { head -c "$1" /dev/urandom | base64 | tr -d '\n'; }

if ! curl -sf "$BAO/v1/secret/data/cluster/identity" -H "X-Vault-Token: $BAO_TOKEN" >/dev/null 2>&1; then
  HS=$(gen_hex 32); PS=$(gen_b64 32); PC=$(gen_b64 32); PX=$(gen_hex 32); OC=$(gen_hex 32)
  curl -sf -X POST "$BAO/v1/secret/data/cluster/identity" -H "X-Vault-Token: $BAO_TOKEN" \
    -d "{\"data\":{\"hydra_system_secret\":\"$HS\",\"pomerium_shared_secret\":\"$PS\",\"pomerium_cookie_secret\":\"$PC\",\"pomerium_client_secret\":\"$PX\",\"oidc_client_secret\":\"$OC\"}}" >/dev/null
  log "Identity secrets generated"
fi

if ! curl -sf "$BAO/v1/secret/data/cluster/storage" -H "X-Vault-Token: $BAO_TOKEN" >/dev/null 2>&1; then
  GR=$(gen_hex 32); GA=$(gen_hex 32); HP=$(gen_hex 12)
  curl -sf -X POST "$BAO/v1/secret/data/cluster/storage" -H "X-Vault-Token: $BAO_TOKEN" \
    -d "{\"data\":{\"garage_rpc_secret\":\"$GR\",\"garage_admin_token\":\"$GA\",\"harbor_admin_password\":\"$HP\"}}" >/dev/null
  log "Storage secrets generated"
fi

log "KMS tokens + secrets ready"

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

echo "$OAUTH" | json_val client_id > /shared/gitea-client
echo "$OAUTH" | json_val client_secret > /shared/gitea-secret

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
    -d "{\"config\":{\"url\":\"http://platform-woodpecker-server:8000/api/hook?access_token=$HOOK_TOKEN\",\"content_type\":\"json\"}}" >/dev/null
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
