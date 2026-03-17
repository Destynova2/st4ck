terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}

# ─── Wait for OpenBao to be reachable ────────────────────────────────

resource "terraform_data" "wait_for_openbao" {
  provisioner "local-exec" {
    command = <<-SH
      echo "Waiting for OpenBao..."
      for i in $(seq 1 30); do
        wget -qS http://127.0.0.1:8200/v1/sys/health 2>&1 | grep -q 'HTTP/' && echo "OpenBao ready" && exit 0
        sleep 2
      done
      echo "ERROR: OpenBao not reachable" && exit 1
    SH
  }
}

# ─── Init + Unseal ───────────────────────────────────────────────────

resource "terraform_data" "init_unseal" {
  depends_on = [terraform_data.wait_for_openbao]

  provisioner "local-exec" {
    command = <<-SH
      NODE0="http://127.0.0.1:8200"
      OUT="${var.kms_output_dir}"
      mkdir -p "$OUT"

      if [ -f "$OUT/root-token.txt" ] && [ -s "$OUT/root-token.txt" ]; then
        echo "Already initialized (root-token.txt exists)"
        exit 0
      fi

      # Static seal auto-unseal: OpenBao is unsealed but needs operator init
      sleep 2
      INIT=$(wget -qO- --header="Content-Type: application/json" \
        --post-data='{"secret_shares":1,"secret_threshold":1}' \
        "$NODE0/v1/sys/init" 2>/dev/null)
      echo "$INIT" | grep -o '"root_token":"[^"]*"' | cut -d'"' -f4 > "$OUT/root-token.txt"

      if [ ! -s "$OUT/root-token.txt" ]; then
        echo "ERROR: init failed, no root token"
        exit 1
      fi
      echo "OpenBao initialized (static seal auto-unseal)"
    SH
  }
}

# ─── Vault provider (uses root token after init) ─────────────────────
# Two-phase: first `tofu apply -target=terraform_data.init_unseal`,
# then `tofu apply` for the rest. The Makefile handles this.

provider "vault" {
  address         = "http://127.0.0.1:8200"
  skip_tls_verify = true
  # Token set via VAULT_TOKEN env var (exported by kms-init sidecar between phases)
}

# ─── Transit auto-unseal ─────────────────────────────────────────────

resource "vault_mount" "transit" {
  path = "transit"
  type = "transit"

  depends_on = [terraform_data.init_unseal]
}

resource "vault_transit_secret_backend_key" "autounseal" {
  backend = vault_mount.transit.path
  name    = "autounseal"
  type    = "aes256-gcm96"
}

resource "vault_policy" "autounseal" {
  name   = "autounseal"
  policy = <<-EOT
    path "transit/encrypt/autounseal" { capabilities = ["update"] }
    path "transit/decrypt/autounseal" { capabilities = ["update"] }
  EOT
}

resource "vault_token" "transit" {
  policies  = [vault_policy.autounseal.name]
  no_parent = true
  period    = "768h"
}

resource "local_file" "transit_token" {
  content  = vault_token.transit.client_token
  filename = "${var.kms_output_dir}/transit-token.txt"
}

# ─── KV v2 (Terraform state backend) ─────────────────────────────────

resource "vault_mount" "secret" {
  path    = "secret"
  type    = "kv"
  options = { version = "2" }

  depends_on = [terraform_data.init_unseal]
}

resource "vault_policy" "vault_backend" {
  name   = "vault-backend"
  policy = <<-EOT
    path "secret/data/tfstate/*" { capabilities = ["create", "read", "update"] }
    path "secret/metadata/tfstate/*" { capabilities = ["delete", "read", "list"] }
  EOT
}

resource "vault_token" "vault_backend" {
  policies  = [vault_policy.vault_backend.name]
  no_parent = true
  period    = "768h"
}

resource "local_file" "vault_backend_token" {
  content  = vault_token.vault_backend.client_token
  filename = "${var.kms_output_dir}/vault-backend-token.txt"
}

# ─── PKI Root CA ──────────────────────────────────────────────────────

resource "vault_mount" "pki_root" {
  path                  = "pki"
  type                  = "pki"
  max_lease_ttl_seconds = 315360000 # 10 years

  depends_on = [terraform_data.init_unseal]
}

resource "vault_pki_secret_backend_root_cert" "root" {
  backend      = vault_mount.pki_root.path
  type         = "internal"
  common_name  = "Talos Platform Root CA"
  organization = "Talos Platform"
  key_type     = "ec"
  key_bits     = 384
  ttl          = "87600h"
  issuer_name  = "root"
}

resource "local_file" "root_ca" {
  content  = vault_pki_secret_backend_root_cert.root.certificate
  filename = "${var.kms_output_dir}/root-ca.pem"
}

# ─── Sub-CA helper module ─────────────────────────────────────────────

module "infra_ca" {
  source       = "./sub-ca"
  name         = "infra"
  common_name  = "Talos Platform Infra CA"
  mount_path   = "pki_infra"
  root_backend = vault_mount.pki_root.path
  root_ca_pem  = vault_pki_secret_backend_root_cert.root.certificate
  domains      = ["svc.cluster.local", "cluster.local", "local"]
  output_dir   = var.kms_output_dir
}

module "app_ca" {
  source       = "./sub-ca"
  name         = "app"
  common_name  = "Talos Platform App CA"
  mount_path   = "pki_app"
  root_backend = vault_mount.pki_root.path
  root_ca_pem  = vault_pki_secret_backend_root_cert.root.certificate
  domains      = ["svc.cluster.local", "local"]
  output_dir   = var.kms_output_dir
}

# ─── Cluster secrets (identity + storage) ─────────────────────────────

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
  mount = vault_mount.secret.path
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
  mount = vault_mount.secret.path
  name  = "cluster/storage"
  data_json = jsonencode({
    garage_rpc_secret      = random_password.storage["garage_rpc_secret"].result
    garage_admin_token     = random_password.storage["garage_admin_token"].result
    harbor_admin_password  = random_password.harbor_admin.result
  })
}

# ─── Read-only token for Terraform stacks ─────────────────────────────

resource "vault_policy" "cluster_secrets_ro" {
  name   = "cluster-secrets-ro"
  policy = <<-EOT
    path "secret/data/cluster/*" { capabilities = ["read"] }
  EOT
}

resource "vault_token" "cluster_secrets" {
  policies  = [vault_policy.cluster_secrets_ro.name]
  no_parent = true
  period    = "768h"
}

resource "local_file" "cluster_secrets_token" {
  content  = vault_token.cluster_secrets.client_token
  filename = "${var.kms_output_dir}/cluster-secrets-token.txt"
}
