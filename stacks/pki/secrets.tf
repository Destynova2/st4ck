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

# ─── Seed secrets into in-cluster OpenBao Infra ───────────────────────

resource "terraform_data" "seed_openbao_secrets" {
  depends_on = [helm_release.openbao_infra]

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
    }
    command = <<-EOT
      set -eu

      # OpenBao listener is HTTPS (cert-manager-provided cert via openbao-infra-tls).
      # BAO_SKIP_VERIFY because we're hitting 127.0.0.1 from inside the pod —
      # the cert is for the cluster-internal DNS name, not the loopback.
      BAO="kubectl -n secrets exec openbao-infra-0 -c openbao -- env BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true"

      echo "Waiting for OpenBao Infra API..."
      for i in $(seq 1 60); do
        $BAO bao status >/dev/null 2>&1 && break
        echo "  attempt $i/60..." && sleep 5
      done

      echo "Logging in..."
      $BAO bao login -method=userpass username=admin password="$BAO_ADMIN_PASSWORD" >/dev/null 2>&1 || \
        { echo "ERROR: OpenBao login failed"; exit 1; }

      # Idempotent: skip if already seeded
      if $BAO bao kv get secret/identity/hydra >/dev/null 2>&1; then
        echo "Secrets already seeded, skipping."
        exit 0
      fi

      echo "Seeding identity secrets..."
      $BAO bao kv put secret/identity/hydra \
        system_secret="$HYDRA_SYSTEM_SECRET"

      $BAO bao kv put secret/identity/pomerium \
        shared_secret="$POMERIUM_SHARED_SECRET" \
        cookie_secret="$POMERIUM_COOKIE_SECRET" \
        client_secret="$POMERIUM_CLIENT_SECRET"

      echo "Seeding storage secrets..."
      $BAO bao kv put secret/storage/garage \
        rpc_secret="$GARAGE_RPC_SECRET" \
        admin_token="$GARAGE_ADMIN_TOKEN"

      $BAO bao kv put secret/storage/harbor \
        admin_password="$HARBOR_ADMIN_PASSWORD"

      echo "OpenBao Infra seeded."
    EOT
  }
}

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
