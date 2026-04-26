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
    gitea = {
      source  = "go-gitea/gitea"
      version = "~> 0.6"
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

# Gitea API access — used to register Flux's SSH public key as a deploy
# key on the management repo. Reaches Gitea via the SSH tunnel set up by
# `make scaleway-tunnel-start` (localhost:3000 → CI VM platform-gitea).
provider "gitea" {
  base_url = var.gitea_api_url
  username = var.gitea_admin_user
  password = var.gitea_admin_password
}

# ─── SSH Key Pair (for Flux → Gitea) ──────────────────────────────
# Ed25519 key pair. The public key is registered as a Gitea deploy key
# below (gitea_deploy_key.flux). Flux source-controller uses go-git
# which doesn't support SSH CA certs — that's why this is a per-key
# trust, not a CA-signed cert.

resource "tls_private_key" "flux_ssh" {
  algorithm = "ED25519"

  # Rotation breaks Flux ↔ Gitea momentarily until gitea_deploy_key
  # below catches up. Idempotent re-applies preserve the key; explicit
  # rotation needs `tofu state rm` + apply (the gitea_deploy_key resource
  # also gets refreshed since its `key` attribute references the new pubkey).
  lifecycle {
    ignore_changes = all
  }
}

# ─── Register Flux's public key as a Gitea deploy key ─────────────────
# Read-only access (Flux only needs to clone). Title is namespaced so
# multiple environments (dev/staging/prod) can each register their own
# Flux key against the same repo without collision.
#
# This resource is the missing piece historically — the comment above
# tls_private_key.flux_ssh said "must be added to Gitea as a deploy key"
# but nothing actually did it (path-B redeploy 2026-04-26 surfaced the
# bug). Now automated.
#
# NOTE: gitea_repository_key.repository wants the numeric repo ID, not
# the path. We look it up via data "gitea_repo" — depends on the repo
# already existing (created in bootstrap/tofu/gitea.tf as ${ci_admin}/talos).
data "gitea_repo" "management" {
  username = var.gitea_repo_owner
  name     = var.gitea_repo_name
}

resource "gitea_repository_key" "flux" {
  repository = data.gitea_repo.management.id
  title      = "flux-source-controller-${var.flux_deploy_key_suffix}"
  key        = trimspace(tls_private_key.flux_ssh.public_key_openssh)
  read_only  = true
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

# ─── Service + Endpoints: gitea.flux-system.svc → CI VM IP ─────────
# Pattern K8s standard pour pointer un nom in-cluster vers une IP externe.
#
# Pourquoi pas Service ExternalName ?
#   ExternalName attend un *hostname* RFC 1123 (CNAME-able). K8s accepte
#   silencieusement une IP en valeur, mais CoreDNS ne peut pas générer
#   un CNAME vers une IP → NXDOMAIN à la résolution. Bug confirmé sur
#   `gitea.flux-system.svc.cluster.local` lookup depuis source-controller.
#
# Solution : Service sans selector (K8s ne génère pas d'Endpoints
# automatiquement) + Endpoints object explicite avec l'IP. CoreDNS sert
# alors un A record direct → la résolution marche.
#
# Tradeoffs vs hardcoding l'IP dans la GitRepository url :
#   - Cluster DNS reste valide si le CI VM IP change (modif d'un seul Endpoint)
#   - NetworkPolicies peuvent targetter le Service
#   - L'IP publique n'apparaît pas dans les manifests committed
resource "kubernetes_service" "gitea_external" {
  metadata {
    name      = "gitea"
    namespace = "flux-system"
  }
  spec {
    # Pas de selector → K8s ne crée pas d'Endpoints automatiquement,
    # nous les créons manuellement ci-dessous.
    port {
      name        = "ssh"
      port        = 22
      target_port = 2222
      protocol    = "TCP"
    }
  }
  depends_on = [kubernetes_namespace.flux_system]
}

resource "kubernetes_endpoints" "gitea_external" {
  metadata {
    name      = "gitea"  # Doit matcher le Service (pour wiring auto)
    namespace = "flux-system"
  }
  subset {
    address {
      ip = var.gitea_external_host
    }
    port {
      name     = "ssh"
      port     = 2222
      protocol = "TCP"
    }
  }
  depends_on = [kubernetes_service.gitea_external]
}

# ─── GitRepository source (SSH) ──────────────────────────────────
# url uses gitea.flux-system.svc.cluster.local (resolved by the Service
# above). The DNS short-name "gitea" works inside flux-system but the
# FQDN is portable across namespaces if Flux ever needs to reach it
# from elsewhere.
locals {
  # Composed from owner+name so the URL stays in sync with the actual
  # Gitea path (bootstrap/tofu/gitea.tf creates ${ci_admin}/talos).
  # Fixed hostname:port = the in-cluster Service this stack provisions
  # above, which the Endpoints object routes to var.gitea_external_host:2222.
  gitea_ssh_url = "ssh://git@gitea.flux-system.svc.cluster.local:22/${var.gitea_repo_owner}/${var.gitea_repo_name}.git"
}

resource "kubectl_manifest" "flux_git_repo" {
  yaml_body = <<-YAML
    apiVersion: source.toolkit.fluxcd.io/v1
    kind: GitRepository
    metadata:
      name: management
      namespace: flux-system
    spec:
      interval: 5m
      url: ${local.gitea_ssh_url}
      ref:
        branch: main
      secretRef:
        name: flux-ssh-identity
  YAML

  depends_on = [
    helm_release.flux,
    kubernetes_secret.flux_ssh_identity,
    kubernetes_service.gitea_external,
    gitea_repository_key.flux,
  ]
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
