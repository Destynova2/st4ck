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

# ─── OpenBao Infra — PKI backend + infrastructure secrets ──────────
# Standalone mode — run `make openbao-init` after first deploy

resource "helm_release" "openbao_infra" {
  name             = "openbao-infra"
  repository       = "https://openbao.github.io/openbao-helm"
  chart            = "openbao"
  version          = var.openbao_version
  namespace        = "secrets"
  create_namespace = false

  values = [file("${path.module}/../../../configs/openbao/values-infra.yaml")]

  depends_on = [kubernetes_namespace.secrets]
}

# ─── OpenBao App — application secrets ─────────────────────────────
# Standalone mode — run `make openbao-init` after first deploy

resource "helm_release" "openbao_app" {
  name             = "openbao-app"
  repository       = "https://openbao.github.io/openbao-helm"
  chart            = "openbao"
  version          = var.openbao_version
  namespace        = "secrets"
  create_namespace = false

  values = [file("${path.module}/../../../configs/openbao/values-app.yaml")]

  depends_on = [kubernetes_namespace.secrets]
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

  values = [file("${path.module}/../../../configs/cert-manager/values.yaml")]

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
  yaml_body = file("${path.module}/../../../configs/cert-manager/cluster-issuer.yaml")

  depends_on = [helm_release.cert_manager, kubernetes_secret.cert_manager_ca]
}
