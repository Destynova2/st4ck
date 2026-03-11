#!/usr/bin/env bash
# Initialize and unseal OpenBao instances running in the cluster.
#
# This runs AFTER `make k8s-pki-apply` deploys the Helm charts.
# Uses 1 key share / 1 threshold for POC simplicity.
#
# Outputs (appended to kms-output/):
#   openbao-infra-token.txt   — Infra instance root token
#   openbao-infra-unseal.txt  — Infra unseal key
#   openbao-app-token.txt     — App instance root token
#   openbao-app-unseal.txt    — App unseal key
#
# Usage: KUBECONFIG=~/.kube/talos-scaleway bash scripts/openbao-cluster-init.sh
set -euo pipefail

OUTDIR="${1:-./kms-output}"
NAMESPACE="secrets"
KC="${KUBECONFIG:-$HOME/.kube/talos-scaleway}"

mkdir -p "$OUTDIR"

init_and_unseal() {
  local name="$1" pod="$2"

  echo "=== Initializing $name ==="

  # Wait for pod to be running
  echo -n "  Waiting for pod $pod"
  for i in $(seq 1 60); do
    local phase
    phase=$(kubectl --kubeconfig "$KC" -n "$NAMESPACE" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
    if [ "$phase" = "Running" ]; then
      echo " ready"
      break
    fi
    echo -n "."
    sleep 5
  done

  # Check if already initialized
  local status
  status=$(kubectl --kubeconfig "$KC" -n "$NAMESPACE" exec "$pod" -- bao status -format=json 2>/dev/null || echo '{"initialized":false,"sealed":true}')
  local initialized
  initialized=$(echo "$status" | jq -r '.initialized')

  if [ "$initialized" = "true" ]; then
    echo "  $name already initialized"
    # Try to unseal if sealed
    local sealed
    sealed=$(echo "$status" | jq -r '.sealed')
    if [ "$sealed" = "true" ] && [ -f "$OUTDIR/${name}-unseal.txt" ]; then
      echo "  Unsealing $name..."
      kubectl --kubeconfig "$KC" -n "$NAMESPACE" exec "$pod" -- \
        bao operator unseal "$(cat "$OUTDIR/${name}-unseal.txt")" > /dev/null
      echo "  $name unsealed"
    fi
    return 0
  fi

  # Initialize with 1 key share (POC — production uses 3/5 with Shamir)
  local init_result
  init_result=$(kubectl --kubeconfig "$KC" -n "$NAMESPACE" exec "$pod" -- \
    bao operator init -key-shares=1 -key-threshold=1 -format=json)

  local root_token unseal_key
  root_token=$(echo "$init_result" | jq -r '.root_token')
  unseal_key=$(echo "$init_result" | jq -r '.unseal_keys_b64[0]')

  echo "$root_token" > "$OUTDIR/${name}-token.txt"
  echo "$unseal_key" > "$OUTDIR/${name}-unseal.txt"
  echo "  Root token saved to $OUTDIR/${name}-token.txt"

  # Unseal
  kubectl --kubeconfig "$KC" -n "$NAMESPACE" exec "$pod" -- \
    bao operator unseal "$unseal_key" > /dev/null
  echo "  $name initialized and unsealed"
}

init_and_unseal "openbao-infra" "openbao-infra-0"
init_and_unseal "openbao-app" "openbao-app-0"

# ─── Enable Transit secret engine (for OpenTofu state encryption) ────
enable_transit() {
  local name="$1" pod="$2"
  local token
  token=$(cat "$OUTDIR/${name}-token.txt" 2>/dev/null || echo "")

  if [ -z "$token" ]; then
    echo "  Skipping Transit for $name (no token found)"
    return 0
  fi

  # Check if Transit is already enabled
  local engines
  engines=$(kubectl --kubeconfig "$KC" -n "$NAMESPACE" exec "$pod" -- \
    env "BAO_TOKEN=$token" bao secrets list -format=json 2>/dev/null || echo '{}')

  if echo "$engines" | jq -e '."transit/"' > /dev/null 2>&1; then
    echo "  Transit engine already enabled on $name"
  else
    echo "  Enabling Transit engine on $name..."
    kubectl --kubeconfig "$KC" -n "$NAMESPACE" exec "$pod" -- \
      env "BAO_TOKEN=$token" bao secrets enable transit
  fi

  # Create state-encryption key (aes256-gcm96) if not exists
  local key_exists
  key_exists=$(kubectl --kubeconfig "$KC" -n "$NAMESPACE" exec "$pod" -- \
    env "BAO_TOKEN=$token" bao read -format=json transit/keys/state-encryption 2>/dev/null || echo "")

  if [ -z "$key_exists" ]; then
    echo "  Creating Transit key 'state-encryption' on $name..."
    kubectl --kubeconfig "$KC" -n "$NAMESPACE" exec "$pod" -- \
      env "BAO_TOKEN=$token" bao write -f transit/keys/state-encryption type=aes256-gcm96
  else
    echo "  Transit key 'state-encryption' already exists on $name"
  fi
}

echo ""
echo "=== Configuring Transit secret engine ==="
enable_transit "openbao-infra" "openbao-infra-0"

# ─── SSH secrets engine (for Flux signed certs) ──────────────────────
configure_ssh_ca() {
  local pod="openbao-infra-0"
  local token
  token=$(cat "$OUTDIR/openbao-infra-token.txt" 2>/dev/null || echo "")
  [ -z "$token" ] && { echo "  Skipping SSH CA (no infra token)"; return 0; }

  local BAO="kubectl --kubeconfig $KC -n $NAMESPACE exec $pod -- env BAO_TOKEN=$token"

  local engines
  engines=$($BAO bao secrets list -format=json 2>/dev/null || echo '{}')

  if echo "$engines" | jq -e '."ssh-client-signer/"' > /dev/null 2>&1; then
    echo "  SSH CA engine already enabled"
  else
    echo "  Enabling SSH secrets engine (ssh-client-signer)..."
    $BAO bao secrets enable -path=ssh-client-signer ssh
    $BAO bao write ssh-client-signer/config/ca generate_signing_key=true
    echo "  SSH CA key pair generated"
  fi

  # Create signing role for Flux (TTL 2h, max 24h)
  $BAO bao write ssh-client-signer/roles/flux \
    key_type=ca \
    allowed_users="flux" \
    default_user="flux" \
    ttl=2h \
    max_ttl=24h \
    allow_user_certificates=true \
    algorithm_signer=rsa-sha2-256 2>/dev/null || true
  echo "  SSH role 'flux' configured (TTL 2h)"

  # Export CA public key (for Gitea TrustedUserCAKeys)
  $BAO bao read -field=public_key ssh-client-signer/config/ca > "$OUTDIR/ssh-ca-public-key.pub" 2>/dev/null
  echo "  SSH CA public key saved to $OUTDIR/ssh-ca-public-key.pub"
  echo "  → Add this to Gitea app.ini: SSH_TRUSTED_USER_CA_KEYS=$(cat "$OUTDIR/ssh-ca-public-key.pub")"
}

echo ""
echo "=== Configuring SSH CA for Flux ==="
configure_ssh_ca

# ─── Kubernetes auth method (for agent injector) ─────────────────────
configure_k8s_auth() {
  local pod="openbao-infra-0"
  local token
  token=$(cat "$OUTDIR/openbao-infra-token.txt" 2>/dev/null || echo "")
  [ -z "$token" ] && { echo "  Skipping K8s auth (no infra token)"; return 0; }

  local BAO="kubectl --kubeconfig $KC -n $NAMESPACE exec $pod -- env BAO_TOKEN=$token"

  local auth_methods
  auth_methods=$($BAO bao auth list -format=json 2>/dev/null || echo '{}')

  if echo "$auth_methods" | jq -e '."kubernetes/"' > /dev/null 2>&1; then
    echo "  Kubernetes auth already enabled"
  else
    echo "  Enabling Kubernetes auth method..."
    $BAO bao auth enable kubernetes
  fi

  # Configure K8s auth to use in-cluster service account
  $BAO bao write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc" 2>/dev/null
  echo "  Kubernetes auth configured"

  # Policy for SSH signing
  kubectl --kubeconfig "$KC" -n "$NAMESPACE" exec "$pod" -- \
    sh -c "echo 'path \"ssh-client-signer/sign/flux\" { capabilities = [\"create\", \"update\"] }' | BAO_TOKEN=$token bao policy write flux-ssh -"
  echo "  Policy 'flux-ssh' written"

  # Role for Flux source-controller service account
  $BAO bao write auth/kubernetes/role/flux-ssh \
    bound_service_account_names="flux2-source-controller" \
    bound_service_account_namespaces="flux-system" \
    policies="flux-ssh" \
    ttl=1h 2>/dev/null
  echo "  K8s auth role 'flux-ssh' bound to flux2-source-controller SA"
}

echo ""
echo "=== Configuring Kubernetes auth for agent injector ==="
configure_k8s_auth

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  OpenBao cluster instances initialized"
echo "  Transit engine enabled (state-encryption key ready)"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "  Infra: kubectl -n $NAMESPACE exec -it openbao-infra-0 -- bao status"
echo "  App:   kubectl -n $NAMESPACE exec -it openbao-app-0 -- bao status"
echo ""
echo "  Tokens/keys saved to $OUTDIR/"
echo ""
echo "  State encryption: stacks deployed after openbao-init can use"
echo "    key_provider \"openbao\" with address=http://openbao-infra.secrets.svc:8200"
echo "════════════════════════════════════════════════════════════"
