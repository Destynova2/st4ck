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

# ─── OpenBao PKI engine bootstrap (Phase 1b-1) ────────────────────────
#
# Mounts pki/ (root) and pki_int/ (intermediate) on OpenBao Infra and
# pre-creates the `cluster-issuer` role + cert-manager Kubernetes auth
# binding. Idempotent: every step guarded by a `bao read` probe so
# re-applies are no-ops.
#
# Why HERE and not in a separate terraform_data: this MUST run after
# helm_release.openbao_infra and after the seal+admin login is wired,
# but BEFORE cert-manager tries to use the Vault Issuer (which lives
# in flux/cluster-issuer.yaml, applied via kubectl_manifest.cluster_issuer
# below). The depends_on chain enforces the order.
#
# CA private keys NEVER leave OpenBao — generation uses
# `pki/root/generate/internal` which keeps the key inside the engine.
# Only the public certificate is emitted.

resource "terraform_data" "bootstrap_openbao_pki" {
  depends_on = [
    helm_release.openbao_infra,
    terraform_data.seed_openbao_secrets,
  ]

  # Re-run on admin password change only — PKI bootstrap itself is
  # purely idempotent against OpenBao state, so any other input would
  # cause unnecessary re-execution. Keep the input small and stable.
  input = sha256(random_password.openbao_admin.result)

  provisioner "local-exec" {
    environment = {
      KUBECONFIG         = var.kubeconfig_path
      BAO_ADMIN_PASSWORD = random_password.openbao_admin.result
    }
    command = <<-EOT
      set -eu

      # `-i` is required so heredoc stdin (bao policy write -) reaches the pod.
      BAO="kubectl -n secrets exec -i openbao-infra-0 -c openbao -- env BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true"

      # ─── Wait for OpenBao Infra API (Pattern 1: 1s polling) ──────────
      # Same pattern as seed_openbao_secrets above — see the comment
      # there for rationale. Phase F-bis: 60×sleep 5 → 300×sleep 1.
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

      echo "Logging in as admin..."
      $BAO bao login -method=userpass username=admin password="$BAO_ADMIN_PASSWORD" >/dev/null 2>&1 || \
        { echo "ERROR: OpenBao login failed"; exit 1; }

      # ─── 1. Enable pki + pki_int mounts ──────────────────────────
      echo "Enabling pki/ mount (10y max-lease)..."
      $BAO bao secrets enable -path=pki -max-lease-ttl=87600h pki 2>&1 | grep -v "path is already in use" || true

      echo "Enabling pki_int/ mount (5y max-lease)..."
      $BAO bao secrets enable -path=pki_int -max-lease-ttl=43800h pki 2>&1 | grep -v "path is already in use" || true

      # ─── 2. Generate root CA (idempotent) ────────────────────────
      # `bao read pki/cert/ca` returns "no certificate" stderr + exit 2
      # when unset; once generated it returns the PEM with exit 0.
      echo "Checking for existing root CA..."
      if $BAO bao read pki/cert/ca 2>&1 | grep -q -- "-----BEGIN CERTIFICATE-----"; then
        echo "  root CA already present, skipping generation"
      else
        echo "  generating root CA (EC P-384, 10y)..."
        $BAO bao write -field=certificate pki/root/generate/internal \
          common_name="st4ck-platform-root" \
          issuer_name="st4ck-platform-root" \
          ttl=87600h key_type=ec key_bits=384 >/dev/null
      fi

      # ─── 3. Generate + sign intermediate (idempotent) ────────────
      echo "Checking for existing intermediate CA..."
      if $BAO bao read pki_int/cert/ca 2>&1 | grep -q -- "-----BEGIN CERTIFICATE-----"; then
        echo "  intermediate CA already present, skipping generation"
      else
        echo "  generating intermediate CSR (EC P-384)..."
        CSR=$($BAO bao write -field=csr pki_int/intermediate/generate/internal \
              common_name="st4ck-platform-intermediate" key_type=ec key_bits=384)
        echo "  signing intermediate with root (5y)..."
        CERT=$($BAO bao write -field=certificate pki/root/sign-intermediate \
              csr="$CSR" format=pem_bundle ttl=43800h)
        echo "  uploading signed intermediate..."
        $BAO bao write pki_int/intermediate/set-signed certificate="$CERT" >/dev/null
      fi

      # ─── 4. Issuer URLs (CRL/OCSP discovery) ─────────────────────
      # Always (re)write — cheap and ensures URLs match the current
      # OpenBao service DNS even if a previous bootstrap used a stale name.
      echo "Configuring issuer URLs..."
      $BAO bao write pki_int/config/urls \
        issuing_certificates="https://openbao-infra.secrets.svc.cluster.local:8200/v1/pki_int/ca" \
        crl_distribution_points="https://openbao-infra.secrets.svc.cluster.local:8200/v1/pki_int/crl" >/dev/null

      # ─── 5. cert-manager role on pki_int ─────────────────────────
      # allow_any_name=true: cert-manager Issuer requests carry CN/SAN
      # validated by the cert-manager Certificate CR itself, not the role.
      # max_ttl=35040h (4y) — covers CNPG + identity-pg CA Certificates
      # which spec duration=87600h (10y). PKI truncates to max_ttl, but
      # cert-manager computes renewalTime from ACTUAL notAfter, so as long
      # as max_ttl >> renewBefore (here 720h), no renewal storm. Headroom
      # is bounded by pki_int issuer validity (5y from bootstrap).
      echo "Writing pki_int/roles/cluster-issuer..."
      # key_type=ec + key_bits=0: only ECDSA keys (any curve P-256/P-384).
      # All Certificate CRs in this repo use ECDSA (matches root + intermediate
      # which are ECDSA-P384). Default key_type=rsa would reject them with
      # "role requires keys of type rsa". Locking to EC is more secure than
      # key_type=any (refuses RSA + Ed25519 leaks).
      $BAO bao write pki_int/roles/cluster-issuer \
        allow_any_name=true \
        enforce_hostnames=false \
        max_ttl=35040h \
        key_type=ec \
        key_bits=0 \
        allowed_uri_sans="spiffe://st4ck/*" >/dev/null

      # ─── 5b. Cilium-specific PKI role (RSA tolerated) ────────────
      # Cilium's hubble.tls.auto helm chart hardcodes RSA-2048 private
      # keys for the auto-generated Certificate CRs (no override
      # exposed). The strict cluster-issuer role above rejects RSA, so
      # we add a SECOND role that accepts any key type, scoped narrowly
      # to *.hubble-grpc.cilium.io CNs only — this isolates the RSA
      # exception to Cilium and keeps every other Certificate strict EC.
      # Used by the cilium-issuer ClusterIssuer (stacks/pki/main.tf).
      echo "Writing pki_int/roles/cilium-hubble..."
      # Two CN suffixes used by Cilium hubble.tls.auto:
      #   *.hubble-grpc.cilium.io   ← hubble-server-certs (peer.svc gRPC)
      #   *.hubble-relay.cilium.io  ← hubble-relay-client-certs
      # CN allowlist scoped to these — strict enough that this role
      # can't be misused for arbitrary cluster TLS.
      $BAO bao write pki_int/roles/cilium-hubble \
        allowed_domains="hubble-grpc.cilium.io,hubble-relay.cilium.io" \
        allow_subdomains=true \
        allow_glob_domains=true \
        enforce_hostnames=false \
        max_ttl=26280h \
        key_type=any \
        key_bits=0 >/dev/null

      # ─── 6. cert-manager Kubernetes auth role + policy ───────────
      # Kubernetes auth method may already be enabled by another
      # bootstrap step (ESO uses it too) — silence "already in use".
      echo "Ensuring auth/kubernetes is enabled..."
      # Idempotent: any HTTP 400 (already enabled, path conflict) is fine.
      # Only abort if the auth method genuinely can't be queried after.
      $BAO bao auth enable kubernetes 2>&1 || echo "  auth/kubernetes already enabled (or precondition failed — verifying below)"
      $BAO bao auth list -format=json 2>&1 | grep -q '"kubernetes/"' || { echo "ERROR: auth/kubernetes not present"; exit 1; }

      # If kubernetes auth was just enabled it needs the cluster's CA +
      # K8s API URL configured. ESO bootstrap (auto-init Job) normally
      # does this; reapply here defensively (idempotent — same values).
      echo "Configuring auth/kubernetes..."
      $BAO bao write auth/kubernetes/config \
        kubernetes_host="https://kubernetes.default.svc:443" \
        disable_local_ca_jwt=false 2>&1 | tail -1 || true

      echo "Writing cert-manager policy..."
      $BAO bao policy write cert-manager - <<'EOF'
path "pki_int/sign/cluster-issuer" {
  capabilities = ["update"]
}
path "pki_int/issue/cluster-issuer" {
  capabilities = ["update"]
}
# ADR-028 wave 4 — Cilium hubble certs use a separate PKI role
# (cilium-hubble) because the Cilium chart hardcodes RSA-2048 (no
# privateKey override exposed) and our main cluster-issuer enforces
# key_type=ec. Same policy because cert-manager is the same client.
path "pki_int/sign/cilium-hubble" {
  capabilities = ["update"]
}
path "pki_int/issue/cilium-hubble" {
  capabilities = ["update"]
}
EOF

      echo "Binding cert-manager SA → cert-manager policy..."
      $BAO bao write auth/kubernetes/role/cert-manager \
        bound_service_account_names=cert-manager \
        bound_service_account_namespaces=cert-manager \
        policies=cert-manager ttl=24h >/dev/null

      echo "OpenBao PKI engine bootstrapped."
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
