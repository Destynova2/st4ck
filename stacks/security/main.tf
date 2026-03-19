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
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
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

# ─── Security Namespace ──────────────────────────────────────────────

resource "kubernetes_namespace" "security" {
  metadata {
    name = "security"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

# ─── Trivy Operator (vulnerability scanning + SBOM) ──────────────────

resource "helm_release" "trivy_operator" {
  name             = "trivy-operator"
  repository       = "https://aquasecurity.github.io/helm-charts"
  chart            = "trivy-operator"
  version          = var.trivy_operator_version
  namespace        = "security"
  create_namespace = false

  values = [file("${path.module}/values-trivy.yaml")]

  depends_on = [kubernetes_namespace.security]
}

# ─── Tetragon (eBPF runtime security observability) ──────────────────
# Talos Linux v1.12+: extraHostPathMounts for /sys/kernel/tracing in values.yaml

resource "helm_release" "tetragon" {
  name             = "tetragon"
  repository       = "https://helm.cilium.io"
  chart            = "tetragon"
  version          = var.tetragon_version
  namespace        = "security"
  create_namespace = false

  values = [file("${path.module}/values-tetragon.yaml")]

  depends_on = [kubernetes_namespace.security]
}

# ─── Kyverno (policy engine) ─────────────────────────────────────────

resource "helm_release" "kyverno" {
  name             = "kyverno"
  repository       = "https://kyverno.github.io/kyverno"
  chart            = "kyverno"
  version          = var.kyverno_version
  namespace        = "security"
  create_namespace = false

  values = [file("${path.module}/values-kyverno.yaml")]

  depends_on = [kubernetes_namespace.security]
}

# ─── Cosign keypair (for image signing + verification) ─────────────

resource "tls_private_key" "cosign" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "kubernetes_secret" "cosign_public_key" {
  metadata {
    name      = "cosign-public-key"
    namespace = "security"
  }

  data = {
    "cosign.pub" = tls_private_key.cosign.public_key_pem
  }

  depends_on = [kubernetes_namespace.security]
}

resource "kubernetes_secret" "cosign_private_key" {
  metadata {
    name      = "cosign-private-key"
    namespace = "security"
  }

  data = {
    "cosign.key" = tls_private_key.cosign.private_key_pem
  }

  depends_on = [kubernetes_namespace.security]
}

# ─── Cosign image verification policy ──────────────────────────────

resource "kubectl_manifest" "cosign_verify_policy" {
  yaml_body = file("${path.module}/verify-images.yaml")

  depends_on = [helm_release.kyverno]
}
