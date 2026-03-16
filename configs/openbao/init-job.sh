#!/bin/sh
# OpenBao in-cluster init — mounted via ConfigMap, no Terraform escaping needed.
# Runs inside a K8s Job (k8s-pki stack). Idempotent.
set -eu

KUBE_API="https://kubernetes.default.svc"
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
kube() { curl -sf --cacert $CA -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" "$@"; }
NS=$NAMESPACE

# ─── Helper: init + unseal one instance ─────────────────────────────
init_instance() {
  local name="$1" svc="$2"
  local addr="http://$svc.$NS.svc:8200"

  echo "=== $name ==="
  echo "  Waiting for $svc..."
  for i in $(seq 1 60); do
    curl -so /dev/null "$addr/v1/sys/health" 2>/dev/null && break
    sleep 5
  done

  # Already initialized?
  if kube "$KUBE_API/api/v1/namespaces/$NS/secrets/$name-token" >/dev/null 2>&1; then
    echo "  $name already initialized (token secret exists)"
    local sealed=$(curl -sf "$addr/v1/sys/health" 2>/dev/null | grep -o '"sealed":true' || true)
    if [ -n "$sealed" ]; then
      local unseal_key=$(kube "$KUBE_API/api/v1/namespaces/$NS/secrets/$name-unseal" | \
        grep -o '"key":"[^"]*"' | tail -1 | cut -d'"' -f4 | base64 -d 2>/dev/null || true)
      [ -n "$unseal_key" ] && curl -sf -X PUT "$addr/v1/sys/unseal" -d "{\"key\":\"$unseal_key\"}" >/dev/null && echo "  Unsealed"
    fi
    return 0
  fi

  # Init
  echo "  Initializing..."
  local init=$(curl -sf -X PUT "$addr/v1/sys/init" -d '{"secret_shares":1,"secret_threshold":1}')
  local root_token=$(echo "$init" | grep -o '"root_token":"[^"]*"' | cut -d'"' -f4)
  local unseal_key=$(echo "$init" | grep -o '"keys":\["[^"]*"' | cut -d'"' -f4)

  curl -sf -X PUT "$addr/v1/sys/unseal" -d "{\"key\":\"$unseal_key\"}" >/dev/null
  echo "  Initialized and unsealed"

  # Store in K8s Secrets
  local rt_b64=$(printf '%s' "$root_token" | base64 | tr -d '\n')
  local uk_b64=$(printf '%s' "$unseal_key" | base64 | tr -d '\n')
  kube -X POST -d "{\"apiVersion\":\"v1\",\"kind\":\"Secret\",\"metadata\":{\"name\":\"$name-token\",\"namespace\":\"$NS\"},\"data\":{\"token\":\"$rt_b64\"}}" \
    "$KUBE_API/api/v1/namespaces/$NS/secrets" >/dev/null
  kube -X POST -d "{\"apiVersion\":\"v1\",\"kind\":\"Secret\",\"metadata\":{\"name\":\"$name-unseal\",\"namespace\":\"$NS\"},\"data\":{\"key\":\"$uk_b64\"}}" \
    "$KUBE_API/api/v1/namespaces/$NS/secrets" >/dev/null
  echo "  Tokens stored in K8s Secrets"
}

init_instance "openbao-infra" "openbao-infra"
init_instance "openbao-app" "openbao-app"

# ─── Configure openbao-infra ────────────────────────────────────────
INFRA_ADDR="http://openbao-infra.$NS.svc:8200"
INFRA_TOKEN=$(kube "$KUBE_API/api/v1/namespaces/$NS/secrets/openbao-infra-token" | \
  grep -o '"token":"[^"]*"' | tail -1 | cut -d'"' -f4 | base64 -d 2>/dev/null || true)

if [ -n "$INFRA_TOKEN" ]; then
  bao_api() { curl -sf -X "$1" -H "X-Vault-Token: $INFRA_TOKEN" -H "Content-Type: application/json" "$2" ${3:+-d "$3"}; }

  # Transit engine
  if ! bao_api GET "$INFRA_ADDR/v1/sys/mounts" | grep -q '"transit/"'; then
    bao_api POST "$INFRA_ADDR/v1/sys/mounts/transit" '{"type":"transit"}' >/dev/null
    echo "  Transit engine enabled"
  fi
  bao_api POST "$INFRA_ADDR/v1/transit/keys/state-encryption" '{"type":"aes256-gcm96"}' >/dev/null 2>&1 || true
  echo "  Transit key 'state-encryption' ready"

  # SSH CA
  if ! bao_api GET "$INFRA_ADDR/v1/sys/mounts" | grep -q '"ssh-client-signer/"'; then
    bao_api POST "$INFRA_ADDR/v1/sys/mounts/ssh-client-signer" '{"type":"ssh"}' >/dev/null
    bao_api POST "$INFRA_ADDR/v1/ssh-client-signer/config/ca" '{"generate_signing_key":true}' >/dev/null
    echo "  SSH CA engine enabled"
  fi
  bao_api POST "$INFRA_ADDR/v1/ssh-client-signer/roles/flux" \
    '{"key_type":"ca","allowed_users":"flux","default_user":"flux","ttl":"2h","max_ttl":"24h","allow_user_certificates":true}' >/dev/null 2>&1 || true
  echo "  SSH role 'flux' ready"

  # K8s auth
  if ! bao_api GET "$INFRA_ADDR/v1/sys/auth" | grep -q '"kubernetes/"'; then
    bao_api POST "$INFRA_ADDR/v1/sys/auth/kubernetes" '{"type":"kubernetes"}' >/dev/null
    echo "  K8s auth enabled"
  fi
  bao_api POST "$INFRA_ADDR/v1/auth/kubernetes/config" '{"kubernetes_host":"https://kubernetes.default.svc"}' >/dev/null
  bao_api PUT "$INFRA_ADDR/v1/sys/policies/acl/flux-ssh" \
    '{"policy":"path \"ssh-client-signer/sign/flux\" { capabilities = [\"create\", \"update\"] }"}' >/dev/null
  bao_api POST "$INFRA_ADDR/v1/auth/kubernetes/role/flux-ssh" \
    '{"bound_service_account_names":"flux2-source-controller","bound_service_account_namespaces":"flux-system","policies":"flux-ssh","ttl":"1h"}' >/dev/null
  echo "  K8s auth + flux-ssh role ready"
fi

echo "=== OpenBao init complete ==="
