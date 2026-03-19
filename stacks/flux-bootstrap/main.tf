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

# ─── SSH Key Pair (for Flux → Gitea) ──────────────────────────────
# Ed25519 key pair — public key must be added to Gitea as a deploy key.
# The SSH CA infrastructure (openbao-cluster-init.sh) is available for
# workloads that use the system ssh binary (CI runners, custom controllers).
# Flux source-controller uses go-git which doesn't support SSH CA certs.

resource "tls_private_key" "flux_ssh" {
  algorithm = "ED25519"
}

# ─── Flux Namespace ──────────────────────────────────────────────
resource "kubernetes_namespace" "flux_system" {
  metadata {
    name = "flux-system"
  }
}

# ─── SSH identity secret for Flux ────────────────────────────────
resource "kubernetes_secret" "flux_ssh_identity" {
  metadata {
    name      = "flux-ssh-identity"
    namespace = "flux-system"
  }

  data = {
    identity       = tls_private_key.flux_ssh.private_key_openssh
    "identity.pub" = tls_private_key.flux_ssh.public_key_openssh
    known_hosts    = var.gitea_known_hosts
  }

  depends_on = [kubernetes_namespace.flux_system]
}

# ─── Flux v2 (Helm install) ─────────────────────────────────────
resource "helm_release" "flux" {
  name             = "flux2"
  repository       = "https://fluxcd-community.github.io/helm-charts"
  chart            = "flux2"
  version          = var.flux_version
  namespace        = "flux-system"
  create_namespace = false

  depends_on = [kubernetes_namespace.flux_system]
}

# ─── GitRepository source (SSH) ──────────────────────────────────
resource "kubectl_manifest" "flux_git_repo" {
  yaml_body = <<-YAML
    apiVersion: source.toolkit.fluxcd.io/v1
    kind: GitRepository
    metadata:
      name: management
      namespace: flux-system
    spec:
      interval: 5m
      url: ${var.gitea_ssh_url}
      ref:
        branch: main
      secretRef:
        name: flux-ssh-identity
  YAML

  depends_on = [helm_release.flux, kubernetes_secret.flux_ssh_identity]
}

# ─── Root Kustomization (points to clusters/management/) ────────
resource "kubectl_manifest" "flux_root_kustomization" {
  yaml_body = <<-YAML
    apiVersion: kustomize.toolkit.fluxcd.io/v1
    kind: Kustomization
    metadata:
      name: management
      namespace: flux-system
    spec:
      interval: 10m
      sourceRef:
        kind: GitRepository
        name: management
      path: ./clusters/management
      prune: true
      wait: true
      timeout: 5m
  YAML

  depends_on = [kubectl_manifest.flux_git_repo]
}
