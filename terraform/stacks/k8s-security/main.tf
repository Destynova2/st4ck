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

# ─── Cosign image verification policy (audit mode) ─────────────────
# verifyImages: images from internal Harbor must be signed with Cosign.
# Set to Audit until Harbor + Cosign signing pipeline is operational.

resource "terraform_data" "cosign_verify_policy" {
  depends_on = [helm_release.kyverno]

  input = {
    host = var.kubernetes_host
    ca   = var.kubernetes_ca_certificate
    cert = var.kubernetes_client_certificate
    key  = var.kubernetes_client_key
  }

  triggers_replace = [
    filemd5("${path.module}/../../../configs/kyverno/verify-images.yaml"),
  ]

  provisioner "local-exec" {
    command     = <<-EOT
      set -e
      CA=$(mktemp) && CERT=$(mktemp) && KEY=$(mktemp)
      echo "$K8S_CA" | base64 -d > "$CA"
      echo "$K8S_CERT" | base64 -d > "$CERT"
      echo "$K8S_KEY" | base64 -d > "$KEY"
      kubectl --server="$K8S_HOST" --certificate-authority="$CA" --client-certificate="$CERT" --client-key="$KEY" \
        apply -f ${path.module}/../../../configs/kyverno/verify-images.yaml
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
        delete clusterpolicy verify-image-signatures --ignore-not-found --timeout=30s || true
      rm -f "$CA" "$CERT" "$KEY"
    EOT
  }
}
