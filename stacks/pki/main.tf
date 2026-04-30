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

  # Bootstrap with 1 replica, then scale to 3 via terraform_data below.
  # OpenBao 2.x has a known race (issue #2274): when 3 pods come up
  # simultaneously, each tries retry_join, the headless service hasn't
  # registered the others yet (DNS NXDOMAIN), so each pod self-inits
  # its own 1-node cluster (split-brain). The chart's initialize {}
  # blocks fire per-pod with no per-ordinal gating — there's no chart
  # parameter to fix this. The canonical workaround per OpenBao docs
  # + 2026 OpenShift guide: deploy with replicas=1, let pod-0 form a
  # quorum-of-1 cluster, then scale to 3 — pods 1+2 retry_join an
  # already-established leader and become followers cleanly.
  # Postmortem 2026-04-27 — 3 hours of debug to find this.
  values = [
    file("${path.module}/flux/values-openbao-infra.yaml"),
    yamlencode({
      server = {
        ha = {
          replicas = 1
        }
      }
    }),
  ]

  depends_on = [
    kubernetes_namespace.secrets,
    kubernetes_secret.openbao_seal_key,
    kubernetes_secret.openbao_admin_password,
    kubectl_manifest.openbao_infra_cert,
  ]
}

# Scale openbao-infra to 3 once pod-0 is established + initialized.
# Triggers on every apply but is idempotent — kubectl scale is no-op
# if already at desired replicas.
#
# Postmortem 2026-04-29 (Fix #5): added split-brain detection + recovery.
# Even with the kubernetes-auth gate above, we have observed pods 1+2
# self-electing as separate leaders before discovering pod-0 (race in the
# join handshake under load). Detection: `bao operator raft list-peers`
# count vs spec.replicas. Recovery: scale to 1, wipe pods 1+2 PVCs,
# scale back to 3, wait for clean rejoin. Idempotent — no-op when raft
# is healthy with 3 peers.
resource "terraform_data" "openbao_infra_scale_to_ha" {
  triggers_replace = {
    helm_id = helm_release.openbao_infra.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      KC="${var.kubeconfig_path}"
      echo "Waiting for openbao-infra-0 to be Ready, active leader, AND initialize blocks done…"
      # CRITICAL: must wait until ALL initialize {} blocks have materialized.
      # `bao status` returning 0 only means the API is up — it doesn't mean
      # initialize blocks have run. We check for the LAST initialize block's
      # output: the kubernetes auth method. Once that exists, all earlier
      # initialize blocks (kv, transit, ssh-ca, policies, approle) are done
      # too (initialize blocks run sequentially per OpenBao docs).
      # Without this check, pods 1+2 race with pod-0's init → split-brain.
      # Postmortem 2026-04-27 (#80).
      for i in $(seq 1 90); do
        READY=$(kubectl --kubeconfig=$KC -n secrets get pod openbao-infra-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)
        if [ "$READY" = "true" ]; then
          K8S_AUTH=$(kubectl --kubeconfig=$KC -n secrets exec -i openbao-infra-0 -c openbao -- env BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true sh -c "
            bao auth list 2>/dev/null | grep -c '^kubernetes/'
          " 2>/dev/null || echo 0)
          if [ "$K8S_AUTH" = "1" ]; then
            echo "  pod-0 ready + initialize blocks done (attempt $i)"
            break
          fi
        fi
        sleep 5
      done
      # Extra safety margin so pod-0 is fully settled as quorum-of-1 leader
      sleep 10
      echo "Scaling openbao-infra to 3 replicas…"
      kubectl --kubeconfig=$KC -n secrets scale statefulset openbao-infra --replicas=3
      echo "Waiting for pods 1+2 to retry_join + become Ready…"
      kubectl --kubeconfig=$KC -n secrets wait pod openbao-infra-1 openbao-infra-2 --for=condition=Ready --timeout=240s || true

      # ─── Fix #5: detect + recover split-brain raft state ───────────
      # Postmortem 2026-04-29: even after the kubernetes-auth gate,
      # observed pods 1+2 self-electing as their own raft leaders
      # (separate single-peer rafts) instead of joining pod-0's quorum.
      # Manual recovery was: scale 3→1, delete PVCs of pods 1+2, scale
      # back. Now automated. The expected count is 3 peers; anything
      # less means split-brain on pod-0's perspective.
      check_peers() {
        kubectl --kubeconfig=$KC -n secrets exec -i openbao-infra-0 -c openbao -- \
          env BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true sh -c \
          "bao operator raft list-peers 2>/dev/null | grep -c '^node-' || echo 0" \
          2>/dev/null || echo 0
      }
      sleep 10
      PEERS=$(check_peers)
      echo "Initial raft peer count from pod-0 perspective: $PEERS"
      if [ "$PEERS" != "3" ]; then
        echo "RECOVERY: split-brain detected (peers=$PEERS, want=3). Wiping pods 1+2 PVCs."
        kubectl --kubeconfig=$KC -n secrets scale statefulset openbao-infra --replicas=1
        # Wait for pods 1+2 to terminate before deleting PVCs
        for i in $(seq 1 30); do
          REM=$(kubectl --kubeconfig=$KC -n secrets get pods -l app.kubernetes.io/instance=openbao-infra --no-headers 2>/dev/null | grep -c -E 'openbao-infra-(1|2)' || echo 0)
          [ "$REM" = "0" ] && break
          sleep 5
        done
        # Delete PVCs (StatefulSet creates them as data-openbao-infra-<idx>)
        kubectl --kubeconfig=$KC -n secrets delete pvc data-openbao-infra-1 data-openbao-infra-2 --ignore-not-found --wait=true --timeout=60s || true
        sleep 5
        echo "  Re-scaling to 3 with fresh raft state for pods 1+2"
        kubectl --kubeconfig=$KC -n secrets scale statefulset openbao-infra --replicas=3
        kubectl --kubeconfig=$KC -n secrets wait pod openbao-infra-1 openbao-infra-2 --for=condition=Ready --timeout=240s || true
        sleep 15
        PEERS=$(check_peers)
        echo "Post-recovery raft peer count: $PEERS"
        if [ "$PEERS" != "3" ]; then
          echo "ERROR: raft still split-brain after recovery (peers=$PEERS). Manual intervention required."
          echo "  Inspect: kubectl --kubeconfig=$KC -n secrets exec openbao-infra-0 -- bao operator raft list-peers"
          exit 1
        fi
      fi
      echo "OpenBao raft healthy: 3 peers."
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

  # Bootstrap with 1 replica, then scale to 3 via terraform_data below.
  # Same OpenBao 2.x split-brain race as openbao-infra (issue #2274) —
  # see the comment block on helm_release.openbao_infra above.
  # Postmortem 2026-04-29 (#11) — fix #5 only sequenced openbao-infra,
  # openbao-app continued to deploy 3 pods simultaneously and split-brain
  # silently (the eso-readonly + admin endpoints rotated requests to
  # empty followers, breaking ESO + day-2 admin login intermittently).
  values = [
    file("${path.module}/flux/values-openbao-app.yaml"),
    yamlencode({
      server = {
        ha = {
          replicas = 1
        }
      }
    }),
  ]

  depends_on = [
    kubernetes_namespace.secrets,
    kubernetes_secret.openbao_seal_key,
    kubectl_manifest.openbao_app_cert,
  ]
}

# Scale openbao-app to 3 once pod-0 is established + initialized.
# Mirror of terraform_data.openbao_infra_scale_to_ha — same split-brain
# detection + recovery logic, with name+selector swapped from infra → app.
# Idempotent — kubectl scale is no-op if already at desired replicas, and
# the recovery path is a no-op when raft is healthy with 3 peers.
# Postmortem 2026-04-29 (#11).
resource "terraform_data" "openbao_app_scale_to_ha" {
  triggers_replace = {
    helm_id = helm_release.openbao_app.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      KC="${var.kubeconfig_path}"
      echo "Waiting for openbao-app-0 to be Ready, active leader, AND initialize blocks done…"
      # CRITICAL: wait until ALL initialize {} blocks have materialized.
      # openbao-app's only initialize block mounts secret/ as KV v2; we
      # check by listing mounts and grepping for it. Without this gate,
      # pods 1+2 race with pod-0's init → split-brain.
      # Same pattern as openbao_infra_scale_to_ha (postmortem 2026-04-27).
      K8S_AUTH=0
      for i in $(seq 1 90); do
        READY=$(kubectl --kubeconfig=$KC -n secrets get pod openbao-app-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)
        if [ "$READY" = "true" ]; then
          K8S_AUTH=$(kubectl --kubeconfig=$KC -n secrets exec -i openbao-app-0 -c openbao -- env BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true sh -c "
            bao secrets list 2>/dev/null | grep -c '^secret/'
          " 2>/dev/null || echo 0)
          if [ "$K8S_AUTH" = "1" ]; then
            echo "  pod-0 ready + initialize blocks done (attempt $i)"
            break
          fi
        fi
        sleep 5
      done
      if [ "$K8S_AUTH" != "1" ]; then
        echo "ERROR: openbao-app-0 not ready after 7.5min — aborting before scale to prevent split-brain"
        exit 1
      fi
      # Extra safety margin so pod-0 is fully settled as quorum-of-1 leader
      sleep 10
      echo "Scaling openbao-app to 3 replicas…"
      kubectl --kubeconfig=$KC -n secrets scale statefulset openbao-app --replicas=3
      echo "Waiting for pods 1+2 to retry_join + become Ready…"
      kubectl --kubeconfig=$KC -n secrets wait pod openbao-app-1 openbao-app-2 --for=condition=Ready --timeout=240s || true

      # ─── Split-brain detection + recovery (mirror of #5) ───────────
      # Same recovery procedure as openbao-infra: scale 3→1, delete PVCs
      # of pods 1+2, scale back. Expected count is 3 peers; anything less
      # means split-brain on pod-0's perspective.
      check_peers() {
        kubectl --kubeconfig=$KC -n secrets exec -i openbao-app-0 -c openbao -- \
          env BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true sh -c \
          "bao operator raft list-peers 2>/dev/null | grep -c '^node-' || echo 0" \
          2>/dev/null || echo 0
      }
      sleep 10
      PEERS=$(check_peers)
      echo "Initial raft peer count from pod-0 perspective: $PEERS"
      if [ "$PEERS" != "3" ]; then
        echo "RECOVERY: split-brain detected (peers=$PEERS, want=3). Wiping pods 1+2 PVCs."
        kubectl --kubeconfig=$KC -n secrets scale statefulset openbao-app --replicas=1
        # Wait for pods 1+2 to terminate before deleting PVCs
        for i in $(seq 1 30); do
          REM=$(kubectl --kubeconfig=$KC -n secrets get pods -l app.kubernetes.io/instance=openbao-app --no-headers 2>/dev/null | grep -c -E 'openbao-app-(1|2)' || echo 0)
          [ "$REM" = "0" ] && break
          sleep 5
        done
        # Delete PVCs (StatefulSet creates them as data-openbao-app-<idx>)
        kubectl --kubeconfig=$KC -n secrets delete pvc data-openbao-app-1 data-openbao-app-2 --ignore-not-found --wait=true --timeout=60s || true
        sleep 5
        echo "  Re-scaling to 3 with fresh raft state for pods 1+2"
        kubectl --kubeconfig=$KC -n secrets scale statefulset openbao-app --replicas=3
        kubectl --kubeconfig=$KC -n secrets wait pod openbao-app-1 openbao-app-2 --for=condition=Ready --timeout=240s || true
        sleep 15
        PEERS=$(check_peers)
        echo "Post-recovery raft peer count: $PEERS"
        if [ "$PEERS" != "3" ]; then
          echo "ERROR: raft still split-brain after recovery (peers=$PEERS). Manual intervention required."
          echo "  Inspect: kubectl --kubeconfig=$KC -n secrets exec openbao-app-0 -- bao operator raft list-peers"
          exit 1
        fi
      fi
      echo "OpenBao app raft healthy: 3 peers."
    EOT
  }

  depends_on = [helm_release.openbao_app]
}

# ─── cert-manager — automatic TLS from infra sub-CA ────────────────

resource "kubernetes_namespace" "cert_manager" {
  metadata {
    name = "cert-manager"
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
