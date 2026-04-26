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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
  }
}

provider "kubernetes" {
  config_path = var.kubeconfig_path
}

provider "helm" {
  kubernetes {
    config_path = var.kubeconfig_path
  }
}

provider "kubectl" {
  config_path      = var.kubeconfig_path
  load_config_file = true
}

# ═══════════════════════════════════════════════════════════════════════
# PKI — Certificates from KMS bootstrap (emulates external CA authority)
#
# Prerequisites: make kms-bootstrap (generates certs in kms-output/)
# ═══════════════════════════════════════════════════════════════════════

locals {
  kms = var.kms_output_dir

  root_ca_cert   = file("${local.kms}/root-ca.pem")
  infra_ca_cert  = file("${local.kms}/infra-ca.pem")
  infra_ca_key   = file("${local.kms}/infra-ca-key.pem")
  infra_ca_chain = file("${local.kms}/infra-ca-chain.pem")
  app_ca_cert    = file("${local.kms}/app-ca.pem")
  app_ca_key     = file("${local.kms}/app-ca-key.pem")
  app_ca_chain   = file("${local.kms}/app-ca-chain.pem")
}

# ─── Secrets Namespace ──────────────────────────────────────────────

resource "kubernetes_namespace" "secrets" {
  metadata {
    name = "secrets"
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
    }
  }
}

# ─── Store CA certs in Kubernetes secrets ───────────────────────────

resource "kubernetes_secret" "pki_root_ca" {
  metadata {
    name      = "pki-root-ca"
    namespace = "secrets"
  }

  data = {
    "ca.crt" = local.root_ca_cert
  }

  depends_on = [kubernetes_namespace.secrets]
}

resource "kubernetes_secret" "pki_infra_ca" {
  metadata {
    name      = "pki-infra-ca"
    namespace = "secrets"
  }

  data = {
    "tls.crt" = local.infra_ca_chain
    "tls.key" = local.infra_ca_key
    "ca.crt"  = local.root_ca_cert
  }

  type = "kubernetes.io/tls"

  depends_on = [kubernetes_namespace.secrets]
}

resource "kubernetes_secret" "pki_app_ca" {
  metadata {
    name      = "pki-app-ca"
    namespace = "secrets"
  }

  data = {
    "tls.crt" = local.app_ca_chain
    "tls.key" = local.app_ca_key
    "ca.crt"  = local.root_ca_cert
  }

  type = "kubernetes.io/tls"

  depends_on = [kubernetes_namespace.secrets]
}

# ─── OpenBao seal key (shared, static seal for auto-unseal) ──────────
# DRIFT: ADR-026 deviation — static seal accepted risk for Gate 1/2.
# See docs/adr/026-openbao-static-seal-accepted-risk.md (tracked drift).
# Migrate to KMS-wrap (Scaleway KMS) before promoting any prod-* cluster.

resource "random_bytes" "openbao_seal_key" {
  length = 32

  # CATASTROPHIC if rotated: same logic as random_bytes.bao_seal_key
  # in envs/scaleway/ci/main.tf — this is the static-seal key for the
  # in-cluster OpenBao instances. Re-generation = unrecoverable Bao
  # raft state (ESO secrets, Hydra/Pomerium/Garage/Harbor seeds, etc.).
  lifecycle {
    ignore_changes = all
  }
}

resource "kubernetes_secret" "openbao_seal_key" {
  metadata {
    name      = "openbao-seal-key"
    namespace = "secrets"
  }

  data = {
    key = random_bytes.openbao_seal_key.hex
  }

  depends_on = [kubernetes_namespace.secrets]
}

resource "random_password" "openbao_admin" {
  length  = 32
  special = false

  lifecycle {
    ignore_changes = all
  }
}

resource "kubernetes_secret" "openbao_admin_password" {
  metadata {
    name      = "openbao-admin-password"
    namespace = "secrets"
  }

  data = {
    password = random_password.openbao_admin.result
  }

  depends_on = [kubernetes_namespace.secrets]
}

# ─── OpenBao Infra — PKI backend + infrastructure secrets ──────────

resource "helm_release" "openbao_infra" {
  name             = "openbao-infra"
  repository       = "https://openbao.github.io/openbao-helm"
  chart            = "openbao"
  version          = var.openbao_version
  namespace        = "secrets"
  create_namespace = false

  values = [file("${path.module}/flux/values-openbao-infra.yaml")]

  depends_on = [
    kubernetes_namespace.secrets,
    kubernetes_secret.openbao_seal_key,
    kubernetes_secret.openbao_admin_password,
    kubectl_manifest.openbao_infra_cert,
  ]
}

# ─── OpenBao App — application secrets ─────────────────────────────

resource "helm_release" "openbao_app" {
  name             = "openbao-app"
  repository       = "https://openbao.github.io/openbao-helm"
  chart            = "openbao"
  version          = var.openbao_version
  namespace        = "secrets"
  create_namespace = false

  values = [file("${path.module}/flux/values-openbao-app.yaml")]

  depends_on = [
    kubernetes_namespace.secrets,
    kubernetes_secret.openbao_seal_key,
    kubectl_manifest.openbao_app_cert,
  ]
}

# ─── cert-manager — automatic TLS from infra sub-CA ────────────────

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

  values = [file("${path.module}/flux/values-cert-manager.yaml")]

  depends_on = [kubernetes_namespace.cert_manager]
}

# Infra sub-CA keypair in cert-manager namespace (for ClusterIssuer)
resource "kubernetes_secret" "cert_manager_ca" {
  metadata {
    name      = "intermediate-ca-keypair"
    namespace = "cert-manager"
  }

  data = {
    "tls.crt" = local.infra_ca_chain
    "tls.key" = local.infra_ca_key
  }

  type = "kubernetes.io/tls"

  depends_on = [kubernetes_namespace.cert_manager]
}

# ClusterIssuer — references the infra sub-CA keypair
resource "kubectl_manifest" "cluster_issuer" {
  yaml_body = file("${path.module}/cluster-issuer.yaml")

  depends_on = [helm_release.cert_manager, kubernetes_secret.cert_manager_ca]
}

# ─── TLS certificates for in-cluster OpenBao ──────────────────────────

resource "kubectl_manifest" "openbao_infra_cert" {
  yaml_body = <<-YAML
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: openbao-infra-tls
      namespace: secrets
    spec:
      secretName: openbao-infra-tls
      issuerRef:
        name: internal-ca
        kind: ClusterIssuer
      dnsNames:
        - openbao-infra
        - openbao-infra.secrets
        - openbao-infra.secrets.svc
        - openbao-infra.secrets.svc.cluster.local
      duration: 8760h    # 1 year
      renewBefore: 720h  # 30 days
  YAML

  depends_on = [kubectl_manifest.cluster_issuer, kubernetes_namespace.secrets]
}

resource "kubectl_manifest" "openbao_app_cert" {
  yaml_body = <<-YAML
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: openbao-app-tls
      namespace: secrets
    spec:
      secretName: openbao-app-tls
      issuerRef:
        name: internal-ca
        kind: ClusterIssuer
      dnsNames:
        - openbao-app
        - openbao-app.secrets
        - openbao-app.secrets.svc
        - openbao-app.secrets.svc.cluster.local
      duration: 8760h
      renewBefore: 720h
  YAML

  depends_on = [kubectl_manifest.cluster_issuer, kubernetes_namespace.secrets]
}
