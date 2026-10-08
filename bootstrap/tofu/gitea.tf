# ─── Wait for Gitea + register first user (auto-admin, no wizard) ────
# INSTALL_LOCK=true in platform-pod.yaml skips the install wizard entirely,
# so Gitea boots directly into normal mode without the shutdown/restart
# that caused "address already in use" on :3000.
#
# The host creates the admin via the Gitea CLI; the sidecar waits for it.

resource "terraform_data" "gitea_install" {
  # The Gitea CSRF signup form is brittle from inside the sidecar (wget can't
  # preserve the session cookie tied to the CSRF token). Instead, the host-side
  # local provisioner or envs/scaleway/ci/launch.sh creates the admin via:
  #   podman exec -u git platform-gitea gitea admin user create ...
  # before the sidecar reaches this resource. We just wait for the user to
  # exist via the public API, then proceed.
  provisioner "local-exec" {
    command = <<-SH
      set -eu
      GITEA="${var.gitea_internal_url}"
      USER="${var.ci_admin}"

      # ─── Wait for Gitea API (Pattern 1: 1s polling + explicit timeout) ──
      # Phase F-bis: 60×sleep 2 (max 120s) → 300×sleep 1 (max 300s) with
      # ~typical detect 2s vs old 4s. HTTP roundtrip on /api/v1/version is
      # cheap enough to poll every second without flooding the server.
      echo "[gitea] Waiting for API..."
      ready=0
      for i in $(seq 1 300); do
        if wget -qO /dev/null "$GITEA/api/v1/version" 2>/dev/null; then
          echo "[gitea] API ready after $${i}s"
          ready=1
          break
        fi
        sleep 1
      done
      if [ "$ready" -ne 1 ]; then
        echo "[gitea] ERROR: API not reachable after 300s at $GITEA" >&2
        exit 1
      fi

      # ─── Wait for admin user (Pattern 1) ──────────────────────────────
      # User is created host-side via `podman exec ... gitea admin user create`
      # Poll the public users API until present.
      echo "[gitea] Waiting for admin user '$USER' (created host-side via podman exec)..."
      found=0
      for i in $(seq 1 300); do
        if wget -qO /tmp/user.json "$GITEA/api/v1/users/$USER" 2>/dev/null \
           && grep -q '"login"' /tmp/user.json; then
          echo "[gitea] User '$USER' exists — proceeding (after $${i}s)"
          found=1
          break
        fi
        sleep 1
      done
      if [ "$found" -ne 1 ]; then
        echo "[gitea] ERROR: admin user '$USER' was not created within 300s" >&2
        echo "[gitea] Expected: the host bootstrap launcher should run:" >&2
        echo "  podman exec -u git platform-gitea gitea admin user create --username $USER ..." >&2
        exit 1
      fi
    SH
  }
}

# ─── OAuth app for Woodpecker ────────────────────────────────────────

resource "gitea_oauth2_app" "woodpecker" {
  name                = "woodpecker"
  confidential_client = true
  redirect_uris       = ["${var.wp_external_url}/authorize"]

  depends_on = [terraform_data.gitea_install]
}

# Write OAuth creds to shared volume (WP reads via _FILE env vars)
resource "local_file" "gitea_client" {
  content              = gitea_oauth2_app.woodpecker.client_id
  filename             = "/shared/gitea-client"
  file_permission      = "0600"
  directory_permission = "0700"
}

resource "local_file" "gitea_secret" {
  content              = gitea_oauth2_app.woodpecker.client_secret
  filename             = "/shared/gitea-secret"
  file_permission      = "0600"
  directory_permission = "0700"
}

# ─── Repository ──────────────────────────────────────────────────────

resource "gitea_repository" "talos" {
  username = var.ci_admin
  name     = "talos"
  private  = false
  # The source HEAD is the first commit; a generated README would diverge.
  auto_init = false

  depends_on = [terraform_data.gitea_install]
}

resource "terraform_data" "git_push" {
  depends_on = [gitea_repository.talos]

  provisioner "local-exec" {
    environment = {
      GITEA_ADMIN    = var.ci_admin
      GITEA_PASSWORD = var.ci_password
      GITEA_PUSH_URL = "${var.gitea_internal_url}/${var.ci_admin}/talos.git"
      GIT_SOURCE_URL = var.git_repo_url
    }
    command = <<-SH
      set -eu
      umask 077
      work=$(mktemp -d /tmp/gitea-push.XXXXXX)
      trap 'rm -rf -- "$work"' EXIT
      trap 'exit 1' HUP INT TERM
      export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
      if [ -e /source/.git ]; then
        git -c safe.directory=/source clone --no-local -- /source "$work/repo"
      else
        git clone -- "$GIT_SOURCE_URL" "$work/repo"
      fi
      cd "$work/repo"
      git remote add gitea "$GITEA_PUSH_URL"
      # An environment-only HTTP header also supports newline passwords,
      # which the line-oriented Git credential-helper protocol cannot carry.
      basic=$(printf '%s:%s' "$GITEA_ADMIN" "$GITEA_PASSWORD" | base64)
      basic=$(printf '%s' "$basic" | tr -d '\r\n')
      export GIT_CONFIG_COUNT=2
      export GIT_CONFIG_KEY_0="http.$GITEA_PUSH_URL.extraHeader"
      export GIT_CONFIG_VALUE_0="Authorization: Basic $basic"
      export GIT_CONFIG_KEY_1=http.followRedirects GIT_CONFIG_VALUE_1=false
      git push gitea HEAD:refs/heads/main
    SH
  }
}
