# ═══════════════════════════════════════════════════════════════════════
# Application secrets — generated here, seeded into in-cluster OpenBao Infra.
# Downstream stacks read via terraform_remote_state.
# ESO syncs from OpenBao Infra → K8s Secrets for Flux day-2.
# ═══════════════════════════════════════════════════════════════════════

# ─── Identity secrets ──────────────────────────────────────────────────

# IDEMPOTENCY: every secret below has lifecycle.ignore_changes=all so a
# state-loss + re-apply doesn't silently rotate them. Postmortem 2026-04-26
# (random_bytes.bao_seal_key for context). Rotating any of these MUST be
# a deliberate `tofu state rm <addr> && tofu apply`. The `keepers` block
# is kept where present as belt-and-suspenders but is no longer the
# primary defense.

resource "random_password" "hydra_system_secret" {
  length  = 64
  special = false

  # Pre-existing keeper (kept as a hint that namespace-pinning was the
  # intent before lifecycle was added — harmless now that ignore_changes
  # blocks rotation entirely).
  keepers = {
    namespace = "identity"
  }

  lifecycle {
    ignore_changes = all
  }
}

resource "random_password" "pomerium_client_secret" {
  length  = 64
  special = false

  lifecycle {
    ignore_changes = all
  }
}

resource "random_password" "oidc_client_secret" {
  length  = 64
  special = false

  lifecycle {
    ignore_changes = all
  }
}

resource "random_bytes" "pomerium_shared_secret" {
  length = 32

  lifecycle {
    ignore_changes = all
  }
}

resource "random_bytes" "pomerium_cookie_secret" {
  length = 32

  lifecycle {
    ignore_changes = all
  }
}

# ─── Storage secrets ──────────────────────────────────────────────────

resource "random_bytes" "garage_rpc_secret" {
  length = 32

  lifecycle {
    ignore_changes = all
  }
}

resource "random_password" "garage_admin_token" {
  length  = 64
  special = false

  lifecycle {
    ignore_changes = all
  }
}

resource "random_password" "harbor_admin_password" {
  length  = 24
  special = false

  lifecycle {
    ignore_changes = all
  }
}

# ─── Security secrets ──────────────────────────────────────────────────

# Cosign keypair (image signing). Generation moved here from
# stacks/security/main.tf (Phase 1a-1) so the keypair lives in OpenBao
# alongside every other application secret. Security stack now reads
# cosign.{pub,key} via ExternalSecret (see flux/external-secret-cosign.yaml).
#
# Rotation invalidates every existing image signature → Kyverno enforce
# blocks all pods → cluster-wide outage. Lock it down with ignore_changes.
resource "tls_private_key" "cosign" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"

  lifecycle {
    ignore_changes = all
  }
}

# ─── Seed secrets into in-cluster OpenBao Infra ───────────────────────

resource "terraform_data" "seed_openbao_secrets" {
  depends_on = [helm_release.openbao_infra]

  # Trigger re-execution if any source secret material changes. Cosign
  # additions are deliberately NOT in the input hash: ignore_changes = all
  # locks them, so they only flip on a state-loss reseed (which we want to
  # detect via the `bao kv get` idempotency guards below, not a hash diff).
  input = sha256(join(",", [
    random_password.hydra_system_secret.result,
    random_password.garage_admin_token.result,
  ]))

  provisioner "local-exec" {
    environment = {
      KUBECONFIG             = var.kubeconfig_path
      BAO_ADMIN_PASSWORD     = random_password.openbao_admin.result
      HYDRA_SYSTEM_SECRET    = random_password.hydra_system_secret.result
      POMERIUM_SHARED_SECRET = random_bytes.pomerium_shared_secret.base64
      POMERIUM_COOKIE_SECRET = random_bytes.pomerium_cookie_secret.base64
      POMERIUM_CLIENT_SECRET = random_password.pomerium_client_secret.result
      OIDC_CLIENT_SECRET     = random_password.oidc_client_secret.result
      GARAGE_RPC_SECRET      = random_bytes.garage_rpc_secret.hex
      GARAGE_ADMIN_TOKEN     = random_password.garage_admin_token.result
      HARBOR_ADMIN_PASSWORD  = random_password.harbor_admin_password.result
      # Cosign keypair (Phase 1a-1). PEMs go through env vars, never on
      # the kubectl exec command line where they'd hit ps + audit logs.
      COSIGN_PUB = tls_private_key.cosign.public_key_pem
      COSIGN_KEY = tls_private_key.cosign.private_key_pem
    }
    command = <<-EOT
      set -eu

      # OpenBao listener is HTTPS (cert-manager-provided cert via openbao-infra-tls).
      # BAO_SKIP_VERIFY because we're hitting 127.0.0.1 from inside the pod —
      # the cert is for the cluster-internal DNS name, not the loopback.
      # `-i` is required so heredoc stdin (bao policy write -) reaches the pod.
      BAO="kubectl -n secrets exec -i openbao-infra-0 -c openbao -- env BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true"

      # ─── Wait for OpenBao Infra API (Pattern 1: 1s polling) ──────────
      # Phase F-bis: 60×sleep 5 (max 5min) → 300×sleep 1 (max 5min) with
      # ~typical detect 2-3s vs old 5-10s. `kubectl exec` roundtrip is
      # the dominant cost (~150-300ms) so dropping sleep to 1s gives a
      # ~3-5× speedup on warm cluster — important on Bug #32 recovery
      # path where this loop runs multiple times during pki re-apply.
      # Explicit timeout exit instead of fall-through to `bao login`
      # which surfaced opaque "connection refused" before.
      echo "Waiting for OpenBao Infra API..."
      ready=0
      for i in $(seq 1 300); do
        if $BAO bao status >/dev/null 2>&1; then
          echo "  OpenBao ready after $${i}s"
          ready=1
          break
        fi
        sleep 1
      done
      if [ "$ready" -ne 1 ]; then
        echo "ERROR: OpenBao Infra API not reachable after 300s" >&2
        exit 1
      fi

      echo "Logging in..."
      $BAO bao login -method=userpass username=admin password="$BAO_ADMIN_PASSWORD" >/dev/null 2>&1 || \
        { echo "ERROR: OpenBao login failed"; exit 1; }

      # Per-path idempotency: each block skips if already seeded. This
      # used to be a single guard on secret/identity/hydra but new paths
      # added later (cosign, Phase 1a-1) would be skipped on re-runs,
      # leaving downstream ExternalSecrets stuck waiting forever.
      seed_if_absent() {
        local path="$1"; shift
        if $BAO bao kv get "$path" >/dev/null 2>&1; then
          echo "  $path: already present, skipping"
          return 0
        fi
        echo "  $path: seeding"
        $BAO bao kv put "$path" "$@"
      }

      echo "Seeding identity secrets..."
      seed_if_absent secret/identity/hydra \
        system_secret="$HYDRA_SYSTEM_SECRET"

      seed_if_absent secret/identity/pomerium \
        shared_secret="$POMERIUM_SHARED_SECRET" \
        cookie_secret="$POMERIUM_COOKIE_SECRET" \
        client_secret="$POMERIUM_CLIENT_SECRET"

      echo "Seeding storage secrets..."
      seed_if_absent secret/storage/garage \
        rpc_secret="$GARAGE_RPC_SECRET" \
        admin_token="$GARAGE_ADMIN_TOKEN"

      seed_if_absent secret/storage/harbor \
        admin_password="$HARBOR_ADMIN_PASSWORD"

      echo "Seeding security secrets..."
      # Cosign keypair: Kyverno verifyImages reads cosign-public-key from
      # the security namespace — backed by ExternalSecret targeting this
      # path. Private key kept in the same KV entry so a single ES sync
      # populates both Secrets without two round-trips.
      seed_if_absent secret/security/cosign \
        cosign.pub="$COSIGN_PUB" \
        cosign.key="$COSIGN_KEY"

      echo "OpenBao Infra seeded."
    EOT
  }
}

# ─── OpenBao PKI engine bootstrap ─────────────────────────────────────
#
# Phase F-bis-2 v3 (2026-04-30): logic MOVED to a Helm post-install Job
# at `stacks/pki/flux/job-bootstrap-openbao-pki.yaml` (see ADR-032).
#
# The resource is kept here as a no-op `terraform_data` so the existing
# `depends_on = [terraform_data.bootstrap_openbao_pki]` chains in
# `main.tf` (cluster_secret_store, cluster_issuer_vault,
# cluster_issuer_cilium) keep resolving without YAML edits across the
# stack. The provisioner now just echoes a one-liner and exits 0.
#
# Why a no-op shim instead of full removal:
#   - The Helm Job runs INSIDE the cluster after `helm install` of
#     openbao-infra. Removing this resource would also need to remove
#     the depends_on edges in main.tf (Agent #10's territory this
#     session), which would deadlock the Tofu DAG ordering: the Vault
#     ClusterIssuer and ClusterSecretStore need pki_int/ + cert-manager
#     auth role to exist before cert-manager hits them. The Helm Job
#     guarantees that — but Tofu can't observe the Job's completion
#     without a `kubernetes_job` data source + wait, which adds 30s of
#     extra polling to every plan. Keeping the no-op shim means the
#     Tofu DAG still has a serialization point (this resource) that
#     downstream resources depend on, even though the actual work
#     happens out-of-band via Flux/Helm.
#
# Migration to definitive removal (planned, post-validation):
#   1. Verify Helm Job runs successfully on a fresh cluster bootstrap.
#   2. Replace the depends_on edges in main.tf with `time_sleep` (~60s)
#      OR a `kubernetes_job` data source with wait_for_completion.
#   3. Delete this entire resource block.
#   4. `tofu state rm 'terraform_data.bootstrap_openbao_pki'` on every
#      existing cluster to drop the old state entry.
#
# The original ~180-LOC bash provisioner is preserved in git history
# (commit before this refactor) — restore via `git show <prev>:stacks/
# pki/secrets.tf` if rollback is needed.
#
# Original behavior (pre-Phase F-bis-2 v3):
#   - Mount pki/ (10y) + pki_int/ (5y) on OpenBao Infra
#   - Generate root CA INSIDE the cluster (duplicated VM root!)
#   - Generate intermediate CSR, sign with cluster root
#   - Configure issuer URLs (CRL/OCSP)
#   - Create roles: cluster-issuer (EC strict), cilium-hubble (any key)
#   - Enable auth/kubernetes, write cert-manager policy + role binding
#
# New behavior (Helm Job):
#   - Skip pki/ mount entirely (no cluster root — VM owns it)
#   - Mount pki_int/ only
#   - Same roles + auth as before
#   - Intermediate CA loading deferred to follow-up (see Job comments)

resource "terraform_data" "bootstrap_openbao_pki" {
  depends_on = [
    helm_release.openbao_infra,
    terraform_data.seed_openbao_secrets,
  ]

  # No re-run trigger needed — the resource is a pure no-op shim.
  # Static input so the resource is created once and never re-runs.
  input = "phase-f-bis-2-v3-noop-shim"

  provisioner "local-exec" {
    command = <<-EOT
      echo "[Phase F-bis-2 v3] terraform_data.bootstrap_openbao_pki is now a no-op shim."
      echo "[Phase F-bis-2 v3] PKI engine bootstrap moved to Helm post-install Job:"
      echo "[Phase F-bis-2 v3]   stacks/pki/flux/job-bootstrap-openbao-pki.yaml"
      echo "[Phase F-bis-2 v3] See ADR-032 for the full migration rationale."
    EOT
  }
}

# ─── Outputs for downstream stacks (Vault Issuer caBundle) ────────────
#
# `pki_int_ca_pem` is the intermediate CA bundle (intermediate + root)
# that any client validating an OpenBao-PKI-issued leaf needs as trust
# anchor. The cert-manager Vault Issuer's caBundle field uses this to
# verify OpenBao's TLS endpoint cert.
#
# We DON'T fetch it from OpenBao here (that would require a vault
# provider and create a chicken-and-egg with the bootstrap step).
# Instead, the bootstrap_openbao_pki provisioner above guarantees the
# CA is present, and the Vault Issuer YAML in flux/cluster-issuer.yaml
# documents how to populate caBundle (see comments there).

# ─── Outputs (consumed by identity + storage via remote_state) ────────

output "hydra_system_secret" {
  value     = random_password.hydra_system_secret.result
  sensitive = true
}

output "pomerium_shared_secret" {
  value     = random_bytes.pomerium_shared_secret.base64
  sensitive = true
}

output "pomerium_cookie_secret" {
  value     = random_bytes.pomerium_cookie_secret.base64
  sensitive = true
}

output "pomerium_client_secret" {
  value     = random_password.pomerium_client_secret.result
  sensitive = true
}

output "oidc_client_secret" {
  value     = random_password.oidc_client_secret.result
  sensitive = true
}

output "garage_rpc_secret" {
  value     = random_bytes.garage_rpc_secret.hex
  sensitive = true
}

output "garage_admin_token" {
  value     = random_password.garage_admin_token.result
  sensitive = true
}

output "harbor_admin_password" {
  value     = random_password.harbor_admin_password.result
  sensitive = true
}
