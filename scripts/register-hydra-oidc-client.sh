#!/usr/bin/env bash
# register-hydra-oidc-client.sh
#
# Bug #35 fix (Phase F-bis-2): register the kubernetes OIDC client in Hydra
# AFTER Flux has deployed the Hydra Helm release. Previously this lived in
# stacks/identity/main.tf as kubernetes_job_v1.hydra_oidc_client, but Hydra
# is now Flux-owned (ADR-028) and the Job timed out 10 min waiting for an
# admin endpoint that only appears once Flux reconciles — long after the
# identity stack apply completes. Postmortem 2026-04-30.
#
# Run via `make oidc-register` once Flux has deployed Hydra. Idempotent:
# 201 (created) and 409 (already registered) both succeed; any other HTTP
# code aborts with the response body for triage (Bug #19/#24 pattern).
#
# Required env:
#   OIDC_CLIENT_SECRET   secret to register (from `tofu output oidc_client_secret`)
#
# Optional env:
#   HYDRA_ADMIN_URL      default: http://hydra-admin.identity.svc:4445
#   KUBECONFIG           default: ~/.kube/st4ck-dev-mgmt-fr-par
#   HYDRA_NAMESPACE      default: identity
#   HYDRA_POD_LABEL      default: app.kubernetes.io/name=hydra,app.kubernetes.io/component=admin
#   POLL_TIMEOUT_S       default: 300 (5 min)

set -eu

: "${OIDC_CLIENT_SECRET:?ERROR: OIDC_CLIENT_SECRET is required (run via make oidc-register)}"
: "${KUBECONFIG:=$HOME/.kube/st4ck-dev-mgmt-fr-par}"
: "${HYDRA_ADMIN_URL:=http://hydra-admin.identity.svc:4445}"
: "${HYDRA_NAMESPACE:=identity}"
: "${HYDRA_POD_LABEL:=app.kubernetes.io/name=hydra,app.kubernetes.io/component=admin}"
: "${POLL_TIMEOUT_S:=300}"

export KUBECONFIG

echo "[oidc-register] kubeconfig:    $KUBECONFIG"
echo "[oidc-register] hydra admin:   $HYDRA_ADMIN_URL"
echo "[oidc-register] poll timeout:  ${POLL_TIMEOUT_S}s"

# Run the curl-based registration as a one-shot Pod inside the cluster so we
# can reach the in-cluster Service DNS (hydra-admin.identity.svc) without a
# port-forward. kubectl run --rm waits for completion and streams logs.
JOB_NAME="hydra-oidc-register-$(date +%s)"

kubectl -n "$HYDRA_NAMESPACE" run "$JOB_NAME" \
  --rm -i --restart=Never \
  --image=curlimages/curl:8.12.1 \
  --env="OIDC_CLIENT_SECRET=${OIDC_CLIENT_SECRET}" \
  --env="HYDRA_ADMIN_URL=${HYDRA_ADMIN_URL}" \
  --env="POLL_TIMEOUT_S=${POLL_TIMEOUT_S}" \
  --command -- /bin/sh -c '
    set -eu

    echo "Waiting for Hydra admin..."
    READY=0
    for i in $(seq 1 "$POLL_TIMEOUT_S"); do
      if curl -sf "${HYDRA_ADMIN_URL}/health/ready" >/dev/null 2>&1; then
        READY=1
        break
      fi
      if [ $((i % 10)) -eq 0 ]; then
        echo "  attempt $i/${POLL_TIMEOUT_S}..."
      fi
      sleep 1
    done
    if [ "$READY" -ne 1 ]; then
      echo "ERROR: Hydra admin not ready after ${POLL_TIMEOUT_S}s — is Flux done reconciling?"
      exit 1
    fi

    echo "Registering kubernetes OIDC client..."
    # Bug #19/#24 pattern: capture HTTP status explicitly. 201 = created,
    # 409 = already registered (both OK). Anything else = exit 1 with body.
    HTTP_CODE=$(curl -s -o /tmp/hydra-resp.txt -w "%{http_code}" \
      -X POST "${HYDRA_ADMIN_URL}/admin/clients" \
      -H "Content-Type: application/json" \
      -d "{
        \"client_id\": \"kubernetes\",
        \"client_secret\": \"${OIDC_CLIENT_SECRET}\",
        \"grant_types\": [\"authorization_code\", \"refresh_token\"],
        \"response_types\": [\"code\"],
        \"scope\": \"openid email profile\",
        \"redirect_uris\": [\"http://localhost:8000\", \"http://localhost:18000\"],
        \"token_endpoint_auth_method\": \"client_secret_basic\"
      }")

    case "$HTTP_CODE" in
      201) echo "  OIDC client created" ;;
      409) echo "  OIDC client already registered (409 — idempotent)" ;;
      *)
        echo "ERROR: Hydra returned HTTP $HTTP_CODE"
        cat /tmp/hydra-resp.txt
        exit 1
        ;;
    esac
    echo "Done."
  '
