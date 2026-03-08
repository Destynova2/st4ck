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
  }
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

  values = [file("${path.module}/../../../configs/trivy/values.yaml")]

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

  values = [file("${path.module}/../../../configs/tetragon/values.yaml")]

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

  values = [file("${path.module}/../../../configs/kyverno/values.yaml")]

  depends_on = [kubernetes_namespace.security]
}
