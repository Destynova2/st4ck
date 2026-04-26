# ─── PKI via TLS provider (no OpenBao PKI engine needed) ─────────────
#
# IDEMPOTENCY INVARIANT: every key+cert here has lifecycle.ignore_changes
# = all so they're generated ONCE and reused on every subsequent apply.
# Same reasoning as random_bytes.bao_seal_key (see envs/scaleway/ci/main.tf):
# silent rotation on state loss would invalidate the entire PKI chain
# (cert-manager ClusterIssuer "internal-ca", ESO, Pomerium, all internal
# services trust the root CA). Rotating any of these MUST be a deliberate
# `tofu state rm` + apply.

resource "tls_private_key" "root_ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P384"

  lifecycle {
    ignore_changes = all
  }
}

resource "tls_self_signed_cert" "root_ca" {
  private_key_pem = tls_private_key.root_ca.private_key_pem

  subject {
    common_name  = "Talos Platform Root CA"
    organization = "Talos Platform"
  }

  validity_period_hours = 87600 # 10 years
  is_ca_certificate     = true

  allowed_uses = [
    "cert_signing",
    "crl_signing",
  ]

  lifecycle {
    ignore_changes = all
  }
}

resource "local_file" "root_ca" {
  content  = tls_self_signed_cert.root_ca.cert_pem
  filename = "${var.output_dir}/root-ca.pem"
}

# ─── Infra Sub-CA ────────────────────────────────────────────────────

resource "tls_private_key" "infra_ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P384"

  lifecycle {
    ignore_changes = all
  }
}

resource "tls_cert_request" "infra_ca" {
  private_key_pem = tls_private_key.infra_ca.private_key_pem

  subject {
    common_name  = "Talos Platform Infra CA"
    organization = "Talos Platform"
  }
}

resource "tls_locally_signed_cert" "infra_ca" {
  cert_request_pem   = tls_cert_request.infra_ca.cert_request_pem
  ca_private_key_pem = tls_private_key.root_ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.root_ca.cert_pem

  validity_period_hours = 43800 # 5 years
  is_ca_certificate     = true

  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "digital_signature",
  ]

  lifecycle {
    ignore_changes = all
  }
}

resource "local_sensitive_file" "infra_ca_key" {
  content         = tls_private_key.infra_ca.private_key_pem
  filename        = "${var.output_dir}/infra-ca-key.pem"
  file_permission = "0600"
}

resource "local_file" "infra_ca_cert" {
  content  = tls_locally_signed_cert.infra_ca.cert_pem
  filename = "${var.output_dir}/infra-ca.pem"
}

resource "local_file" "infra_ca_chain" {
  content  = "${tls_locally_signed_cert.infra_ca.cert_pem}${tls_self_signed_cert.root_ca.cert_pem}"
  filename = "${var.output_dir}/infra-ca-chain.pem"
}

# ─── App Sub-CA ──────────────────────────────────────────────────────

resource "tls_private_key" "app_ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P384"

  lifecycle {
    ignore_changes = all
  }
}

resource "tls_cert_request" "app_ca" {
  private_key_pem = tls_private_key.app_ca.private_key_pem

  subject {
    common_name  = "Talos Platform App CA"
    organization = "Talos Platform"
  }
}

resource "tls_locally_signed_cert" "app_ca" {
  cert_request_pem   = tls_cert_request.app_ca.cert_request_pem
  ca_private_key_pem = tls_private_key.root_ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.root_ca.cert_pem

  validity_period_hours = 43800 # 5 years
  is_ca_certificate     = true

  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "digital_signature",
  ]

  lifecycle {
    ignore_changes = all
  }
}

resource "local_sensitive_file" "app_ca_key" {
  content         = tls_private_key.app_ca.private_key_pem
  filename        = "${var.output_dir}/app-ca-key.pem"
  file_permission = "0600"
}

resource "local_file" "app_ca_cert" {
  content  = tls_locally_signed_cert.app_ca.cert_pem
  filename = "${var.output_dir}/app-ca.pem"
}

resource "local_file" "app_ca_chain" {
  content  = "${tls_locally_signed_cert.app_ca.cert_pem}${tls_self_signed_cert.root_ca.cert_pem}"
  filename = "${var.output_dir}/app-ca-chain.pem"
}
