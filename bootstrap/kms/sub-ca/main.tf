terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}

resource "vault_mount" "pki" {
  path                  = var.mount_path
  type                  = "pki"
  max_lease_ttl_seconds = 157680000 # 5 years
}

resource "vault_pki_secret_backend_intermediate_cert_request" "this" {
  backend      = vault_mount.pki.path
  type         = "exported"
  common_name  = var.common_name
  organization = "Talos Platform"
  key_type     = "ec"
  key_bits     = 384
}

resource "vault_pki_secret_backend_root_sign_intermediate" "this" {
  backend      = var.root_backend
  csr          = vault_pki_secret_backend_intermediate_cert_request.this.csr
  common_name  = var.common_name
  organization = "Talos Platform"
  ttl          = "43800h"
}

resource "vault_pki_secret_backend_intermediate_set_signed" "this" {
  backend     = vault_mount.pki.path
  certificate = "${vault_pki_secret_backend_root_sign_intermediate.this.certificate}\n${vault_pki_secret_backend_root_sign_intermediate.this.issuing_ca}"
}

resource "vault_pki_secret_backend_role" "default" {
  backend          = vault_mount.pki.path
  name             = "default"
  allowed_domains  = var.domains
  allow_subdomains = true
  allow_bare_domains = true
  max_ttl          = "8760h"
  key_type         = "ec"
  key_bits         = 256

  depends_on = [vault_pki_secret_backend_intermediate_set_signed.this]
}

resource "local_file" "ca_key" {
  content  = vault_pki_secret_backend_intermediate_cert_request.this.private_key
  filename = "${var.output_dir}/${var.name}-ca-key.pem"
}

resource "local_file" "ca_cert" {
  content  = vault_pki_secret_backend_root_sign_intermediate.this.certificate
  filename = "${var.output_dir}/${var.name}-ca.pem"
}

resource "local_file" "ca_chain" {
  content  = "${vault_pki_secret_backend_root_sign_intermediate.this.certificate}\n${var.root_ca_pem}"
  filename = "${var.output_dir}/${var.name}-ca-chain.pem"
}
