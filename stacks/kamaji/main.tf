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
  config_path = var.kubeconfig_path
}

provider "helm" {
  kubernetes {
    config_path = var.kubeconfig_path
  }
}

# ═══════════════════════════════════════════════════════════════════════
# Kamaji — Hosted Control Planes (KaaS)
#
# Prerequisites (see ADR-025):
#   - Cilium CNI deployed (stacks/cni)
#   - cert-manager + ClusterIssuer "internal-ca" deployed (stacks/pki).
#     Kamaji's admission webhook uses cert-manager to issue its serving cert.
#
# This stack ONLY installs the operators:
#   1. Kamaji (hosted CP manager) in namespace kamaji-system
#   2. Ænix etcd-operator (per-tenant etcd) in namespace etcd-operator-system
#
# Tenant TenantControlPlane + EtcdCluster resources are NOT created here —
# they are rendered per-tenant by stacks/managed-cluster using the templates
# under ./templates/.
# ═══════════════════════════════════════════════════════════════════════

# Version pins come from the platform version registry (single source of
# truth shared with Flux postBuild.substituteFrom and the Hauler manifest):
# clusters/management/versions-configmap.yaml. Variables stay as optional
# overrides (default null).
locals {
  platform_versions = yamldecode(file("${path.module}/../../clusters/management/versions-configmap.yaml")).data
}

locals {
  labels_common = {
    "app.kubernetes.io/part-of"    = "st4ck"
    "app.kubernetes.io/managed-by" = "opentofu"
  }
}

# ─── Kamaji namespace ────────────────────────────────────────────────

resource "kubernetes_namespace" "kamaji" {
  metadata {
    name = var.namespace_kamaji
    labels = merge(local.labels_common, {
      "app.kubernetes.io/name"             = "kamaji"
      "pod-security.kubernetes.io/enforce" = "baseline"
    })
  }
}

# ─── Kamaji operator ─────────────────────────────────────────────────
# CRDs are installed by the chart itself.
# Webhook serving cert is issued by cert-manager via ClusterIssuer "internal-ca".

resource "helm_release" "kamaji" {
  name             = "kamaji"
  # ⚠ 2026-07-14 : Clastix a ferme l'acces ANONYME a ghcr.io/clastix
  # (401 sur le token pull — chart et image). Un deploiement fresh de ce
  # stack echoue tant que : (a) un compte/token Clastix est configure,
  # (b) les artefacts sont re-serves depuis notre registre (hauler/zot),
  # ou (c) une alternative a Kamaji est actee. Decision a prendre —
  # coherent avec leur passage stable-payant (cf. ADR-020/025 et le
  # rapport docs/reviews/2026-07-12 versions : "edge = canal de facto").
  repository       = "oci://ghcr.io/clastix/charts"
  chart            = "kamaji"
  version          = coalesce(var.kamaji_version, local.platform_versions.kamaji_version)
  namespace        = kubernetes_namespace.kamaji.metadata[0].name
  create_namespace = false

  values = [file("${path.module}/values.yaml")]

  depends_on = [kubernetes_namespace.kamaji]
}

# ─── Ænix etcd-operator namespace ────────────────────────────────────

resource "kubernetes_namespace" "etcd_operator" {
  metadata {
    name = var.namespace_etcd_operator
    labels = merge(local.labels_common, {
      "app.kubernetes.io/name"             = "etcd-operator"
      "pod-security.kubernetes.io/enforce" = "baseline"
    })
  }
}

# ─── Ænix etcd-operator ──────────────────────────────────────────────
# Provides the EtcdCluster CRD used by each tenant's Kamaji DataStore.

resource "helm_release" "etcd_operator" {
  name             = "etcd-operator"
  repository       = "oci://ghcr.io/aenix-io/charts"
  chart            = "etcd-operator"
  version          = coalesce(var.etcd_operator_version, local.platform_versions.etcd_operator_version)
  namespace        = kubernetes_namespace.etcd_operator.metadata[0].name
  create_namespace = false

  depends_on = [kubernetes_namespace.etcd_operator]
}
