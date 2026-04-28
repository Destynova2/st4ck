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

# ─── OpenBao admin password (read from secrets/openbao-admin-password) ──
# Seeded by stacks/pki/main.tf (random_password.openbao_admin → K8s
# Secret). Reading it here keeps flux-bootstrap decoupled from pki's
# tofu state — no terraform_remote_state, no shared backend creds.
# The Secret MUST exist by the time this stack runs; in the standard
# pipeline, pki runs before flux-bootstrap, so this is satisfied.
data "kubernetes_secret" "openbao_admin_password" {
  metadata {
    name      = "openbao-admin-password"
    namespace = "secrets"
  }
}

# ─── Seed Flux SSH key into OpenBao Infra (KV v2) ─────────────────
#
# Why here (not in stacks/pki/secrets.tf with the other seeds)?
#   pki has no visibility on tls_private_key.flux_ssh (lives in this
#   stack), and we don't want a cross-stack remote_state read for one
#   secret. So this resource mirrors the pki `seed_openbao_secrets`
#   pattern (kubectl exec → bao login userpass → bao kv put) but lives
#   alongside the resource that owns the key.
#
# What it writes:
#   secret/flux/ssh
#     ├── identity      = ed25519 private key (OpenSSH PEM)
#     ├── identity.pub  = ed25519 public key (OpenSSH)
#     └── known_hosts   = SSH host key for Gitea (rotates with CI VM)
#
# Idempotency:
#   `bao kv put` overwrites — safe for re-apply. We don't gate on
#   "already seeded" like pki does because known_hosts legitimately
#   rotates per CI VM redeploy (the SSH KEY itself is pinned by
#   tls_private_key's lifecycle.ignore_changes).
#
# Trigger (input):
#   sha256 of public key + known_hosts. The private key is not in
#   the trigger to avoid rewriting state on every refresh; the pubkey
#   uniquely identifies the keypair.
resource "terraform_data" "seed_flux_ssh_to_openbao" {
  input = sha256(join(",", [
    tls_private_key.flux_ssh.public_key_openssh,
    var.gitea_known_hosts,
  ]))

  provisioner "local-exec" {
    environment = {
      KUBECONFIG         = var.kubeconfig_path
      BAO_ADMIN_PASSWORD = data.kubernetes_secret.openbao_admin_password.data["password"]
      FLUX_SSH_IDENTITY  = tls_private_key.flux_ssh.private_key_openssh
      FLUX_SSH_PUBLIC    = tls_private_key.flux_ssh.public_key_openssh
      FLUX_KNOWN_HOSTS   = var.gitea_known_hosts
    }
    command = <<-EOT
      set -eu

      # Same TLS-skip pattern as stacks/pki/secrets.tf: cert is for the
      # cluster-internal DNS name, not 127.0.0.1 from inside the pod.
      BAO="kubectl -n secrets exec openbao-infra-0 -c openbao -- env BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true"

      echo "Waiting for OpenBao Infra API..."
      for i in $(seq 1 60); do
        $BAO bao status >/dev/null 2>&1 && break
        echo "  attempt $i/60..." && sleep 5
      done

      echo "Logging in..."
      $BAO bao login -method=userpass username=admin password="$BAO_ADMIN_PASSWORD" >/dev/null 2>&1 || \
        { echo "ERROR: OpenBao login failed"; exit 1; }

      # bao kv put — k=v pairs (same pattern as stacks/pki/secrets.tf).
      # Values come from env vars on the inner pod process so they
      # don't appear in the workstation's `ps` output; the only argv
      # leak surface is the kubelet exec audit log (acceptable, same
      # as pki seed). The literal key `identity.pub` is used because
      # Flux source-controller requires that exact filename.
      echo "Seeding secret/flux/ssh..."
      $BAO bao kv put secret/flux/ssh \
        identity="$FLUX_SSH_IDENTITY" \
        identity.pub="$FLUX_SSH_PUBLIC" \
        known_hosts="$FLUX_KNOWN_HOSTS"

      echo "Flux SSH seeded into OpenBao."
    EOT
  }
}

# ─── ExternalSecret: OpenBao secret/flux/ssh → flux-ssh-identity ──
#
# Replaces the previous `kubernetes_secret.flux_ssh_identity` resource
# (now removed). ESO recreates the K8s Secret from OpenBao on every
# refresh (1h) so:
#   - the only TF-managed copy of the private key is in tofu state
#     (encrypted in OpenBao KV v2 via vault-backend);
#   - K8s Secret is reconciled — `kubectl delete` heals automatically;
#   - the same secret can be consumed cluster-wide via OpenBao without
#     ever passing through Git or another tofu remote_state.
#
# Applied via kubectl_manifest because flux-bootstrap is a tofu-mode
# stack (no Flux Kustomization layer at apply time — Flux installs
# itself further down). depends_on the seed so the keys exist by the
# time ESO tries to read them; even if ESO refreshes pre-seed, it just
# retries every refreshInterval.
resource "kubectl_manifest" "flux_ssh_external_secret" {
  yaml_body = <<-YAML
    apiVersion: external-secrets.io/v1
    kind: ExternalSecret
    metadata:
      name: flux-ssh-identity
      namespace: flux-system
    spec:
      refreshInterval: 1h
      secretStoreRef:
        name: openbao-infra
        kind: ClusterSecretStore
      target:
        name: flux-ssh-identity
        creationPolicy: Owner
      data:
        - secretKey: identity
          remoteRef:
            key: flux/ssh
            property: identity
        - secretKey: identity.pub
          remoteRef:
            key: flux/ssh
            property: identity.pub
        - secretKey: known_hosts
          remoteRef:
            key: flux/ssh
            property: known_hosts
  YAML

  depends_on = [
    kubernetes_namespace.flux_system,
    terraform_data.seed_flux_ssh_to_openbao,
  ]
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
    # ESO populates the K8s Secret `flux-ssh-identity` from OpenBao.
    # source-controller will block on the secretRef until ESO writes
    # it, but ordering here keeps reconciliation snappy on first apply.
    kubectl_manifest.flux_ssh_external_secret,
    kubernetes_service.gitea_external,
    gitea_repository_key.flux,
  ]
}

# ─── Root Kustomizations: ESO first, then everything else ────────
#
# Two-phase split: ESO must be installed BEFORE the management
# Kustomization can apply the ClusterSecretStore CR (which references
# the ESO-provided CRD). Without this split, server-side dry-run on the
# CR fails because the CRD doesn't exist yet.
#
# Phase 1 — `management-eso`:
#   path:  ./clusters/management-eso/  (just external-secrets/flux/)
#   wait:  true  → blocks until the ESO HelmRelease reports Ready,
#                  i.e. the CRDs are installed.
#
# Phase 2 — `management`:
#   path:        ./clusters/management/  (all stacks INCLUDING
#                external-secrets/flux-config which has the CSS)
#   dependsOn:   management-eso
#   By the time we run, ESO is Ready → CSS dry-run succeeds.
resource "kubectl_manifest" "flux_kustomization_eso" {
  yaml_body = <<-YAML
    apiVersion: kustomize.toolkit.fluxcd.io/v1
    kind: Kustomization
    metadata:
      name: management-eso
      namespace: flux-system
    spec:
      interval: 10m
      sourceRef:
        kind: GitRepository
        name: management
      path: ./clusters/management-eso
      prune: true
      wait: true
      timeout: 5m
  YAML

  depends_on = [kubectl_manifest.flux_git_repo]
}

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
      dependsOn:
        - name: management-eso
  YAML

  depends_on = [kubectl_manifest.flux_kustomization_eso]
}
