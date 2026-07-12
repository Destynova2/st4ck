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
# Kept alongside OpenClarity during the migration: Trivy operator emits
# VulnerabilityReport CRs that other tooling (e.g. Polaris, kube-bench)
# consume directly. OpenClarity is a higher-level multi-scanner that also
# uses Trivy under the hood — they don't conflict, just produce two
# overlapping data sources. Migration plan: see ADR-027.

# trivy-operator → Flux owner (helmrelease-trivy.yaml). ADR-028.

# ─── OpenClarity (multi-scanner: Trivy + Grype + Syft) ───────────────
# Linux Foundation / OpenSSF project (formerly KubeClarity by Anchore).
# Discovers images in the cluster, runs Trivy + Grype + Syft in parallel,
# dedupes findings, exposes a UI + API + Postgres-backed history.
#
# Two scanners on the same image catch CVEs that one alone misses:
#   - Trivy DB: NVD + RedHat + Alpine + Debian + Ubuntu + …
#   - Grype DB: Anchore syft + GitHub Security Advisories
# Defense-in-depth without paying for Snyk.

# ─── CNPG Cluster for OpenClarity (mirrors identity stack pattern) ──
# OpenClarity needs a Postgres backend. Bitnami's bundled chart fails
# on the Aug-2025 Docker Hub paywall; SQLite works but loses features
# (no concurrent writes, harder backup). Use a dedicated CNPG cluster
# in this namespace. Depends on the CNPG operator from the identity
# stack — operator is cluster-scoped so one install handles all CRs.

# ─── CNPG external certificates (Phase 1b-3) ───────────────────────
# Same pattern as stacks/identity/main.tf — see header in
# stacks/security/flux-openclarity-eso/openclarity-pg-certs.yaml for the
# full rationale. Files moved out of flux/ during the OpenClarity Flux
# split (Bug #21 / Phase C resume): the ESO + cert pipeline lives in
# flux-openclarity-eso/ so the HelmRelease Kustomization (flux-openclarity)
# can dependsOn it cleanly.
data "kubectl_file_documents" "openclarity_pg_certs" {
  content = file("${path.module}/flux-openclarity-eso/openclarity-pg-certs.yaml")
}

resource "kubectl_manifest" "openclarity_pg_certs" {
  for_each = data.kubectl_file_documents.openclarity_pg_certs.manifests

  yaml_body = each.value

  depends_on = [kubernetes_namespace.security]
}

# The CNPG CRD is installed by the cnpg_operator Helm release in
# stacks/identity. This cross-stack edge was only guaranteed by k8s-up's
# ordering (pipeline audit 2026-07-12 A0): a standalone
# k8s-security-apply on a fresh cluster failed on "resource
# [postgresql.cnpg.io/v1/Cluster] isn't valid". The wait puts the edge
# in the stack, not the orchestrator.
resource "terraform_data" "wait_cnpg_crd" {
  provisioner "local-exec" {
    environment = { KUBECONFIG = var.kubeconfig_path }
    command     = <<-EOT
      set -eu
      echo "Waiting for CNPG CRD (installed by stacks/identity)..."
      for i in $(seq 1 120); do
        kubectl get crd clusters.postgresql.cnpg.io >/dev/null 2>&1 && exit 0
        sleep 1
      done
      echo "ERROR: CNPG CRD not found after 120s — deploy stacks/identity first." >&2
      exit 1
    EOT
  }
}

resource "kubectl_manifest" "openclarity_pg_cluster" {
  yaml_body = <<-YAML
    apiVersion: postgresql.cnpg.io/v1
    kind: Cluster
    metadata:
      name: openclarity-pg
      namespace: security
    spec:
      instances: 2
      storage:
        size: 5Gi
      # WAL archive against Garage S3 — see stacks/identity/main.tf for
      # the postmortem 2026-04-28 explaining why both AWS_REGION AND
      # AWS_DEFAULT_REGION must be set (boto3 falls back to us-east-1
      # without the latter, breaking sigv4 against Garage's "garage"
      # signing region).
      env:
        - name: AWS_REGION
          value: "garage"
        - name: AWS_DEFAULT_REGION
          value: "garage"
      # Phase 1b-3: external certs from cert-manager (OpenBao PKI).
      certificates:
        serverCASecret: openclarity-pg-server-ca-tls
        serverTLSSecret: openclarity-pg-server-tls
        clientCASecret: openclarity-pg-client-ca-tls
        replicationTLSSecret: openclarity-pg-replication-tls
      bootstrap:
        initdb:
          database: openclarity
          owner: openclarity
  YAML

  depends_on = [
    terraform_data.wait_cnpg_crd,
    kubernetes_namespace.security,
    # All 4 cert Secrets must exist before CNPG inspects spec.certificates.
    kubectl_manifest.openclarity_pg_certs,
  ]
}

# Phase 1a-3: openclarity-pg-credentials is no longer materialized by Tofu.
# The PushSecret + ExternalSecret pair in
# flux-openclarity-eso/external-secrets-openclarity.yaml now owns the
# lifecycle:
#   1. CNPG creates openclarity-pg-app on cluster bootstrap
#   2. PushSecret openclarity-pg-mirror copies it into OpenBao at
#      secret/security/db/openclarity (rotation-safe, see eso-readonly policy
#      which grants write on secret/data/*/db/* — single source of truth)
#   3. ExternalSecret openclarity-pg-credentials renders the
#      {username,password,database} Secret OpenClarity reads via
#      externalPostgresql.auth.existingSecret
# Race-free at deploy time: helm_release.openclarity below waits on the
# OpenBao seed Job + ESO sync via the kubectl_manifest below.

# OpenClarity → Flux owner (ADR-028 wave 2).
# stacks/security/flux/helmrelease-openclarity.yaml uses OCIRepository
# (ghcr.io/openclarity/charts/openclarity is OCI-only, no index.yaml).
# Tofu still creates the CNPG cluster + ESO secrets that OpenClarity
# consumes at startup.

# ─── Tetragon (eBPF runtime security observability) ──────────────────
# Talos Linux v1.12+: extraHostPathMounts for /sys/kernel/tracing in values.yaml

# tetragon + kyverno → Flux owner (helmrelease-tetragon.yaml + helmrelease-kyverno.yaml). ADR-028.

# ─── Cosign / OpenClarity ESO manifests (Phase 1a-1, 1a-3) ─────────
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
# OpenClarity DB credentials follow the same pattern (PushSecret mirrors
# CNPG's openclarity-pg-app into OpenBao, then ExternalSecret renders
# openclarity-pg-credentials with the {username,password,database} schema
# the chart wants).
#
# YAML-only (kubectl_manifest) so that the future "tofu state rm + handoff
# to Flux" step from the README is a one-liner — Flux already has these
# files in its kustomization.yaml.

# Multi-doc YAML files split by kubectl_file_documents → one
# kubectl_manifest per doc. Lets us keep human-readable single files
# (one for cosign, one for openclarity) shared between Tofu day-1 and
# Flux day-2 (kustomization.yaml below references the same files).
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

data "kubectl_file_documents" "openclarity_eso" {
  content = file("${path.module}/flux-openclarity-eso/external-secrets-openclarity.yaml")
}

resource "kubectl_manifest" "openclarity_eso" {
  for_each = data.kubectl_file_documents.openclarity_eso.manifests

  yaml_body = each.value

  depends_on = [
    kubernetes_namespace.security,
    # PushSecret needs CNPG's openclarity-pg-app to exist on the source
    # side. ExternalSecret needs the OpenBao path written by PushSecret.
    # Both are inside the same multi-doc file so we depend on the cluster
    # only — the ExternalSecret will retry on its refreshInterval until
    # the PushSecret has populated OpenBao (~one cycle, default 1h, but
    # the doc opts into 30s for the bootstrap window).
    kubectl_manifest.openclarity_pg_cluster,
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
