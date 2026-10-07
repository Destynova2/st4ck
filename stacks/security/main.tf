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
    # tls provider removed: cosign keypair generation moved to the pki
    # stack (Phase 1a-1) — security stack now consumes the materialized
    # K8s Secrets via ExternalSecret only.
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

# Version pins come from the platform version registry (single source of
# truth shared with Flux postBuild.substituteFrom and the Hauler manifest):
# clusters/management/versions-configmap.yaml. Variables stay as optional
# overrides (default null).
locals {
  platform_versions = yamldecode(file("${path.module}/../../clusters/management/versions-configmap.yaml")).data
}

# Flux owns the namespace and Cosign ExternalSecrets (ADR-043).
removed {
  from = kubernetes_namespace.security
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubectl_manifest.cosign_externalsecrets
  lifecycle {
    destroy = false
  }
}
