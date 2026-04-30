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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
    # tls provider needed by secrets.tf for the cosign keypair. Cosign
    # generation lives in pki (not security) so it can be seeded into
    # OpenBao via the same terraform_data.seed_openbao_secrets bash
    # batch — security stack downstream pulls cosign.{pub,key} via
    # ESO, matching the SSO-for-secrets goal (Phase 1a-1).
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

# ═══════════════════════════════════════════════════════════════════════
# PKI — Certificates from KMS bootstrap (emulates external CA authority)
#
# Prerequisites: make kms-bootstrap (generates certs in kms-output/)
# ═══════════════════════════════════════════════════════════════════════

locals {
  kms = var.kms_output_dir

  root_ca_cert   = file("${local.kms}/root-ca.pem")
  infra_ca_cert  = file("${local.kms}/infra-ca.pem")
  infra_ca_key   = file("${local.kms}/infra-ca-key.pem")
  infra_ca_chain = file("${local.kms}/infra-ca-chain.pem")
  app_ca_cert    = file("${local.kms}/app-ca.pem")
  app_ca_key     = file("${local.kms}/app-ca-key.pem")
  app_ca_chain   = file("${local.kms}/app-ca-chain.pem")
}

# ─── Secrets Namespace ──────────────────────────────────────────────

resource "kubernetes_namespace" "secrets" {
  metadata {
    name = "secrets"
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
    }
  }
}

# ─── Store CA certs in Kubernetes secrets ───────────────────────────

resource "kubernetes_secret" "pki_root_ca" {
  metadata {
    name      = "pki-root-ca"
    namespace = "secrets"
  }

  data = {
    "ca.crt" = local.root_ca_cert
  }

  depends_on = [kubernetes_namespace.secrets]
}

resource "kubernetes_secret" "pki_infra_ca" {
  metadata {
    name      = "pki-infra-ca"
    namespace = "secrets"
  }

  data = {
    "tls.crt" = local.infra_ca_chain
    "tls.key" = local.infra_ca_key
    "ca.crt"  = local.root_ca_cert
  }

  type = "kubernetes.io/tls"

  depends_on = [kubernetes_namespace.secrets]
}

resource "kubernetes_secret" "pki_app_ca" {
  metadata {
    name      = "pki-app-ca"
    namespace = "secrets"
  }

  data = {
    "tls.crt" = local.app_ca_chain
    "tls.key" = local.app_ca_key
    "ca.crt"  = local.root_ca_cert
  }

  type = "kubernetes.io/tls"

  depends_on = [kubernetes_namespace.secrets]
}

# ─── OpenBao seal key (shared, static seal for auto-unseal) ──────────
# DRIFT: ADR-026 deviation — static seal accepted risk for Gate 1/2.
# See docs/adr/026-openbao-static-seal-accepted-risk.md (tracked drift).
# Migrate to KMS-wrap (Scaleway KMS) before promoting any prod-* cluster.

resource "random_bytes" "openbao_seal_key" {
  length = 32

  # CATASTROPHIC if rotated: same logic as random_bytes.bao_seal_key
  # in envs/scaleway/ci/main.tf — this is the static-seal key for the
  # in-cluster OpenBao instances. Re-generation = unrecoverable Bao
  # raft state (ESO secrets, Hydra/Pomerium/Garage/Harbor seeds, etc.).
  lifecycle {
    ignore_changes = all
  }
}

resource "kubernetes_secret" "openbao_seal_key" {
  metadata {
    name      = "openbao-seal-key"
    namespace = "secrets"
  }

  data = {
    key = random_bytes.openbao_seal_key.hex
  }

  depends_on = [kubernetes_namespace.secrets]
}

resource "random_password" "openbao_admin" {
  length  = 32
  special = false

  lifecycle {
    ignore_changes = all
  }
}

resource "kubernetes_secret" "openbao_admin_password" {
  metadata {
    name      = "openbao-admin-password"
    namespace = "secrets"
  }

  data = {
    password = random_password.openbao_admin.result
  }

  depends_on = [kubernetes_namespace.secrets]
}

# ─── OpenBao Infra — PKI backend + infrastructure secrets ──────────

resource "helm_release" "openbao_infra" {
  name             = "openbao-infra"
  repository       = "https://openbao.github.io/openbao-helm"
  chart            = "openbao"
  version          = var.openbao_version
  namespace        = "secrets"
  create_namespace = false

  # Phase F-bis-2 — Helm-native HA. Deploy 3 replicas d'emblée via
  # values-openbao-infra.yaml (server.ha.replicas: 3 +
  # statefulSet.podManagementPolicy: OrderedReady).
  # K8s GARANTIT pod-0 Ready avant pod-1 → race window OpenBao 2.x
  # #2274 (split-brain) éliminée architecturalement.
  # Remplace l'ancien pattern Bootstrap@1 + terraform_data scale_to_ha
  # (Fix #5/#11/#32) qui scalait 1→3 par script bash + recovery loop.
  values = [
    file("${path.module}/flux/values-openbao-infra.yaml"),
  ]

  depends_on = [
    kubernetes_namespace.secrets,
    kubernetes_secret.openbao_seal_key,
    kubernetes_secret.openbao_admin_password,
    kubectl_manifest.openbao_infra_cert,
  ]
}

# Defensive health check — Phase F-bis-2 replacement for the ancien
# terraform_data.openbao_infra_scale_to_ha (~120 lignes scale + recovery
# bash). Le pattern Helm-native (replicas: 3 + retry_join +
# podManagementPolicy: OrderedReady) gère le bootstrap nativement, donc
# on n'a plus besoin de scale 1→3 ni de recovery split-brain. Ce check
# poll juste les 3 pods Ready après helm install, fail-fast si raft pas
# convergé (laisse l'erreur K8s remonter au lieu de tenter recovery custom).
resource "terraform_data" "openbao_infra_health_check" {
  triggers_replace = {
    helm_id = helm_release.openbao_infra.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      KC="${var.kubeconfig_path}"
      echo "Waiting for OpenBao Infra raft 3/3 healthy..."
      for i in $(seq 1 300); do
        READY=0
        for p in openbao-infra-0 openbao-infra-1 openbao-infra-2; do
          R=$(kubectl --kubeconfig=$KC -n secrets get pod $p -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo false)
          [ "$R" = "true" ] && READY=$((READY+1))
        done
        if [ "$READY" = "3" ]; then
          echo "  raft 3/3 ready after $${i}s"
          exit 0
        fi
        sleep 1
      done
      echo "ERROR: OpenBao Infra raft not 3/3 healthy after 5min."
      kubectl --kubeconfig=$KC -n secrets get pods -l app.kubernetes.io/instance=openbao-infra
      exit 1
    EOT
  }

  depends_on = [helm_release.openbao_infra]
}

# ─── OpenBao App — application secrets ─────────────────────────────

resource "helm_release" "openbao_app" {
  name             = "openbao-app"
  repository       = "https://openbao.github.io/openbao-helm"
  chart            = "openbao"
  version          = var.openbao_version
  namespace        = "secrets"
  create_namespace = false

  # Phase F-bis-2 — Helm-native HA. Voir helm_release.openbao_infra
  # ci-dessus pour rationale complet (replicas: 3 + retry_join +
  # podManagementPolicy: OrderedReady gérés via values-openbao-app.yaml).
  values = [
    file("${path.module}/flux/values-openbao-app.yaml"),
  ]

  depends_on = [
    kubernetes_namespace.secrets,
    kubernetes_secret.openbao_seal_key,
    kubectl_manifest.openbao_app_cert,
  ]
}

# Defensive health check — Phase F-bis-2 (mirror of openbao_infra_health_check).
# Voir terraform_data.openbao_infra_health_check ci-dessus pour rationale.
resource "terraform_data" "openbao_app_health_check" {
  triggers_replace = {
    helm_id = helm_release.openbao_app.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      KC="${var.kubeconfig_path}"
      echo "Waiting for OpenBao App raft 3/3 healthy..."
      for i in $(seq 1 300); do
        READY=0
        for p in openbao-app-0 openbao-app-1 openbao-app-2; do
          R=$(kubectl --kubeconfig=$KC -n secrets get pod $p -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo false)
          [ "$R" = "true" ] && READY=$((READY+1))
        done
        if [ "$READY" = "3" ]; then
          echo "  raft 3/3 ready after $${i}s"
          exit 0
        fi
        sleep 1
      done
      echo "ERROR: OpenBao App raft not 3/3 healthy after 5min."
      kubectl --kubeconfig=$KC -n secrets get pods -l app.kubernetes.io/instance=openbao-app
      exit 1
    EOT
  }

  depends_on = [helm_release.openbao_app]
}

# ─── cert-manager — automatic TLS from infra sub-CA ────────────────

resource "kubernetes_namespace" "cert_manager" {
  metadata {
    name = "cert-manager"
    # PSA labels MUST mirror stacks/pki/flux/namespace.yaml — without
    # both sources declaring the same labels, server-side-apply between
    # tofu + Flux would strip whichever label is present on only one
    # side (silent PSA drift). Same fix pattern as the garage namespace
    # (#10). Postmortem 2026-04-29 (#14).
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/warn"    = "baseline"
    }
  }
}

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_version
  namespace        = "cert-manager"
  create_namespace = false

  values = [file("${path.module}/flux/values-cert-manager.yaml")]

  depends_on = [kubernetes_namespace.cert_manager]
}

# ─── External Secrets Operator (CRDs + controllers) ─────────────────
# Installed in pki stack (not Flux) because security/storage/identity/
# monitoring all apply ExternalSecret/PushSecret CRs via tofu BEFORE
# flux-bootstrap runs. Without ESO CRDs at apply time those stacks
# fail with "resource isn't valid for cluster, check the APIVersion".
# ClusterSecretStore wiring still happens via Flux.
resource "kubernetes_namespace" "external_secrets" {
  metadata {
    name = "external-secrets"
    # PSA labels MUST mirror stacks/external-secrets/flux/namespace.yaml.
    # Same SSA idempotency reasoning as cert_manager above — both
    # sources must declare baseline to prevent silent label stripping
    # on Flux reconcile. Postmortem 2026-04-29 (#14).
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/warn"    = "baseline"
    }
  }
}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.external_secrets_version
  namespace        = "external-secrets"
  create_namespace = false

  set {
    name  = "installCRDs"
    value = "true"
  }

  depends_on = [kubernetes_namespace.external_secrets]
}

# ─── ClusterSecretStore (openbao-infra) ──────────────────────────────
# Applied here (NOT via Flux) to break the catch-22:
#   Flux GitRepository pull → needs flux-ssh-identity Secret
#     → comes from ExternalSecret
#       → needs ClusterSecretStore openbao-infra
#         → if managed by Flux, can never deploy because Flux can't
#           pull the repo. Loop.
# Putting CSS in tofu (alongside the ESO install) breaks the cycle so
# Flux can pull on first reconcile.
resource "kubectl_manifest" "cluster_secret_store" {
  yaml_body = file("${path.module}/../external-secrets/flux-config/cluster-secret-store.yaml")

  depends_on = [
    helm_release.external_secrets,
    terraform_data.bootstrap_openbao_pki,
  ]
}

# Infra sub-CA keypair in cert-manager namespace (for ClusterIssuer)
resource "kubernetes_secret" "cert_manager_ca" {
  metadata {
    name      = "intermediate-ca-keypair"
    namespace = "cert-manager"
  }

  data = {
    "tls.crt" = local.infra_ca_chain
    "tls.key" = local.infra_ca_key
  }

  type = "kubernetes.io/tls"

  depends_on = [kubernetes_namespace.cert_manager]
}

# ─── OpenBao PKI CA bundle for Vault Issuer (Phase 1b-2) ────────────
#
# The Vault-kind ClusterIssuer "internal-ca" needs caBundleSecretRef to
# validate OpenBao's TLS endpoint cert (Secret openbao-infra-tls in
# secrets ns). For Phase 1b-2, that endpoint cert is still signed by
# the bootstrap issuer → the bundle is the same infra-ca-chain that
# intermediate-ca-keypair uses to sign things. Phase 2/3 may rotate.
#
# Secret lives in cert-manager namespace (matches cert-manager's
# default --cluster-resource-namespace flag — Vault ClusterIssuer
# resolves caBundleSecretRef in that namespace).
resource "kubernetes_secret" "openbao_pki_ca_bundle" {
  metadata {
    name      = "openbao-pki-ca-bundle"
    namespace = "cert-manager"
  }

  data = {
    "ca.crt" = local.infra_ca_chain
  }

  depends_on = [kubernetes_namespace.cert_manager]
}

# ClusterIssuers — bootstrap (CA-secret) + day-2 (Vault/OpenBao PKI).
# See cluster-issuer.yaml header for the chicken-and-egg rationale.
#
# Split into TWO Tofu resources to break a dependency cycle:
#
#   helm_release.openbao_infra
#     ↳ kubectl_manifest.openbao_infra_cert  (needs an issuer at startup)
#         ↳ cluster_issuer (bootstrap)       ← MUST exist pre-OpenBao
#                                              (NO openbao dep, else cycle)
#
#   terraform_data.bootstrap_openbao_pki     ← needs openbao_infra running
#     ↳ cluster_issuer (vault)               ← needs the pki_int role +
#                                              cert-manager k8s auth role
#                                              that bootstrap_openbao_pki
#                                              creates
#
# The bootstrap issuer therefore MUST NOT depend on bootstrap_openbao_pki.
# The Vault issuer depends on it (and on the bootstrap issuer being live,
# transitively, since openbao-infra-tls is signed by the bootstrap issuer
# and the Vault issuer's caBundleSecretRef points to the same chain).

# ─── Bootstrap ClusterIssuer (CA-secret kind) ────────────────────────
# Pre-OpenBao. Signs OpenBao's own endpoint cert. No OpenBao dependency.
resource "kubectl_manifest" "cluster_issuer_bootstrap" {
  yaml_body = <<-YAML
    apiVersion: cert-manager.io/v1
    kind: ClusterIssuer
    metadata:
      name: internal-ca-bootstrap
    spec:
      ca:
        secretName: intermediate-ca-keypair
  YAML

  depends_on = [
    helm_release.cert_manager,
    kubernetes_secret.cert_manager_ca,
  ]
}

# ─── Day-2 ClusterIssuer (Vault kind, OpenBao PKI backend) ───────────
# Renamed locally to "internal-ca" — name kept stable so every existing
# Certificate CR (hydra-tls, pomerium-*-tls, headlamp, etc.) renews from
# OpenBao on its next cycle without YAML edits cascading.
resource "kubectl_manifest" "cluster_issuer_vault" {
  yaml_body = <<-YAML
    apiVersion: cert-manager.io/v1
    kind: ClusterIssuer
    metadata:
      name: internal-ca
    spec:
      vault:
        server: https://openbao-infra.secrets.svc:8200
        path: pki_int/sign/cluster-issuer
        caBundleSecretRef:
          name: openbao-pki-ca-bundle
          key: ca.crt
        auth:
          kubernetes:
            role: cert-manager
            mountPath: /v1/auth/kubernetes
            serviceAccountRef:
              name: cert-manager
              # namespace field removed: not in cert-manager 1.19 schema
              # for vault.auth.kubernetes.serviceAccountRef. SA defaults
              # to cert-manager's own namespace, which is what we want.
  YAML

  depends_on = [
    helm_release.cert_manager,
    kubernetes_secret.openbao_pki_ca_bundle,
    terraform_data.bootstrap_openbao_pki,
  ]
}

# ─── Cilium-only ClusterIssuer (RSA tolerated) ──────────────────────
# Cilium's hubble.tls.auto.method=certmanager auto-creates Certificate
# CRs without a way to override privateKey.algorithm — they default to
# RSA-2048. The strict `internal-ca` issuer above rejects RSA, so we
# add a 2nd issuer pointing at the cilium-hubble PKI role (key_type=any,
# CN allowlist scoped to *.hubble-grpc.cilium.io). Audit log unchanged.
resource "kubectl_manifest" "cluster_issuer_cilium" {
  yaml_body = <<-YAML
    apiVersion: cert-manager.io/v1
    kind: ClusterIssuer
    metadata:
      name: cilium-issuer
    spec:
      vault:
        server: https://openbao-infra.secrets.svc:8200
        path: pki_int/sign/cilium-hubble
        caBundleSecretRef:
          name: openbao-pki-ca-bundle
          key: ca.crt
        auth:
          kubernetes:
            role: cert-manager
            mountPath: /v1/auth/kubernetes
            serviceAccountRef:
              name: cert-manager
  YAML

  depends_on = [
    helm_release.cert_manager,
    kubernetes_secret.openbao_pki_ca_bundle,
    terraform_data.bootstrap_openbao_pki,
  ]
}


# ─── TLS certificates for in-cluster OpenBao ──────────────────────────
#
# Both OpenBao endpoint certs (infra + app) are issued by the BOOTSTRAP
# ClusterIssuer (internal-ca-bootstrap, CA-secret kind). This breaks the
# chicken-and-egg where the Vault issuer would need OpenBao reachable to
# issue OpenBao's reachability cert. Every OTHER Certificate in the
# cluster uses the Vault issuer "internal-ca" → audited by OpenBao.

resource "kubectl_manifest" "openbao_infra_cert" {
  yaml_body = <<-YAML
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: openbao-infra-tls
      namespace: secrets
    spec:
      secretName: openbao-infra-tls
      issuerRef:
        name: internal-ca-bootstrap
        kind: ClusterIssuer
      dnsNames:
        - openbao-infra
        - openbao-infra.secrets
        - openbao-infra.secrets.svc
        - openbao-infra.secrets.svc.cluster.local
      duration: 8760h    # 1 year
      renewBefore: 720h  # 30 days
  YAML

  depends_on = [kubectl_manifest.cluster_issuer_bootstrap, kubernetes_namespace.secrets]
}

resource "kubectl_manifest" "openbao_app_cert" {
  yaml_body = <<-YAML
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: openbao-app-tls
      namespace: secrets
    spec:
      secretName: openbao-app-tls
      issuerRef:
        name: internal-ca-bootstrap
        kind: ClusterIssuer
      dnsNames:
        - openbao-app
        - openbao-app.secrets
        - openbao-app.secrets.svc
        - openbao-app.secrets.svc.cluster.local
      duration: 8760h
      renewBefore: 720h
  YAML

  depends_on = [kubectl_manifest.cluster_issuer_bootstrap, kubernetes_namespace.secrets]
}
