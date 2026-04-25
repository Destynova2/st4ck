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
  repository       = "oci://ghcr.io/clastix/charts"
  chart            = "kamaji"
  version          = var.kamaji_version
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
  version          = var.etcd_operator_version
  namespace        = kubernetes_namespace.etcd_operator.metadata[0].name
  create_namespace = false

  depends_on = [kubernetes_namespace.etcd_operator]
}
