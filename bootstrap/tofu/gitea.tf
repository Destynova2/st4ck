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
      GITEA="${var.gitea_internal_url}"
      echo "Waiting for Gitea..."
      for i in $(seq 1 60); do
        wget -qO /dev/null "$GITEA/api/v1/version" 2>/dev/null && break
        sleep 2
      done

      # Register first user via signup form (becomes admin automatically)
      # Fetch CSRF token from signup page first
      wget -qO /tmp/signup.html "$GITEA/user/sign_up" 2>/dev/null
      CSRF=$(grep '_csrf' /tmp/signup.html | grep -o 'value="[^"]*"' | head -1 | cut -d'"' -f2)

      # POST signup — idempotent: if user exists, Gitea returns 200 with error in HTML
      wget -qO /dev/null --post-data="_csrf=$CSRF&user_name=${var.ci_admin}&email=admin@ci.local&password=${var.ci_password}&retype=${var.ci_password}" \
        "$GITEA/user/sign_up" 2>/dev/null || true

      echo "Waiting for Gitea API..."
      for i in $(seq 1 30); do
        wget -qO /dev/null "$GITEA/api/v1/version" 2>/dev/null && echo "Gitea ready" && exit 0
        sleep 2
      done
      echo "ERROR: Gitea API not ready" && exit 1
    SH
  }
}

# ─── OAuth app for Woodpecker ────────────────────────────────────────

resource "gitea_oauth2_app" "woodpecker" {
  name                  = "woodpecker"
  confidential_client   = true
  redirect_uris         = ["${var.wp_external_url}/authorize"]

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
