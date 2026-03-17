# ─── OAuth dance to get WP API token ─────────────────────────────────
# This is the only truly imperative part — WP v3 has no CLI token create
# without browser OAuth. We do the dance with wget/curl.

resource "terraform_data" "wp_setup" {
  depends_on = [
    gitea_oauth2_app.woodpecker,
    terraform_data.git_push,
    local_file.gitea_client,
    local_file.gitea_secret,
  ]

  provisioner "local-exec" {
    command = <<-SH
      GITEA="${var.gitea_internal_url}"
      WP="${var.wp_internal_url}"
      WP_EXT="${var.wp_external_url}"
      OAUTH_EXT="${var.gitea_external_url}"
      ADMIN="${var.ci_admin}"
      PASS="${var.ci_password}"

      echo "Waiting for Woodpecker..."
      for i in $(seq 1 60); do
        wget -qO /dev/null "$WP/healthz" 2>/dev/null && break
        sleep 2
      done

      # Login to Gitea
      wget -qO /tmp/login.html --save-cookies /tmp/gc "$GITEA/user/login" 2>/dev/null
      CSRF=$(grep '_csrf' /tmp/login.html | grep -o 'value="[^"]*"' | head -1 | cut -d'"' -f2)
      wget -qO /dev/null --load-cookies /tmp/gc --save-cookies /tmp/gc \
        --post-data="_csrf=$CSRF&user_name=$ADMIN&password=$PASS" \
        "$GITEA/user/login" 2>/dev/null || true

      # Start WP authorize flow
      WP_REDIR=$(wget -qS "$WP/authorize" 2>&1 | grep -i 'location:' | head -1 | sed 's/.*ocation: //' | tr -d '\r\n')
      INT_REDIR=$(echo "$WP_REDIR" | sed "s|$OAUTH_EXT|$GITEA|")
      wget -qO /tmp/auth.html --load-cookies /tmp/gc --save-cookies /tmp/gc \
        -S "$INT_REDIR" 2>/tmp/auth_headers.txt || true
      AUTH_LOC=$(grep -i 'location:' /tmp/auth_headers.txt | head -1 | sed 's/.*ocation: //' | tr -d '\r\n')

      # Grant authorization if needed
      if [ -z "$AUTH_LOC" ]; then
        CSRF2=$(grep '_csrf' /tmp/auth.html | grep -o 'value="[^"]*"' | tail -1 | cut -d'"' -f2)
        CID=$(grep 'client_id' /tmp/auth.html | grep -o 'value="[^"]*"' | cut -d'"' -f2)
        STATE=$(grep 'name="state"' /tmp/auth.html | grep -o 'value="[^"]*"' | cut -d'"' -f2)
        RURI=$(grep 'redirect_uri' /tmp/auth.html | grep -o 'value="[^"]*"' | cut -d'"' -f2)
        AUTH_LOC=$(wget -qO /dev/null --load-cookies /tmp/gc --save-cookies /tmp/gc \
          -S --post-data="_csrf=$CSRF2&client_id=$CID&state=$STATE&redirect_uri=$RURI&scope=&nonce=&granted=true" \
          "$GITEA/login/oauth/grant" 2>&1 | grep -i 'location:' | head -1 | sed 's/.*ocation: //' | tr -d '\r\n')
      fi

      # Complete callback
      INT_CB=$(echo "$AUTH_LOC" | sed "s|$WP_EXT|$WP|")
      wget -qO /dev/null --save-cookies /tmp/wc -S "$INT_CB" 2>/dev/null || true
      WP_JWT=$(grep user_sess /tmp/wc | awk '{print $NF}')
      WP_CSRF=$(wget -qO- --header="Cookie: user_sess=$WP_JWT" "$WP/web-config.js" 2>/dev/null \
        | grep -o 'WOODPECKER_CSRF = "[^"]*"' | cut -d'"' -f2)
      WP_TOKEN=$(wget -qO- --header="Cookie: user_sess=$WP_JWT" \
        --header="X-CSRF-TOKEN: $WP_CSRF" \
        --post-data="" "$WP/api/user/token" 2>/dev/null)

      if [ -z "$WP_TOKEN" ]; then
        echo "WARNING: Could not get WP token, skipping repo activation"
        exit 0
      fi

      # Activate repo
      wget -qO /dev/null --header="Authorization: Bearer $WP_TOKEN" \
        --post-data="" "$WP/api/repos?forge_remote_id=1" 2>/dev/null || true
      sleep 1

      # Patch webhook to internal URL
      HOOKS=$(wget -qO- --header="Authorization: Basic $(printf '%s:%s' $ADMIN $PASS | base64)" \
        "$GITEA/api/v1/repos/$ADMIN/talos/hooks" 2>/dev/null)
      HOOK_ID=$(echo "$HOOKS" | grep -o '"id":[0-9]*' | tail -1 | cut -d: -f2)
      HOOK_URL=$(echo "$HOOKS" | grep -o '"url":"[^"]*"' | tail -1 | cut -d'"' -f4)
      HOOK_TOKEN=$(echo "$HOOK_URL" | sed 's/.*access_token=//')

      if [ -n "$HOOK_ID" ] && [ -n "$HOOK_TOKEN" ]; then
        wget -qO /dev/null --header="Authorization: Basic $(printf '%s:%s' $ADMIN $PASS | base64)" \
          --header="Content-Type: application/json" \
          --post-data="{\"config\":{\"url\":\"$WP/api/hook?access_token=$HOOK_TOKEN\",\"content_type\":\"json\"}}" \
          "$GITEA/api/v1/repos/$ADMIN/talos/hooks/$HOOK_ID" 2>/dev/null || true
        echo "Webhook patched"
      fi

      # Create WP secrets
      VB_TOKEN=$(cat /kms-output/vault-backend-token.txt 2>/dev/null)
      CS_TOKEN=$(cat /kms-output/cluster-secrets-token.txt 2>/dev/null)
      for pair in \
        "scw_project_id:${var.scw_project_id}" \
        "scw_image_access_key:${var.scw_image_access_key}" \
        "scw_image_secret_key:${var.scw_image_secret_key}" \
        "scw_cluster_access_key:${var.scw_cluster_access_key}" \
        "scw_cluster_secret_key:${var.scw_cluster_secret_key}" \
        "tf_http_password:$VB_TOKEN" \
        "vault_token:$CS_TOKEN"; do
        key="$${pair%%:*}"
        value="$${pair#*:}"
        wget -qO /dev/null --header="Authorization: Bearer $WP_TOKEN" \
          --header="Content-Type: application/json" \
          --post-data="{\"name\":\"$key\",\"value\":\"$value\",\"events\":[\"push\"]}" \
          "$WP/api/repos/1/secrets" 2>/dev/null && echo "  $key" || true
      done

      echo "=== Woodpecker setup complete ==="
    SH
  }
}
