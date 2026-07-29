#!/usr/bin/env bash
# e2e-local.sh — golden path tofu-first AUTOMATISE (test-local.md 3.4).
# Rend la classe "day-1 manquant / conflit SSA" verifiable sans humain :
# cluster jetable → day-1 tofu dans l'ordre de prod → day-2 Flux →
# assertions → exit 0/1. Concu pour nightly + porte de release ADR-037.
#
# Prerequis : podman machine rootful ~24Gi/12cpu/100Go, platform pod up
# (make bootstrap), kms-output/ present, HEAD pousse sur le Gitea local.
#
# Env : VB_PORT (defaut 8080), GITEA_PORT (defaut 3000),
#       E2E_NAME (defaut st4ck-e2e), E2E_KEEP=1 (pas de teardown),
#       E2E_TIMEOUT_MIN (defaut 45, attente de convergence day-2).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

VB_PORT="${VB_PORT:-8080}"
GITEA_PORT="${GITEA_PORT:-3000}"
E2E_NAME="${E2E_NAME:-st4ck-e2e}"
E2E_TIMEOUT_MIN="${E2E_TIMEOUT_MIN:-45}"
# Levier 5 : 1 CP + 3 workers suffisent (garage rf=3 sur workers).
export WORKERS="${E2E_WORKERS:-3}"
# Levier 1 : mirror hauler auto-detecte (hauler store serve sur :5001).
E2E_MIRROR_PORT="${E2E_MIRROR_PORT:-5001}"
# LOCAL_BACKEND=1 : etat tofu LOCAL et jetable — purge a chaque run.
# Sans cela, les chemins d'etat partages du vault-backend font sauter les
# terraform_data (seeds KV, chargement pki_int : triggers inchanges =
# jamais re-executes sur un cluster neuf) — trouve par le run 1.
CTX_ARGS=(ENV=dev INSTANCE=docker REGION=local "VB_PORT=${VB_PORT}" LOCAL_BACKEND=1)
KC="${HOME}/.kube/st4ck-dev-docker-local"
K="kubectl --kubeconfig ${KC} --request-timeout=30s"
GVPROXY_HOST="192.168.127.254" # IP de l'hote vue des pods (gvproxy)

# HRs toleres non-Ready (limites structurelles du tier container,
# documentees dans test-local.md — kubescape node-agent exige /boot,
# bpffs... absents des noeuds conteneurises).
ALLOWLIST_HR="security/kubescape"

FAIL=0
phase() { printf '\n═══ %s ═══\n' "$*"; }
die()   { printf 'E2E FAIL: %s\n' "$*" >&2; exit 1; }

# ── Phase 0 : preflight ─────────────────────────────────────────────────
phase "0. preflight"
curl -so /dev/null "http://localhost:${VB_PORT}/state/test" \
  || die "vault-backend injoignable sur :${VB_PORT} (make bootstrap)"
curl -so /dev/null "http://localhost:${GITEA_PORT}" \
  || die "Gitea injoignable sur :${GITEA_PORT}"
[ -f kms-output/vault-backend-token.txt ] || die "kms-output/ absent"
if curl -so /dev/null "http://localhost:${E2E_MIRROR_PORT}/v2/_catalog"; then
  export REGISTRY_MIRROR="192.168.127.254:${E2E_MIRROR_PORT}"
  echo "mirror hauler detecte → ${REGISTRY_MIRROR}"
else
  echo "pas de mirror hauler sur :${E2E_MIRROR_PORT} (pulls upstream directs)"
fi
echo "preflight ok"

# ── Phase 1 : cluster jetable sans CNI ──────────────────────────────────
phase "1. cluster ${E2E_NAME} (1 CP + ${WORKERS} workers, sans CNI)"
if [ "${E2E_REUSE:-0}" = "1" ] && ${K} get nodes >/dev/null 2>&1; then
  # Levier 3 : mode iteration — cluster ET etats tofu conserves
  # (coherents entre eux). Le mode froid reste la porte de release.
  echo "E2E_REUSE=1 — cluster existant conserve, re-applies incrementaux"
else
  for st in cni pki monitoring identity security storage; do
    rm -f "stacks/${st}/terraform.tfstate" "stacks/${st}/terraform.tfstate.backup" \
          "stacks/${st}/_local_backend_override.tf"
  done
  make local-docker-down "LOCAL_DOCKER_NAME=${E2E_NAME}" >/dev/null 2>&1 || true
  KUBECONFIG_OUT="${KC}" SKIP_CILIUM=1 bash scripts/local-docker-up.sh "${E2E_NAME}"
fi

# ── Phase 2 : day-1 tofu, ordre de production ───────────────────────────
phase "2. day-1 tofu (cni → pki → waves)"
make k8s-cni-apply "${CTX_ARGS[@]}"
${K} wait --for=condition=Ready nodes --all --timeout=300s >/dev/null
make k8s-pki-apply "${CTX_ARGS[@]}"
make -j3 k8s-wave1 "${CTX_ARGS[@]}"
make k8s-wave2 "${CTX_ARGS[@]}"

# ── Phase 3 : day-2 Flux (HTTP vers le Gitea du bootstrap) ──────────────
phase "3. day-2 Flux"
flux --kubeconfig "${KC}" install >/dev/null
# Source canonique : l'output tofu du bootstrap (etat local).
GITEA_PASS="$(tofu -chdir=bootstrap output -raw admin_password 2>/dev/null \
  || cat "${E2E_GITEA_PASS_FILE:?admin_password introuvable (tofu bootstrap output) et E2E_GITEA_PASS_FILE non fourni}")"
${K} -n flux-system create secret generic flux-git-auth \
  --from-literal=username=talos --from-literal=password="${GITEA_PASS}" \
  --dry-run=client -o yaml | ${K} apply -f - >/dev/null
${K} apply -f clusters/management/versions-configmap.yaml >/dev/null
sed -e "s|__GITEA_URL__|http://${GVPROXY_HOST}:${GITEA_PORT}/talos/talos.git|" \
  scripts/e2e-local-flux.yaml | ${K} apply -f - >/dev/null
echo "GitRepository + Kustomization racine appliques"

# ── Phase 4 : convergence ───────────────────────────────────────────────
phase "4. convergence (max ${E2E_TIMEOUT_MIN} min)"
DEADLINE=$(( $(date +%s) + E2E_TIMEOUT_MIN * 60 ))
while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
  sleep 60
  HR_STATE=$(${K} get helmrelease -A -o custom-columns="NS:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[?(@.type=='Ready')].status" --no-headers 2>/dev/null) || HR_STATE=""
  TOTAL=$(printf '%s\n' "${HR_STATE}" | grep -c . || true)
  READY=$(printf '%s\n' "${HR_STATE}" | awk '$3=="True"' | wc -l | tr -d ' ')
  echo "  HR ready=${READY}/${TOTAL}"
  if [ "${TOTAL}" -gt 0 ]; then
    PENDING=$(printf '%s\n' "${HR_STATE}" | awk '$3!="True" {print $1"/"$2}')
    NON_ALLOWED=$(printf '%s\n' "${PENDING}" | grep -vxF "${ALLOWLIST_HR}" | grep -c . || true)
    [ "${NON_ALLOWED}" = "0" ] && break
    # Levier 2 : un HR False a mi-fenetre a epuise ses retries sur un
    # transitoire (course ES, timeout pull) — un suspend/resume le
    # relance. Une seule fois par HR et par run.
    ELAPSED=$(( E2E_TIMEOUT_MIN * 60 - (DEADLINE - $(date +%s)) ))
    if [ "${ELAPSED}" -gt $(( E2E_TIMEOUT_MIN * 30 )) ]; then
      for hr in ${PENDING}; do
        case " ${KICKED:-} " in *" ${hr} "*) continue ;; esac
        NS="${hr%%/*}"; HRNAME="${hr##*/}"
        STATUS=$(printf '%s\n' "${HR_STATE}" | awk -v ns="${NS}" -v n="${HRNAME}" '$1==ns && $2==n {print $3}')
        [ "${STATUS}" = "False" ] || continue
        echo "  kick ${hr} (suspend/resume)"
        flux --kubeconfig "${KC}" -n "${NS}" suspend hr "${HRNAME}" >/dev/null 2>&1 || true
        flux --kubeconfig "${KC}" -n "${NS}" resume hr "${HRNAME}" --timeout 10s >/dev/null 2>&1 || true
        KICKED="${KICKED:-} ${hr}"
      done
    fi
  fi
done

# ── Phase 5 : assertions ────────────────────────────────────────────────
phase "5. assertions"
# 5a. HRs Ready (hors allowlist)
BAD_HR=$(${K} get helmrelease -A -o custom-columns="NS:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[?(@.type=='Ready')].status" --no-headers \
  | awk '$3!="True" {print $1"/"$2}' | grep -vxF "${ALLOWLIST_HR}" || true)
if [ -z "${BAD_HR}" ]; then echo "✅ HRs Ready (allowlist: ${ALLOWLIST_HR})"
else
  echo "❌ HRs non-Ready: ${BAD_HR}"; FAIL=1
  # Messages d'echec — le teardown emporte le cluster, capturons le POURQUOI
  for hr in ${BAD_HR}; do
    NS="${hr%%/*}"; NAME="${hr##*/}"
    MSG=$(${K} -n "${NS}" get helmrelease "${NAME}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null | head -c 300)
    echo "   ↳ ${hr}: ${MSG}"
  done
fi
# 5b. Kustomizations enfants True (la racine depend de l'allowlist via
# ses health checks — verifiee indirectement par 5a)
BAD_KS=$(${K} get kustomizations -n flux-system -o custom-columns="NAME:.metadata.name,READY:.status.conditions[?(@.type=='Ready')].status" --no-headers \
  | awk '$1!="management" && $2!="True" {print $1}' || true)
if [ -z "${BAD_KS}" ]; then echo "✅ Kustomizations enfants True"
else echo "❌ Kustomizations KO: ${BAD_KS}"; FAIL=1; fi
# 5c. ExternalSecrets tous synchronises
BAD_ES=$(${K} get externalsecrets -A -o custom-columns="NS:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[?(@.type=='Ready')].status" --no-headers \
  | awk '$3!="True" {print $1"/"$2}' || true)
if [ -z "${BAD_ES}" ]; then echo "✅ ExternalSecrets synchronises"
else echo "❌ ExternalSecrets KO: ${BAD_ES}"; FAIL=1; fi
# 5d. ClusterIssuers Ready (la chaine pki_int complete)
BAD_CI=$(${K} get clusterissuers -o custom-columns="NAME:.metadata.name,READY:.status.conditions[?(@.type=='Ready')].status" --no-headers \
  | awk '$2!="True" {print $1}' || true)
if [ -z "${BAD_CI}" ]; then echo "✅ ClusterIssuers Ready"
else echo "❌ ClusterIssuers KO: ${BAD_CI}"; FAIL=1; fi
# 5e. Pods KO — informatif (WARN), le tier container a ses limites
${K} get pods -A 2>/dev/null | grep -vE "Running|Completed" | tail -n +2 \
  | sed 's/^/  ⚠ pod KO: /' || true

# ── Phase 6 : teardown (sauf E2E_KEEP=1) ────────────────────────────────
if [ "${E2E_KEEP:-0}" != "1" ]; then
  phase "6. teardown"
  make local-docker-down "LOCAL_DOCKER_NAME=${E2E_NAME}" >/dev/null 2>&1 || true
fi

phase "BILAN"
if [ "${FAIL}" = "0" ]; then echo "E2E GOLDEN PATH: ✅ PASS"; else echo "E2E GOLDEN PATH: ❌ FAIL"; fi
exit "${FAIL}"
