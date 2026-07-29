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

resource "kubernetes_namespace" "security" {
  metadata {
    name = "security"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

# ─── Trivy Operator (vulnerability scanning + SBOM) ──────────────────
# The platform's scanner (ADR-038): VulnerabilityReport, SbomReport,
# ExposedSecretReport, ConfigAudit/RBAC/compliance CRs.

# trivy-operator → Flux owner (helmrelease-trivy.yaml). ADR-028.

# ─── OpenClarity → RETIRÉ (ADR-038, 2026-07-13) ─────────────────────
# Le projet a été archivé upstream le 2026-05-29 (dernière release
# 2025-02-05). trivy-operator (ci-dessus) couvre SBOM / vulnérabilités /
# secrets / misconfig / RBAC. Manques assumés : malware (option
# documentée : Kubescape node-agent seul) et rootkits (aucun successeur
# k8s maintenu — mitigé par Talos immuable + Tetragon).
# Le cluster CNPG openclarity-pg, ses certs, le PushSecret et les deux
# Kustomizations Flux ont été supprimés — sur un cluster existant, le
# prochain apply détruit ces ressources (voulu) et Flux prune les CRs.

# tetragon + kyverno → Flux owner (helmrelease-tetragon.yaml + helmrelease-kyverno.yaml). ADR-028.

# ─── Cosign ESO manifests (Phase 1a-1) ─────────────────────────────
#
# Cosign keypair (cosign.pub / cosign.key) is now generated in the pki
# stack (stacks/pki/secrets.tf) and seeded into OpenBao at
# secret/security/cosign. The two ExternalSecrets below materialize the
# K8s Secrets that downstream consumers (Kyverno verifyImages, signing
# CronJob, ad-hoc cosign sign) still expect by name:
#
#   cosign-public-key  → key cosign.pub (read by verify-images.yaml)
#   cosign-private-key → key cosign.key

#
# YAML-only (kubectl_manifest) so that the future "tofu state rm + handoff
# to Flux" step from the README is a one-liner — Flux already has these
# files in its kustomization.yaml.

# Multi-doc YAML split by kubectl_file_documents → one kubectl_manifest
# per doc; the same file is shared between Tofu day-1 and Flux day-2.
data "kubectl_file_documents" "cosign_externalsecrets" {
  content = file("${path.module}/flux-kyverno-policies/external-secret-cosign.yaml")
}

resource "kubectl_manifest" "cosign_externalsecrets" {
  for_each = data.kubectl_file_documents.cosign_externalsecrets.manifests

  yaml_body = each.value

  depends_on = [
    kubernetes_namespace.security,
    # ESO CRDs must exist (deployed by the external-secrets stack which
    # runs before security in the pipeline). ClusterSecretStore
    # openbao-infra is also required — provided by the pki stack's
    # auto-init Job.
  ]
}

# ─── Cosign image verification policy → Flux owner ─────────────────
# The ClusterPolicy verify-image-signatures is owned by Flux ONLY
# (stacks/security/flux-kyverno-policies/cosign-policy.yaml, applied by
# the security-kyverno-policies Kustomization, gated on the Kyverno HR).
# A count-gated tofu copy used to live here with an INVALID schema
# (`key:` rejected by the Kyverno v1.17 CRD) — the documented remediation
# (re-running k8s-security-apply on a warm cluster) applied the invalid
# YAML and broke the apply. Removed 2026-07-12 (hanoi pass 2, T3).
# MIGRATION on clusters where the resource exists in state:
#   tofu state rm 'kubectl_manifest.cosign_verify_policy[0]'
# BEFORE applying, otherwise the next apply destroys Flux's policy.
