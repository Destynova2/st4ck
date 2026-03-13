#!/usr/bin/env bash
# Bootstrap OpenBao KMS cluster (3 nodes Raft) + Transit auto-unseal + PKI CA chain
#
# Prerequisites: podman, jq, bao CLI (or curl)
# Usage: bash scripts/openbao-kms-bootstrap.sh
#
# Outputs (written to ./kms-output/):
#   root-token.txt          — KMS root token (keep secret)
#   unseal-keys.txt         — Shamir unseal keys (keep secret)
#   transit-token.txt       — Token for auto-unseal policy (inject into k8s)
#   vault-backend-token.txt — Token for vault-backend (Terraform state in KV v2)
#   root-ca.pem             — Root CA certificate
#   infra-ca.pem            — Infra sub-CA cert (Cilium mTLS, etcd, internal)
#   infra-ca-key.pem        — Infra sub-CA private key (for cert-manager)
#   infra-ca-chain.pem      — Infra chain (infra + root)
#   app-ca.pem              — App sub-CA cert (Hydra TLS, user-facing)
#   app-ca-key.pem          — App sub-CA private key
#   app-ca-chain.pem        — App chain (app + root)
set -euo pipefail

OUTDIR="${1:-./kms-output}"
NODE0="http://127.0.0.1:8200"
NODE1="http://127.0.0.1:8202"
NODE2="http://127.0.0.1:8204"
PKI_ORG="${PKI_ORG:-Talos Platform}"
PKI_ROOT_TTL="${PKI_ROOT_TTL:-87600h}"      # 10 years
PKI_INT_TTL="${PKI_INT_TTL:-43800h}"        # 5 years

mkdir -p "$OUTDIR"

# ─── Helpers ────────────────────────────────────────────────────────────

bao_api() {
  local method="$1" url="$2"; shift 2
  curl -sf -X "$method" -H "X-Vault-Token: $ROOT_TOKEN" \
    -H "Content-Type: application/json" "$url" "$@"
}

wait_for() {
  local url="$1" max=30
  echo -n "  Waiting for $url"
  for i in $(seq 1 $max); do
    # OpenBao returns 501 when not initialized, 503 when sealed — both mean it's up
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' "${url}/v1/sys/health" 2>/dev/null || echo "000")
    if [ "$code" != "000" ]; then
      echo " ready (HTTP $code)"
      return 0
    fi
    echo -n "."
    sleep 1
  done
  echo " TIMEOUT"
  return 1
}

# ─── 1. Start the pod (if not already running via Quadlet) ────────────

echo "=== Starting OpenBao KMS cluster (3 nodes) ==="
if ! podman pod exists openbao-kms 2>/dev/null && ! podman pod exists platform 2>/dev/null; then
  echo "ERROR: No KMS pod running. Use 'make kms-bootstrap' (platform pod) or start manually."
  exit 1
fi
wait_for "$NODE0"

# ─── 2. Initialize node-0 ──────────────────────────────────────────────

echo "=== Initializing Raft cluster ==="
INIT=$(curl -sf -X PUT "$NODE0/v1/sys/init" \
  -d '{"secret_shares":3,"secret_threshold":2}')

ROOT_TOKEN=$(echo "$INIT" | jq -r '.root_token')
KEYS_JSON=$(echo "$INIT" | jq -r '.keys[]')
mapfile -t KEYS <<< "$KEYS_JSON"

echo "$ROOT_TOKEN" > "$OUTDIR/root-token.txt"
printf '%s\n' "${KEYS[@]}" > "$OUTDIR/unseal-keys.txt"
echo "  Root token saved to $OUTDIR/root-token.txt"

# ─── 3. Unseal node-0 ──────────────────────────────────────────────────

echo "=== Unsealing node-0 ==="
curl -sf -X PUT "$NODE0/v1/sys/unseal" -d "{\"key\":\"${KEYS[0]}\"}" > /dev/null
curl -sf -X PUT "$NODE0/v1/sys/unseal" -d "{\"key\":\"${KEYS[1]}\"}" > /dev/null
echo "  node-0 unsealed"

# ─── 4. Join + unseal nodes 1 and 2 ────────────────────────────────────

echo "=== Joining node-1 and node-2 to Raft ==="
for node_url in "$NODE1" "$NODE2"; do
  wait_for "$node_url"
  curl -sf -X PUT "$node_url/v1/sys/storage/raft/join" \
    -d "{\"leader_api_addr\":\"$NODE0\"}" > /dev/null
  curl -sf -X PUT "$node_url/v1/sys/unseal" -d "{\"key\":\"${KEYS[0]}\"}" > /dev/null
  curl -sf -X PUT "$node_url/v1/sys/unseal" -d "{\"key\":\"${KEYS[1]}\"}" > /dev/null
  echo "  $(basename "$node_url") joined and unsealed"
done

# Verify Raft peers
echo "=== Raft cluster status ==="
bao_api GET "$NODE0/v1/sys/storage/raft/configuration" | jq -r '.data.config.servers[] | "  \(.node_id): \(.leader)"'

# ─── 5. Transit engine for auto-unseal ─────────────────────────────────

echo "=== Configuring Transit auto-unseal ==="
bao_api POST "$NODE0/v1/sys/mounts/transit" -d '{"type":"transit"}' > /dev/null
bao_api POST "$NODE0/v1/transit/keys/autounseal" -d '{"type":"aes256-gcm96"}' > /dev/null

# Create restricted policy for auto-unseal
bao_api PUT "$NODE0/v1/sys/policies/acl/autounseal" -d '{
  "policy": "path \"transit/encrypt/autounseal\" { capabilities = [\"update\"] }\npath \"transit/decrypt/autounseal\" { capabilities = [\"update\"] }"
}' > /dev/null

# Create token with auto-unseal policy (no expiry)
TRANSIT_TOKEN=$(bao_api POST "$NODE0/v1/auth/token/create" \
  -d '{"policies":["autounseal"],"no_parent":true,"period":"768h"}' | jq -r '.auth.client_token')
echo "$TRANSIT_TOKEN" > "$OUTDIR/transit-token.txt"
echo "  Transit key 'autounseal' created"
echo "  Transit token saved to $OUTDIR/transit-token.txt"

# ─── 5b. KV v2 + vault-backend policy/token (Terraform state) ─────────

echo "=== Configuring KV v2 for Terraform state ==="
bao_api POST "$NODE0/v1/sys/mounts/secret" \
  -d '{"type":"kv","options":{"version":"2"}}' > /dev/null

# Policy: vault-backend needs CRUD on tfstate data + list/delete on metadata
bao_api PUT "$NODE0/v1/sys/policies/acl/vault-backend" -d '{
  "policy": "path \"secret/data/tfstate/*\" { capabilities = [\"create\", \"read\", \"update\"] }\npath \"secret/metadata/tfstate/*\" { capabilities = [\"delete\", \"read\", \"list\"] }"
}' > /dev/null

# Create token with vault-backend policy (no expiry, periodic renewal)
VB_TOKEN=$(bao_api POST "$NODE0/v1/auth/token/create" \
  -d '{"policies":["vault-backend"],"no_parent":true,"period":"768h"}' | jq -r '.auth.client_token')
echo "$VB_TOKEN" > "$OUTDIR/vault-backend-token.txt"
echo "  KV v2 mounted at secret/"
echo "  vault-backend policy created"
echo "  vault-backend token saved to $OUTDIR/vault-backend-token.txt"

# ─── 6. PKI — Root CA ──────────────────────────────────────────────────

echo "=== Generating PKI Root CA ==="
bao_api POST "$NODE0/v1/sys/mounts/pki" -d "{\"type\":\"pki\",\"config\":{\"max_lease_ttl\":\"$PKI_ROOT_TTL\"}}" > /dev/null

ROOT_CA=$(bao_api POST "$NODE0/v1/pki/root/generate/internal" -d "{
  \"common_name\": \"${PKI_ORG} Root CA\",
  \"organization\": \"${PKI_ORG}\",
  \"key_type\": \"ec\",
  \"key_bits\": 384,
  \"ttl\": \"$PKI_ROOT_TTL\",
  \"issuer_name\": \"root\"
}")
echo "$ROOT_CA" | jq -r '.data.certificate' > "$OUTDIR/root-ca.pem"
echo "  Root CA generated: ${PKI_ORG} Root CA"

# ─── 7. PKI — Sub-CA Infra (Cilium mTLS, etcd, cert-manager internal) ──

generate_sub_ca() {
  local name="$1" cn="$2" mount="$3" domains="$4"

  echo "=== Generating PKI Sub-CA: $cn ==="
  bao_api POST "$NODE0/v1/sys/mounts/$mount" \
    -d "{\"type\":\"pki\",\"config\":{\"max_lease_ttl\":\"$PKI_INT_TTL\"}}" > /dev/null

  local gen_result
  gen_result=$(bao_api POST "$NODE0/v1/$mount/intermediate/generate/exported" -d "{
    \"common_name\": \"$cn\",
    \"organization\": \"${PKI_ORG}\",
    \"key_type\": \"ec\",
    \"key_bits\": 384,
    \"issuer_name\": \"$name\"
  }")
  local csr
  csr=$(echo "$gen_result" | jq -r '.data.csr')
  echo "$gen_result" | jq -r '.data.private_key' > "$OUTDIR/${name}-ca-key.pem"

  local signed
  signed=$(bao_api POST "$NODE0/v1/pki/root/sign-intermediate" -d "{
    \"csr\": $(echo "$csr" | jq -Rs .),
    \"common_name\": \"$cn\",
    \"organization\": \"${PKI_ORG}\",
    \"ttl\": \"$PKI_INT_TTL\"
  }")

  echo "$signed" | jq -r '.data.certificate' > "$OUTDIR/${name}-ca.pem"
  cat "$OUTDIR/${name}-ca.pem" "$OUTDIR/root-ca.pem" > "$OUTDIR/${name}-ca-chain.pem"

  # Set signed cert
  bao_api POST "$NODE0/v1/$mount/intermediate/set-signed" -d "{
    \"certificate\": $(echo "$signed" | jq -r '.data.certificate + "\n" + .data.issuing_ca' | jq -Rs .)
  }" > /dev/null

  # Create role
  bao_api POST "$NODE0/v1/$mount/roles/default" -d "{
    \"allowed_domains\": [$domains],
    \"allow_subdomains\": true,
    \"allow_bare_domains\": true,
    \"max_ttl\": \"8760h\",
    \"key_type\": \"ec\",
    \"key_bits\": 256
  }" > /dev/null

  echo "  $cn generated and signed by Root"
}

generate_sub_ca "infra" "${PKI_ORG} Infra CA" "pki_infra" \
  '"svc.cluster.local","cluster.local","local"'

# ─── 8. PKI — Sub-CA App (Hydra TLS, user-facing services) ────────────

generate_sub_ca "app" "${PKI_ORG} App CA" "pki_app" \
  '"svc.cluster.local","local"'

# ─── 9. Summary ────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  KMS cluster ready — 3 nodes Raft"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "  Outputs in $OUTDIR/:"
echo "    root-token.txt          — KMS root token"
echo "    unseal-keys.txt         — Shamir keys (3 shares, threshold 2)"
echo "    transit-token.txt       — Auto-unseal token for OpenBao App/Infra"
echo "    vault-backend-token.txt — Token for vault-backend (Terraform state)"
echo "    root-ca.pem             — Root CA cert"
echo "    infra-ca.pem            — Infra sub-CA cert (Cilium mTLS, etcd)"
echo "    infra-ca-key.pem        — Infra sub-CA private key"
echo "    infra-ca-chain.pem      — Infra chain (infra + root)"
echo "    app-ca.pem              — App sub-CA cert (Hydra TLS, user-facing)"
echo "    app-ca-key.pem          — App sub-CA private key"
echo "    app-ca-chain.pem        — App chain (app + root)"
echo ""
echo "  Auto-unseal config for OpenBao App/Infra:"
echo "    seal \"transit\" {"
echo "      address         = \"$NODE0\""
echo "      token           = \"$(cat "$OUTDIR/transit-token.txt")\""
echo "      key_name        = \"autounseal\""
echo "      mount_path      = \"transit/\""
echo "      tls_skip_verify = true"
echo "    }"
echo ""
echo "  Terraform HTTP backend (vault-backend on :8080):"
echo "    backend \"http\" {"
echo "      address        = \"http://127.0.0.1:8080\""
echo "      lock_address   = \"http://127.0.0.1:8080\""
echo "      unlock_address = \"http://127.0.0.1:8080\""
echo "      username       = \"TOKEN\""
echo "      password       = \"$(cat "$OUTDIR/vault-backend-token.txt")\""
echo "    }"
echo ""
echo "  To stop:  podman play kube --down configs/openbao/kms-pod.yaml"
echo "════════════════════════════════════════════════════════════"
