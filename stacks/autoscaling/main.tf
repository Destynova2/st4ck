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

# Migration only. Flux owns the namespace and the three metrics/pod scalers.
# Legacy AWS/CAPI controllers are preserved, NOT adopted by the native provider.
# Uninstall them explicitly after draining their NodeClaims (ADR-044).
removed {
  from = kubernetes_namespace.autoscaling
  lifecycle {
    destroy = false
  }
}
removed {
  from = helm_release.karpenter
  lifecycle {
    destroy = false
  }
}
removed {
  from = helm_release.karpenter_capi_provider
  lifecycle {
    destroy = false
  }
}
removed {
  from = helm_release.prometheus_adapter
  lifecycle {
    destroy = false
  }
}
removed {
  from = helm_release.vpa
  lifecycle {
    destroy = false
  }
}
removed {
  from = helm_release.keda
  lifecycle {
    destroy = false
  }
}
