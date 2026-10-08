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

# Migration-only state: Flux owns Garage, its layout Job and consumers.
removed {
  from = kubernetes_namespace.storage
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_namespace.garage
  lifecycle {
    destroy = false
  }
}

removed {
  from = helm_release.garage
  lifecycle {
    destroy = false
  }
}

removed {
  from = terraform_data.garage_wait
  lifecycle {
    destroy = false
  }
}

removed {
  from = terraform_data.garage_layout
  lifecycle {
    destroy = false
  }
}

removed {
  from = terraform_data.garage_buckets_keys
  lifecycle {
    destroy = false
  }
}
