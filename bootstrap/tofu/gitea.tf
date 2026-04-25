# ─── Wait for Gitea + register first user (auto-admin, no wizard) ────
# INSTALL_LOCK=true in platform-pod.yaml skips the install wizard entirely,
# so Gitea boots directly into normal mode without the shutdown/restart
# that caused "address already in use" on :3000.
#
# The first registered user via /user/sign_up automatically becomes admin
# (Gitea checks HasOnlyOneUser and sets IsAdmin=true).
# This POST does NOT trigger a server restart — it's a normal signup.

resource "terraform_data" "gitea_install" {
  # The Gitea CSRF signup form is brittle from inside the sidecar (wget can't
  # preserve the session cookie tied to the CSRF token). Instead, the host-side
  # setup.sh (envs/scaleway/ci/setup.sh.tpl) creates the admin via:
  #   podman exec -u git platform-gitea gitea admin user create ...
  # before the sidecar reaches this resource. We just wait for the user to
  # exist via the public API, then proceed.
  provisioner "local-exec" {
    command = <<-SH
      set -eu
      GITEA="${var.gitea_internal_url}"
      USER="${var.ci_admin}"

      echo "[gitea] Waiting for API..."
      for i in $(seq 1 60); do
        wget -qO /dev/null "$GITEA/api/v1/version" 2>/dev/null && break
        sleep 2
      done

      echo "[gitea] Waiting for admin user '$USER' (created host-side via podman exec)..."
      for i in $(seq 1 60); do
        if wget -qO /tmp/user.json "$GITEA/api/v1/users/$USER" 2>/dev/null \
           && grep -q "\"login\"" /tmp/user.json; then
          echo "[gitea] User '$USER' exists — proceeding"
          exit 0
        fi
        sleep 2
      done

      echo "[gitea] ERROR: admin user '$USER' was not created within 120s" >&2
      echo "[gitea] Expected: setup.sh on the VM should run:" >&2
      echo "  podman exec -u git platform-gitea gitea admin user create --username $USER ..." >&2
      exit 1
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
