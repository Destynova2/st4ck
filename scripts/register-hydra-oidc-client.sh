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
# Secret handling:
#   The OIDC client secret is sourced from OpenBao Infra through ESO:
#     secret/identity/hydra.client_secret -> hydra-secrets/oidc-client-secret
#   This script mounts that Kubernetes Secret into the one-shot registration
#   pod as a file. It does not pass the secret as a pod environment variable
#   or interpolate it into shell JSON.
#
# Optional env:
#   HYDRA_ADMIN_URL                  default: http://hydra-admin.identity.svc:4445
#   KUBECONFIG                       default: ~/.kube/st4ck-dev-mgmt-fr-par
#   HYDRA_NAMESPACE                  default: identity
#   OIDC_CLIENT_SECRET_SECRET_NAME   default: hydra-secrets
#   OIDC_CLIENT_SECRET_SECRET_KEY    default: oidc-client-secret
#   OIDC_REGISTER_IMAGE              default: alpine/k8s:1.35.4 (curl + jq)
#   POLL_TIMEOUT_S                   default: 300 (5 min)

set -euo pipefail

: "${KUBECONFIG:=$HOME/.kube/st4ck-dev-mgmt-fr-par}"
: "${HYDRA_ADMIN_URL:=http://hydra-admin.identity.svc:4445}"
: "${HYDRA_NAMESPACE:=identity}"
: "${HYDRA_POD_LABEL:=app.kubernetes.io/name=hydra,app.kubernetes.io/component=admin}"
: "${OIDC_CLIENT_SECRET_SECRET_NAME:=hydra-secrets}"
: "${OIDC_CLIENT_SECRET_SECRET_KEY:=oidc-client-secret}"
: "${OIDC_REGISTER_IMAGE:=alpine/k8s:1.35.4}"
: "${POLL_TIMEOUT_S:=300}"

export KUBECONFIG

echo "[oidc-register] kubeconfig:    $KUBECONFIG"
echo "[oidc-register] hydra admin:   $HYDRA_ADMIN_URL"
echo "[oidc-register] secret source: $HYDRA_NAMESPACE/$OIDC_CLIENT_SECRET_SECRET_NAME:$OIDC_CLIENT_SECRET_SECRET_KEY"
echo "[oidc-register] poll timeout:  ${POLL_TIMEOUT_S}s"

kubectl -n "$HYDRA_NAMESPACE" get secret "$OIDC_CLIENT_SECRET_SECRET_NAME" >/dev/null

JOB_NAME="hydra-oidc-register-$(date +%s)"

cleanup() {
  kubectl -n "$HYDRA_NAMESPACE" delete pod "$JOB_NAME" --ignore-not-found=true >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

cat <<YAML | kubectl -n "$HYDRA_NAMESPACE" apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${JOB_NAME}
  labels:
    app.kubernetes.io/name: hydra-oidc-register
spec:
  restartPolicy: Never
  volumes:
    - name: oidc-client-secret
      secret:
        secretName: ${OIDC_CLIENT_SECRET_SECRET_NAME}
        items:
          - key: ${OIDC_CLIENT_SECRET_SECRET_KEY}
            path: client-secret
  containers:
    - name: register
      image: ${OIDC_REGISTER_IMAGE}
      imagePullPolicy: IfNotPresent
      env:
        - name: HYDRA_ADMIN_URL
          value: "${HYDRA_ADMIN_URL}"
        - name: POLL_TIMEOUT_S
          value: "${POLL_TIMEOUT_S}"
        - name: OIDC_CLIENT_SECRET_FILE
          value: /var/run/secrets/hydra-oidc/client-secret
      volumeMounts:
        - name: oidc-client-secret
          mountPath: /var/run/secrets/hydra-oidc
          readOnly: true
      command:
        - /bin/sh
        - -c
        - |
          set -eu

          command -v curl >/dev/null 2>&1 || { echo "ERROR: curl not found in image" >&2; exit 1; }
          command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found in image" >&2; exit 1; }
          test -s "\$OIDC_CLIENT_SECRET_FILE" || { echo "ERROR: mounted OIDC client secret is empty" >&2; exit 1; }

          echo "Waiting for Hydra admin..."
          READY=0
          for i in \$(seq 1 "\$POLL_TIMEOUT_S"); do
            if curl -sf "\${HYDRA_ADMIN_URL}/health/ready" >/dev/null 2>&1; then
              READY=1
              break
            fi
            if [ \$((i % 10)) -eq 0 ]; then
              echo "  attempt \$i/\${POLL_TIMEOUT_S}..."
            fi
            sleep 1
          done
          if [ "\$READY" -ne 1 ]; then
            echo "ERROR: Hydra admin not ready after \${POLL_TIMEOUT_S}s — is Flux done reconciling?" >&2
            exit 1
          fi

          echo "Registering kubernetes OIDC client..."
          jq -n --rawfile client_secret "\$OIDC_CLIENT_SECRET_FILE" '{
            client_id: "kubernetes",
            client_secret: (\$client_secret | rtrimstr("\n")),
            grant_types: ["authorization_code", "refresh_token"],
            response_types: ["code"],
            scope: "openid email profile",
            redirect_uris: ["http://localhost:8000", "http://localhost:18000"],
            token_endpoint_auth_method: "client_secret_basic"
          }' > /tmp/hydra-client.json

          HTTP_CODE=\$(curl -s -o /tmp/hydra-resp.txt -w "%{http_code}" \
            -X POST "\${HYDRA_ADMIN_URL}/admin/clients" \
            -H "Content-Type: application/json" \
            --data-binary @/tmp/hydra-client.json)

          case "\$HTTP_CODE" in
            201) echo "  OIDC client created" ;;
            409) echo "  OIDC client already registered (409 — idempotent)" ;;
            *)
              echo "ERROR: Hydra returned HTTP \$HTTP_CODE" >&2
              cat /tmp/hydra-resp.txt >&2
              exit 1
              ;;
          esac
          echo "Done."
YAML

kubectl -n "$HYDRA_NAMESPACE" logs -f "pod/$JOB_NAME" --pod-running-timeout=120s || true

PHASE="$(kubectl -n "$HYDRA_NAMESPACE" get pod "$JOB_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || echo Unknown)"
if [ "$PHASE" != "Succeeded" ]; then
  echo "ERROR: OIDC registration pod ended with phase: $PHASE" >&2
  kubectl -n "$HYDRA_NAMESPACE" describe pod "$JOB_NAME" >&2 || true
  exit 1
fi
