terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# ═══════════════════════════════════════════════════════════════════════
# Auto-generated secrets (stored in Terraform state, never on disk)
# ═══════════════════════════════════════════════════════════════════════

resource "random_id" "openbao_infra_root_token" {
  byte_length = 32
}

resource "random_id" "openbao_app_root_token" {
  byte_length = 32
}

resource "random_id" "hydra_system_secret" {
  byte_length = 32
}

resource "random_id" "pomerium_shared_secret" {
  byte_length = 32
}

resource "random_id" "pomerium_cookie_secret" {
  byte_length = 32
}

resource "random_id" "pomerium_client_secret" {
  byte_length = 32
}

provider "kubernetes" {
  host                   = var.kubernetes_host
  client_certificate     = base64decode(var.kubernetes_client_certificate)
  client_key             = base64decode(var.kubernetes_client_key)
  cluster_ca_certificate = base64decode(var.kubernetes_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = var.kubernetes_host
    client_certificate     = base64decode(var.kubernetes_client_certificate)
    client_key             = base64decode(var.kubernetes_client_key)
    cluster_ca_certificate = base64decode(var.kubernetes_ca_certificate)
  }
}

# ═══════════════════════════════════════════════════════════════════════
# PKI — Root CA + Intermediate CA (pure Terraform, zero service)
# ═══════════════════════════════════════════════════════════════════════

# ─── Root CA ──────────────────────────────────────────────────────────

resource "tls_private_key" "root_ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P384"
}

resource "tls_self_signed_cert" "root_ca" {
  private_key_pem = tls_private_key.root_ca.private_key_pem

  subject {
    common_name  = "${var.pki_org} Root CA"
    organization = var.pki_org
  }

  validity_period_hours = 87600 # 10 years
  is_ca_certificate     = true

  allowed_uses = [
    "cert_signing",
    "crl_signing",
  ]
}

# ─── Intermediate CA ─────────────────────────────────────────────────

resource "tls_private_key" "intermediate_ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P384"
}

resource "tls_cert_request" "intermediate_ca" {
  private_key_pem = tls_private_key.intermediate_ca.private_key_pem

  subject {
    common_name  = "${var.pki_org} Intermediate CA"
    organization = var.pki_org
  }
}

resource "tls_locally_signed_cert" "intermediate_ca" {
  cert_request_pem   = tls_cert_request.intermediate_ca.cert_request_pem
  ca_private_key_pem = tls_private_key.root_ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.root_ca.cert_pem

  validity_period_hours = 43800 # 5 years
  is_ca_certificate     = true

  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "digital_signature",
  ]
}

# ─── Store CA chain in Kubernetes secret ─────────────────────────────

resource "kubernetes_namespace" "secrets" {
  metadata {
    name = "secrets"
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
    }
  }
}

resource "kubernetes_secret" "pki_root_ca" {
  metadata {
    name      = "pki-root-ca"
    namespace = "secrets"
  }

  data = {
    "ca.crt" = tls_self_signed_cert.root_ca.cert_pem
  }

  depends_on = [kubernetes_namespace.secrets]
}

resource "kubernetes_secret" "pki_intermediate_ca" {
  metadata {
    name      = "pki-intermediate-ca"
    namespace = "secrets"
  }

  data = {
    "tls.crt" = "${tls_locally_signed_cert.intermediate_ca.cert_pem}${tls_self_signed_cert.root_ca.cert_pem}"
    "tls.key" = tls_private_key.intermediate_ca.private_key_pem
    "ca.crt"  = tls_self_signed_cert.root_ca.cert_pem
  }

  type = "kubernetes.io/tls"

  depends_on = [kubernetes_namespace.secrets]
}

# ═══════════════════════════════════════════════════════════════════════
# OpenBao Infra — PKI backend + infrastructure secrets
# ═══════════════════════════════════════════════════════════════════════

resource "helm_release" "openbao_infra" {
  name             = "openbao-infra"
  repository       = "https://openbao.github.io/openbao-helm"
  chart            = "openbao"
  version          = var.openbao_version
  namespace        = "secrets"
  create_namespace = false

  values = [templatefile("${path.module}/../../../configs/openbao/values-infra.yaml", {
    root_token = random_id.openbao_infra_root_token.hex
  })]

  depends_on = [kubernetes_namespace.secrets]
}

# ═══════════════════════════════════════════════════════════════════════
# OpenBao App — application secrets
# ═══════════════════════════════════════════════════════════════════════

resource "helm_release" "openbao_app" {
  name             = "openbao-app"
  repository       = "https://openbao.github.io/openbao-helm"
  chart            = "openbao"
  version          = var.openbao_version
  namespace        = "secrets"
  create_namespace = false

  values = [templatefile("${path.module}/../../../configs/openbao/values-app.yaml", {
    root_token = random_id.openbao_app_root_token.hex
  })]

  depends_on = [kubernetes_namespace.secrets]
}

# ═══════════════════════════════════════════════════════════════════════
# cert-manager — automatic TLS certificates from intermediate CA
# ═══════════════════════════════════════════════════════════════════════

resource "kubernetes_namespace" "cert_manager" {
  metadata {
    name = "cert-manager"
  }
}

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_version
  namespace        = "cert-manager"
  create_namespace = false

  values = [file("${path.module}/../../../configs/cert-manager/values.yaml")]

  depends_on = [kubernetes_namespace.cert_manager]
}

# Intermediate CA secret in cert-manager namespace (for ClusterIssuer)
resource "kubernetes_secret" "cert_manager_ca" {
  metadata {
    name      = "intermediate-ca-keypair"
    namespace = "cert-manager"
  }

  data = {
    "tls.crt" = "${tls_locally_signed_cert.intermediate_ca.cert_pem}${tls_self_signed_cert.root_ca.cert_pem}"
    "tls.key" = tls_private_key.intermediate_ca.private_key_pem
  }

  type = "kubernetes.io/tls"

  depends_on = [kubernetes_namespace.cert_manager]
}

# ClusterIssuer — applied via kubectl after CRDs exist
resource "terraform_data" "cluster_issuer" {
  depends_on = [helm_release.cert_manager, kubernetes_secret.cert_manager_ca]

  input = {
    host = var.kubernetes_host
    ca   = var.kubernetes_ca_certificate
    cert = var.kubernetes_client_certificate
    key  = var.kubernetes_client_key
  }

  provisioner "local-exec" {
    command     = <<-EOT
      set -e
      CA=$(mktemp) && CERT=$(mktemp) && KEY=$(mktemp)
      echo "$K8S_CA" | base64 -d > "$CA"
      echo "$K8S_CERT" | base64 -d > "$CERT"
      echo "$K8S_KEY" | base64 -d > "$KEY"
      kubectl --server="$K8S_HOST" --certificate-authority="$CA" --client-certificate="$CERT" --client-key="$KEY" \
        apply -f ${path.module}/../../../configs/cert-manager/cluster-issuer.yaml
      rm -f "$CA" "$CERT" "$KEY"
    EOT
    environment = {
      K8S_HOST = var.kubernetes_host
      K8S_CA   = var.kubernetes_ca_certificate
      K8S_CERT = var.kubernetes_client_certificate
      K8S_KEY  = var.kubernetes_client_key
    }
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -e
      CA=$(mktemp) && CERT=$(mktemp) && KEY=$(mktemp)
      echo "${self.input.ca}" | base64 -d > "$CA"
      echo "${self.input.cert}" | base64 -d > "$CERT"
      echo "${self.input.key}" | base64 -d > "$KEY"
      kubectl --server="${self.input.host}" --certificate-authority="$CA" --client-certificate="$CERT" --client-key="$KEY" \
        delete clusterissuer internal-ca --ignore-not-found --timeout=30s || true
      rm -f "$CA" "$CERT" "$KEY"
    EOT
  }
}

# ═══════════════════════════════════════════════════════════════════════
# Identity — Ory Kratos + Hydra + Pomerium
# ═══════════════════════════════════════════════════════════════════════

resource "kubernetes_namespace" "identity" {
  metadata {
    name = "identity"
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
    }
  }
}

# ─── Ory Kratos (identity management) ────────────────────────────────

resource "helm_release" "kratos" {
  name             = "kratos"
  repository       = "https://k8s.ory.sh/helm/charts"
  chart            = "kratos"
  version          = var.kratos_version
  namespace        = "identity"
  create_namespace = false

  values = [file("${path.module}/../../../configs/kratos/values.yaml")]

  depends_on = [kubernetes_namespace.identity]
}

# ─── Ory Hydra (OAuth2 / OIDC) ──────────────────────────────────────

resource "helm_release" "hydra" {
  name             = "hydra"
  repository       = "https://k8s.ory.sh/helm/charts"
  chart            = "hydra"
  version          = var.hydra_version
  namespace        = "identity"
  create_namespace = false

  values = [templatefile("${path.module}/../../../configs/hydra/values.yaml", {
    system_secret = random_id.hydra_system_secret.hex
  })]

  depends_on = [kubernetes_namespace.identity]
}

# ─── Pomerium (zero-trust access proxy) ─────────────────────────────

resource "helm_release" "pomerium" {
  name             = "pomerium"
  repository       = "https://helm.pomerium.io"
  chart            = "pomerium"
  version          = var.pomerium_version
  namespace        = "identity"
  create_namespace = false

  values = [templatefile("${path.module}/../../../configs/pomerium/values.yaml", {
    client_secret = random_id.pomerium_client_secret.hex
    shared_secret = random_id.pomerium_shared_secret.b64_std
    cookie_secret = random_id.pomerium_cookie_secret.b64_std
  })]

  depends_on = [kubernetes_namespace.identity, helm_release.hydra]
}
