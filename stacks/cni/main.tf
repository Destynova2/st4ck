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

provider "helm" {
  kubernetes {
    config_path = var.kubeconfig_path
  }
}

provider "kubernetes" {
  config_path = var.kubeconfig_path
}

# ─── Cilium CNI ──────────────────────────────────────────────────────────
# MUST be deployed first: without CNI, no pods can be scheduled.
# Fast deploy (~30s) — separated from monitoring to unblock k8s-pki early.

resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = var.cilium_version
  namespace  = "kube-system"

  values = [file("${path.module}/flux/values.yaml")]
}

# ─── local-path-provisioner ──────────────────────────────────────────────
# StorageClass dependency for the pki stack: OpenBao + cert-manager need
# PVCs which need a default StorageClass which needs a provisioner.
# Flux runs AFTER pki via flux-bootstrap, so this MUST be tofu-owned (not
# Flux-owned) — moving here closes the chicken/egg loop discovered during
# the 2026-04-29 manual rebuild postmortem.
#
# The helper-pod uses hostPath which baseline PSA rejects, so the namespace
# carries enforce=privileged labels (Fix #3).

resource "kubernetes_namespace" "local_path_storage" {
  metadata {
    name = "local-path-storage"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/warn"    = "privileged"
    }
  }
}

resource "helm_release" "local_path_provisioner" {
  name       = "local-path-provisioner"
  repository = "https://charts.containeroo.ch"
  chart      = "local-path-provisioner"
  version    = var.local_path_provisioner_version
  namespace  = kubernetes_namespace.local_path_storage.metadata[0].name

  create_namespace = false

  values = [file("${path.module}/values-local-path.yaml")]

  depends_on = [
    helm_release.cilium,
  ]
}
