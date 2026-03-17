# ─── Tokens ──────────────────────────────────────────────────────────
# Created via vault provider (authenticated by userpass from self-init)

resource "vault_token" "vault_backend" {
  policies  = ["vault-backend"]
  no_parent = true
  period    = "768h"
}

resource "vault_token" "cluster_secrets" {
  policies  = ["cluster-secrets-ro"]
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

resource "local_file" "cluster_secrets_token" {
  content  = vault_token.cluster_secrets.client_token
  filename = "${var.output_dir}/cluster-secrets-token.txt"
}

resource "local_file" "transit_token" {
  content  = vault_token.autounseal.client_token
  filename = "${var.output_dir}/transit-token.txt"
}

# ─── Cluster secrets ─────────────────────────────────────────────────

resource "random_password" "identity" {
  for_each = toset(["hydra_system_secret", "pomerium_client_secret", "oidc_client_secret"])
  length   = 64
  special  = false
}

resource "random_bytes" "identity_b64" {
  for_each = toset(["pomerium_shared_secret", "pomerium_cookie_secret"])
  length   = 32
}

resource "random_password" "storage" {
  for_each = toset(["garage_rpc_secret", "garage_admin_token"])
  length   = 64
  special  = false
}

resource "random_password" "harbor_admin" {
  length  = 24
  special = false
}

resource "vault_kv_secret_v2" "identity" {
  mount = "secret"
  name  = "cluster/identity"
  data_json = jsonencode({
    hydra_system_secret    = random_password.identity["hydra_system_secret"].result
    pomerium_shared_secret = random_bytes.identity_b64["pomerium_shared_secret"].base64
    pomerium_cookie_secret = random_bytes.identity_b64["pomerium_cookie_secret"].base64
    pomerium_client_secret = random_password.identity["pomerium_client_secret"].result
    oidc_client_secret     = random_password.identity["oidc_client_secret"].result
  })
}

resource "vault_kv_secret_v2" "storage" {
  mount = "secret"
  name  = "cluster/storage"
  data_json = jsonencode({
    garage_rpc_secret     = random_password.storage["garage_rpc_secret"].result
    garage_admin_token    = random_password.storage["garage_admin_token"].result
    harbor_admin_password = random_password.harbor_admin.result
  })
}

