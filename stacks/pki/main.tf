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

# Version pins come from the platform version registry (single source of
# truth shared with Flux postBuild.substituteFrom and the Hauler manifest):
# clusters/management/versions-configmap.yaml. Variables stay as optional
# overrides (default null).
locals {
  platform_versions = yamldecode(file("${path.module}/../../clusters/management/versions-configmap.yaml")).data
}

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
  version          = coalesce(var.openbao_version, local.platform_versions.openbao_version)
  namespace        = "secrets"
  create_namespace = false

  # The two-phase Make target bootstraps once, then records three in Helm.
  # OpenBao 2.x has a known race (issue #2274): when 3 pods come up
  # simultaneously, each tries retry_join, the headless service hasn't
  # registered the others yet (DNS NXDOMAIN), so each pod self-inits
  # its own 1-node cluster (split-brain). The chart's initialize {}
  # blocks fire per-pod with no per-ordinal gating — there's no chart
  # parameter to fix this. The canonical workaround per OpenBao docs
  # + 2026 OpenShift guide: deploy with replicas=1, let pod-0 form a
  # quorum-of-1 cluster, then scale to 3 — pods 1+2 retry_join an
  # already-established leader and become followers cleanly.
  # Local E2E 2026-09-26: delaying scale alone still splits the cluster.
  # Remove initialize{} from the configuration BEFORE adding followers
  # (OpenBao #3652). Only the first, single-node phase appends these blocks.
  values = [
    file("${path.module}/flux/values-openbao-infra.yaml"),
    yamlencode({
      server = {
        ha = {
          replicas = contains(var.openbao_bootstrap_releases, "openbao-infra") ? 1 : 3
          raft = {
            config = join("\n", [
              yamldecode(file("${path.module}/flux/values-openbao-infra.yaml")).server.ha.raft.config,
              contains(var.openbao_bootstrap_releases, "openbao-infra") ? file("${path.module}/bootstrap-openbao-infra.hcl") : "",
            ])
          }
        }
      }
    }),
  ]

  lifecycle {
    precondition {
      condition     = local.openbao_apply_allowed["openbao-infra"]
      error_message = "Unsafe OpenBao Infra phase. Use make k8s-pki-apply; never bootstrap existing HA/PVCs."
    }
  }

  depends_on = [
    kubernetes_namespace.secrets,
    kubernetes_secret.openbao_seal_key,
    kubernetes_secret.openbao_admin_password,
    kubectl_manifest.openbao_infra_cert,
  ]
}

# Verify bootstrap readiness or, in the second Helm phase, leader agreement.
# Health failures preserve PVCs and require an explicit recovery procedure.
resource "terraform_data" "openbao_infra_scale_to_ha" {
  triggers_replace = {
    helm_id   = helm_release.openbao_infra.id
    chart     = helm_release.openbao_infra.version
    values    = sha256(join("", helm_release.openbao_infra.values))
    check_sha = filesha256("${path.module}/../../scripts/check-openbao-ha.sh")
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      KC="${var.kubeconfig_path}"
      # Existing HA clusters may have any ordinal as leader.
      if [ "$(kubectl --kubeconfig="$KC" -n secrets get statefulset openbao-infra -o jsonpath='{.spec.replicas}')" = 3 ]; then
        KUBECONFIG="$KC" bash "${path.module}/../../scripts/check-openbao-ha.sh" openbao-infra
        exit 0
      fi
      echo "Waiting for openbao-infra-0 to be Ready, active leader, AND initialize blocks done…"
      # CRITICAL: must wait until ALL initialize {} blocks have materialized.
      # `bao status` returning 0 only means the API is up — it doesn't mean
      # initialize blocks have run. We check for the LAST initialize block's
      # output: the kubernetes auth method. Once that exists, all earlier
      # initialize blocks (kv, transit, ssh-ca, policies, approle) are done
      # too (initialize blocks run sequentially per OpenBao docs).
      # Without this check, pods 1+2 race with pod-0's init → split-brain.
      # Postmortem 2026-04-27 (#80).
      # Bug #32 fix (postmortem 2026-04-30 PHASE D.3): the previous probe
      # called `bao auth list` without auth → 403 → grep -c → 0 →
      # K8S_AUTH stays 0 → script hangs the full 7.5min then exits "not
      # ready" even though pod is actually fine. Login first using the
      # admin password baked into pod env (BAO_ADMIN_PASSWORD).
      K8S_AUTH=0
      for i in $(seq 1 90); do
        READY=$(kubectl --kubeconfig=$KC -n secrets get pod openbao-infra-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)
        if [ "$READY" = "true" ]; then
          K8S_AUTH=$(kubectl --kubeconfig=$KC -n secrets exec -i openbao-infra-0 -c openbao -- env BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true sh -c "
            bao login -method=userpass username=admin password=\$BAO_ADMIN_PASSWORD >/dev/null 2>&1 && bao auth list 2>/dev/null | grep -c '^kubernetes/'
          " 2>/dev/null || echo 0)
          if [ "$K8S_AUTH" = "1" ]; then
            echo "  pod-0 ready + initialize blocks done (attempt $i)"
            break
          fi
        fi
        sleep 5
      done
      # Postmortem 2026-04-29 (#13): hard-exit if loop expired without
      # confirming the kubernetes-auth gate. Previously the loop fell
      # through silently → unconditional scale to 3 → exact split-brain
      # that fix #5 was designed to recover from. Surface the real
      # readiness failure instead of papering over it (recovery adds
      # latency + fragility; better to fail fast at apply time).
      if [ "$K8S_AUTH" != "1" ]; then
        echo "ERROR: openbao-infra-0 not ready after 7.5min — aborting before scale to prevent split-brain"
        exit 1
      fi
      # The next Helm apply removes initialize{} before adding followers.
      # A kubectl scale here would give each follower self-init configuration.
      echo "Single-node initialization complete; ready for the join-only Helm phase."
    EOT
  }

  depends_on = [helm_release.openbao_infra]
}

# ─── OpenBao App — application secrets ─────────────────────────────

resource "helm_release" "openbao_app" {
  name             = "openbao-app"
  repository       = "https://openbao.github.io/openbao-helm"
  chart            = "openbao"
  version          = coalesce(var.openbao_version, local.platform_versions.openbao_version)
  namespace        = "secrets"
  create_namespace = false

  # Bootstrap is an explicit first phase; day-2 Helm always owns three replicas.
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
          replicas = contains(var.openbao_bootstrap_releases, "openbao-app") ? 1 : 3
          raft = {
            config = join("\n", [
              yamldecode(file("${path.module}/flux/values-openbao-app.yaml")).server.ha.raft.config,
              contains(var.openbao_bootstrap_releases, "openbao-app") ? file("${path.module}/bootstrap-openbao-app.hcl") : "",
            ])
          }
        }
      }
    }),
  ]

  lifecycle {
    precondition {
      condition     = local.openbao_apply_allowed["openbao-app"]
      error_message = "Unsafe OpenBao App phase. Use make k8s-pki-apply; never bootstrap existing HA/PVCs."
    }
  }

  depends_on = [
    kubernetes_namespace.secrets,
    kubernetes_secret.openbao_seal_key,
    kubectl_manifest.openbao_app_cert,
  ]
}

# Same bootstrap and non-destructive verification as OpenBao Infra.
resource "terraform_data" "openbao_app_scale_to_ha" {
  triggers_replace = {
    helm_id   = helm_release.openbao_app.id
    chart     = helm_release.openbao_app.version
    values    = sha256(join("", helm_release.openbao_app.values))
    check_sha = filesha256("${path.module}/../../scripts/check-openbao-ha.sh")
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      KC="${var.kubeconfig_path}"
      if [ "$(kubectl --kubeconfig="$KC" -n secrets get statefulset openbao-app -o jsonpath='{.spec.replicas}')" = 3 ]; then
        KUBECONFIG="$KC" bash "${path.module}/../../scripts/check-openbao-ha.sh" openbao-app
        exit 0
      fi
      echo "Waiting for openbao-app-0 to be Ready, active leader, AND initialize blocks done…"
      # CRITICAL: wait until ALL initialize {} blocks have materialized.
      # openbao-app's only initialize block mounts secret/ as KV v2.
      # Postmortem 2026-04-29 (#22, Phase C resume): the previous probe
      # used `bao secrets list | grep ^secret/` which requires auth, but
      # openbao-app has NO userpass admin enabled (only openbao-infra does
      # — see secrets.tf seed). Loop hung at 0 forever → exit 1.
      # Auth-free probe: `bao status -format=json` returns initialized=true
      # once the initialize{} block ran, regardless of seal/auth state.
      # Same pattern as openbao_infra_scale_to_ha (postmortem 2026-04-27).
      INIT=0
      for i in $(seq 1 90); do
        READY=$(kubectl --kubeconfig=$KC -n secrets get pod openbao-app-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)
        if [ "$READY" = "true" ]; then
          INIT=$(kubectl --kubeconfig=$KC -n secrets exec -i openbao-app-0 -c openbao -- env BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true sh -c "bao status -format=json 2>/dev/null | grep -c '\"initialized\": true'" 2>/dev/null || echo 0)
          if [ "$INIT" = "1" ]; then
            echo "  pod-0 ready + initialized=true (attempt $i)"
            break
          fi
        fi
        sleep 5
      done
      if [ "$INIT" != "1" ]; then
        echo "ERROR: openbao-app-0 not initialized after 7.5min — aborting before scale to prevent split-brain"
        exit 1
      fi
      echo "Single-node initialization complete; ready for the join-only Helm phase."
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
  version          = coalesce(var.cert_manager_version, local.platform_versions.cert_manager_version)
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
    # PSA labels: tofu is the sole owner of this namespace (the former
    # Flux-owned stacks/external-secrets/flux/ was purged 2026-07-12).
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
  version          = coalesce(var.external_secrets_version, local.platform_versions.external_secrets_version)
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

# ─── TokenRequest RBAC for the Vault issuer ──────────────────────────
# cert-manager's Vault auth mints a token FOR the referenced SA via the
# TokenRequest API — without this Role the issuer fails with
# `serviceaccounts "cert-manager" is forbidden` and every Certificate
# behind internal-ca stalls (identity chain incl. CNPG — golden-path
# finding 2026-07-16, keystone of the whole identity dependency tree).
resource "kubectl_manifest" "cert_manager_tokenrequest_role" {
  yaml_body = <<-YAML
    apiVersion: rbac.authorization.k8s.io/v1
    kind: Role
    metadata:
      name: cert-manager-tokenrequest
      namespace: cert-manager
    rules:
      - apiGroups: [""]
        resources: ["serviceaccounts/token"]
        resourceNames: ["cert-manager"]
        verbs: ["create"]
  YAML

  depends_on = [helm_release.cert_manager]
}

resource "kubectl_manifest" "cert_manager_tokenrequest_binding" {
  yaml_body = <<-YAML
    apiVersion: rbac.authorization.k8s.io/v1
    kind: RoleBinding
    metadata:
      name: cert-manager-tokenrequest
      namespace: cert-manager
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: Role
      name: cert-manager-tokenrequest
    subjects:
      - kind: ServiceAccount
        name: cert-manager
        namespace: cert-manager
  YAML

  depends_on = [kubectl_manifest.cert_manager_tokenrequest_role]
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
