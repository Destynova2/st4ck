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
# Kept alongside OpenClarity during the migration: Trivy operator emits
# VulnerabilityReport CRs that other tooling (e.g. Polaris, kube-bench)
# consume directly. OpenClarity is a higher-level multi-scanner that also
# uses Trivy under the hood — they don't conflict, just produce two
# overlapping data sources. Migration plan: see ADR-027.

resource "helm_release" "trivy_operator" {
  name             = "trivy-operator"
  repository       = "https://aquasecurity.github.io/helm-charts"
  chart            = "trivy-operator"
  version          = var.trivy_operator_version
  namespace        = "security"
  create_namespace = false

  values = [file("${path.module}/flux/values-trivy.yaml")]

  depends_on = [kubernetes_namespace.security]
}

# ─── OpenClarity (multi-scanner: Trivy + Grype + Syft) ───────────────
# Linux Foundation / OpenSSF project (formerly KubeClarity by Anchore).
# Discovers images in the cluster, runs Trivy + Grype + Syft in parallel,
# dedupes findings, exposes a UI + API + Postgres-backed history.
#
# Two scanners on the same image catch CVEs that one alone misses:
#   - Trivy DB: NVD + RedHat + Alpine + Debian + Ubuntu + …
#   - Grype DB: Anchore syft + GitHub Security Advisories
# Defense-in-depth without paying for Snyk.

# ─── CNPG Cluster for OpenClarity (mirrors identity stack pattern) ──
# OpenClarity needs a Postgres backend. Bitnami's bundled chart fails
# on the Aug-2025 Docker Hub paywall; SQLite works but loses features
# (no concurrent writes, harder backup). Use a dedicated CNPG cluster
# in this namespace. Depends on the CNPG operator from the identity
# stack — operator is cluster-scoped so one install handles all CRs.

resource "kubectl_manifest" "openclarity_pg_cluster" {
  yaml_body = <<-YAML
    apiVersion: postgresql.cnpg.io/v1
    kind: Cluster
    metadata:
      name: openclarity-pg
      namespace: security
    spec:
      instances: 2
      storage:
        size: 5Gi
      bootstrap:
        initdb:
          database: openclarity
          owner: openclarity
  YAML

  depends_on = [kubernetes_namespace.security]
}

data "kubernetes_secret" "openclarity_pg_app" {
  metadata {
    name      = "openclarity-pg-app"
    namespace = "security"
  }
  depends_on = [kubectl_manifest.openclarity_pg_cluster]
}

# Re-key CNPG's secret into the {username,password,database} schema that
# OpenClarity's externalPostgresql.auth.existingSecret expects.
resource "kubernetes_secret" "openclarity_pg_credentials" {
  metadata {
    name      = "openclarity-pg-credentials"
    namespace = "security"
  }
  data = {
    username = data.kubernetes_secret.openclarity_pg_app.data["username"]
    password = data.kubernetes_secret.openclarity_pg_app.data["password"]
    database = "openclarity"
  }
  type = "Opaque"
}

resource "helm_release" "openclarity" {
  name             = "openclarity"
  # OpenClarity is published as an OCI artifact (no traditional Helm repo).
  chart            = "oci://ghcr.io/openclarity/charts/openclarity"
  version          = var.openclarity_version
  namespace        = "security"
  create_namespace = false

  values = [file("${path.module}/flux/values-openclarity.yaml")]

  # OpenClarity has 11+ pods (apiserver, orchestrator, ui, gateway, swagger-ui,
  # uibackend, trivy-server, grype-server, exploit-db, freshclam, yara-rule).
  # Helm wait=true with default 5min times out on slow clusters; switch to
  # async mode and let the operator inspect pods himself.
  wait    = false
  timeout = 900

  depends_on = [
    kubernetes_namespace.security,
    kubernetes_secret.openclarity_pg_credentials,
  ]
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

  values = [file("${path.module}/flux/values-tetragon.yaml")]

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

  values = [file("${path.module}/flux/values-kyverno.yaml")]

  depends_on = [kubernetes_namespace.security]
}

# ─── Cosign keypair (for image signing + verification) ─────────────

resource "tls_private_key" "cosign" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"

  # Rotation invalidates every existing image signature → Kyverno enforce
  # blocks all pods → cluster-wide outage. Lock it down.
  lifecycle {
    ignore_changes = all
  }
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
