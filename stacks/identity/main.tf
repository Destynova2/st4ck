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

# ═══════════════════════════════════════════════════════════════════════
# Secrets from k8s-pki stack (generated + seeded into OpenBao Infra)
# ═══════════════════════════════════════════════════════════════════════

# Version pins come from the platform version registry (single source of
# truth shared with Flux postBuild.substituteFrom and the Hauler manifest):
# clusters/management/versions-configmap.yaml. Variables stay as optional
# overrides (default null).
locals {
  platform_versions = yamldecode(file("${path.module}/../../clusters/management/versions-configmap.yaml")).data
}

# The pki remote_state read died with ADR-028 (secrets flow through
# OpenBao/ESO) — removed 2026-07-12 (hanoi pass 2 #5): it forced
# pki_state_password on every apply and broke naked `tofu apply`.

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

# Flux owns CNPG, certificates and identity workloads (ADR-043).
# Preserve existing objects while relinquishing the historical state.
removed {
  from = kubernetes_namespace.identity
  lifecycle {
    destroy = false
  }
}

removed {
  from = helm_release.cnpg_operator
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubectl_manifest.identity_pg_certs
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubectl_manifest.identity_pg_cluster
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubectl_manifest.identity_pg_scheduled_backup
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubectl_manifest.hydra_tls_cert
  lifecycle {
    destroy = false
  }
}
