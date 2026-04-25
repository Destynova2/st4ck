# ─── Wait for Gitea + register first user (auto-admin, no wizard) ────
# INSTALL_LOCK=true in platform-pod.yaml skips the install wizard entirely,
# so Gitea boots directly into normal mode without the shutdown/restart
# that caused "address already in use" on :3000.
#
# The first registered user via /user/sign_up automatically becomes admin
# (Gitea checks HasOnlyOneUser and sets IsAdmin=true).
# This POST does NOT trigger a server restart — it's a normal signup.

resource "terraform_data" "gitea_install" {
  provisioner "local-exec" {
    command = <<-SH
      set -eu
      GITEA="${var.gitea_internal_url}"
      USER="${var.ci_admin}"
      PASS="${var.ci_password}"

      echo "[gitea] Waiting for API..."
      for i in $(seq 1 60); do
        wget -qO /dev/null "$GITEA/api/v1/version" 2>/dev/null && break
        sleep 2
      done

      # ─── Idempotent: skip signup if user already exists ────────────────
      if wget -qO /tmp/user.json "$GITEA/api/v1/users/$USER" 2>/dev/null \
         && grep -q "\"login\"" /tmp/user.json; then
        echo "[gitea] User '$USER' already exists — skipping signup"
        exit 0
      fi

      # ─── Get CSRF token from the signup form ───────────────────────────
      wget -qO /tmp/signup.html "$GITEA/user/sign_up" 2>/dev/null || {
        echo "[gitea] ERROR: wget failed to fetch /user/sign_up" >&2
        exit 1
      }
      CSRF=$(grep '_csrf' /tmp/signup.html | grep -o 'value="[^"]*"' | head -1 | cut -d'"' -f2 || true)

      if [ -z "$CSRF" ]; then
        echo "[gitea] ERROR: failed to extract _csrf token from signup page" >&2
        echo "[gitea] First 30 lines of /user/sign_up response:" >&2
        head -30 /tmp/signup.html >&2 || true
        echo "[gitea] FALLBACK: trying admin user create via Gitea CLI on disk..." >&2
        # Last-resort: write a one-shot user-create script the gitea container
        # will pick up on next exec. Caller (setup.sh.tpl) must podman-exec.
        echo "$USER:$PASS:admin@ci.local" > /shared/gitea-pending-user
        exit 1
      fi

      # ─── POST signup ───────────────────────────────────────────────────
      wget -qO /tmp/signup-result.html \
        --post-data="_csrf=$CSRF&user_name=$USER&email=admin@ci.local&password=$PASS&retype=$PASS" \
        "$GITEA/user/sign_up" 2>/dev/null || {
        echo "[gitea] ERROR: signup POST failed" >&2
        exit 1
      }

      # ─── Verify user actually got created ──────────────────────────────
      sleep 2
      if ! wget -qO /tmp/user-verify.json "$GITEA/api/v1/users/$USER" 2>/dev/null \
         || ! grep -q "\"login\"" /tmp/user-verify.json; then
        echo "[gitea] ERROR: signup POST returned 200 but user '$USER' not in API" >&2
        echo "[gitea] First 30 lines of signup result:" >&2
        head -30 /tmp/signup-result.html >&2 || true
        exit 1
      fi
      echo "[gitea] User '$USER' created and verified"
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
  content  = gitea_oauth2_app.woodpecker.client_id
  filename = "/shared/gitea-client"
}

resource "local_file" "gitea_secret" {
  content  = gitea_oauth2_app.woodpecker.client_secret
  filename = "/shared/gitea-secret"
}

# ─── Repository ──────────────────────────────────────────────────────

resource "gitea_repository" "talos" {
  username = var.ci_admin
  name     = "talos"
  private  = false

  depends_on = [terraform_data.gitea_install]
}

resource "terraform_data" "git_push" {
  depends_on = [gitea_repository.talos]

  provisioner "local-exec" {
    command = <<-SH
      cd /tmp
      if [ -d /source/.git ]; then
        git clone /source talos-push 2>/dev/null || true
      else
        git clone "${var.git_repo_url}" talos-push 2>/dev/null || true
      fi
      cd talos-push
      git remote add gitea "http://platform-gitea:3000/${var.ci_admin}/talos.git" 2>/dev/null || true
      git -c credential.helper='!f() { echo "username=${var.ci_admin}"; echo "password=${var.ci_password}"; }; f' \
        push gitea main --force 2>&1 | tail -2
    SH
  }
}
