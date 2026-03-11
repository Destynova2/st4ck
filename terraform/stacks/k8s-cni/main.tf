terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }
}

provider "helm" {
  kubernetes {
    config_path = var.kubeconfig_path
  }
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

  values = [file("${path.module}/../../../configs/cilium/values.yaml")]
}
