# ─── AppRole for vault-backend ────────────────────────────────────────
# Role created by self-init, we just fetch the IDs

data "vault_approle_auth_backend_role_id" "vault_backend" {
  backend   = "approle"
  role_name = "vault-backend"
}

resource "vault_approle_auth_backend_role_secret_id" "vault_backend" {
  backend   = "approle"
  role_name = "vault-backend"
}

resource "local_file" "approle_role_id" {
  content  = data.vault_approle_auth_backend_role_id.vault_backend.role_id
  filename = "${var.output_dir}/approle-role-id.txt"
}

resource "local_file" "approle_secret_id" {
  content  = vault_approle_auth_backend_role_secret_id.vault_backend.secret_id
  filename = "${var.output_dir}/approle-secret-id.txt"
}

# ─── Tokens ──────────────────────────────────────────────────────────
# Created via vault provider (authenticated by userpass from self-init)

resource "vault_token" "vault_backend" {
  policies  = ["vault-backend"]
  no_parent = true
  period    = "768h"
}


resource "vault_token" "autounseal" {
  policies  = ["autounseal"]
  no_parent = true
  period    = "768h"
}

# Write tokens to files (for vault-backend + WP secrets)
resource "local_file" "vault_backend_token" {
  content  = vault_token.vault_backend.client_token
  filename = "${var.output_dir}/vault-backend-token.txt"
}


resource "local_file" "transit_token" {
  content  = vault_token.autounseal.client_token
  filename = "${var.output_dir}/transit-token.txt"
}


