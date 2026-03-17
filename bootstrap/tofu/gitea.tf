# ─── Wait for Gitea install wizard to be available ───────────────────

resource "terraform_data" "gitea_install" {
  provisioner "local-exec" {
    command = <<-SH
      GITEA="${var.gitea_internal_url}"
      echo "Waiting for Gitea..."
      for i in $(seq 1 60); do
        CODE=$(wget -qO /dev/null -S "$GITEA/" 2>&1 | grep -c 'HTTP/' || echo 0)
        [ "$CODE" -gt 0 ] && break
        sleep 2
      done

      # Install Gitea via wizard (first boot only, idempotent — retry up to 3x)
      for attempt in 1 2 3; do
        wget -qO /dev/null --post-data="db_type=sqlite3&\
db_path=/var/lib/gitea/data/gitea.db&\
app_name=Gitea&\
repo_root_path=/var/lib/gitea/git/repositories&\
lfs_root_path=/var/lib/gitea/data/lfs&\
run_user=git&\
domain=localhost&\
ssh_port=2222&\
http_port=3000&\
app_url=${var.gitea_external_url}/&\
log_root_path=/var/lib/gitea/data/log&\
admin_name=${var.ci_admin}&\
admin_passwd=${var.ci_password}&\
admin_confirm_passwd=${var.ci_password}&\
admin_email=admin@ci.local&\
password_algorithm=pbkdf2" \
          "$GITEA/" 2>/dev/null && break
        echo "  Gitea install attempt $attempt failed, retrying..."
        sleep 3
      done

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
      git remote add gitea "http://${var.ci_admin}:${var.ci_password}@platform-gitea:3000/${var.ci_admin}/talos.git" 2>/dev/null || true
      git push gitea main --force 2>&1 | tail -2
    SH
  }
}
