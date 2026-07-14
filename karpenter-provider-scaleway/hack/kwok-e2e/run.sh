#!/usr/bin/env bash
# kwok e2e harness — level 5 of docs/how-to/test-local.md.
#
# Full NodeClaim cycle against a kwok cluster: static NodePool replicas
# 0->1 -> Create() (fake power-on) -> simulated kubelet join with the exact
# scaleway-em://<zone>/<id> providerID -> Registered/Initialized -> 1->0 ->
# drain -> Delete() (fake power-off) -> NodeClaim finalized.
#
# Usage: hack/kwok-e2e/run.sh          (or: make e2e-kwok)
#   KEEP=1          keep the kwok cluster + controller running on failure/exit
#   KWOK_RUNTIME=…  kwokctl runtime (default: podman if available, else docker)
#   TIMEOUT=…       per-wait timeout in seconds (default 120)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_ROOT="$(cd "${HERE}/../.." && pwd)"
CLUSTER="${KWOK_CLUSTER:-karpenter-em-e2e}"
TIMEOUT="${TIMEOUT:-120}"
DEBUG_ADDR="127.0.0.1:8085"
ARTIFACTS="${HERE}/.artifacts"
CONTROLLER_LOG="${ARTIFACTS}/controller.log"
CONTROLLER_PID=""

say()  { printf '\033[1;34m[e2e]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
  local status=$?
  if [ -n "${CONTROLLER_PID}" ] && kill -0 "${CONTROLLER_PID}" 2>/dev/null; then
    if [ "${KEEP:-0}" = "1" ]; then
      say "KEEP=1 — controller left running (pid ${CONTROLLER_PID}, log ${CONTROLLER_LOG})"
    else
      kill "${CONTROLLER_PID}" 2>/dev/null || true
    fi
  fi
  if [ "${KEEP:-0}" = "1" ]; then
    say "KEEP=1 — cluster '${CLUSTER}' kept (kwokctl delete cluster --name ${CLUSTER})"
  else
    kwokctl delete cluster --name "${CLUSTER}" >/dev/null 2>&1 || true
  fi
  [ $status -eq 0 ] || say "artifacts in ${ARTIFACTS} (controller.log + evidence yaml)"
}
trap cleanup EXIT

# retry <seconds> <description> <cmd...> — polls every 2 s.
retry() {
  local deadline=$(( $(date +%s) + $1 )) desc=$2; shift 2
  until "$@" >/dev/null 2>&1; do
    if [ "$(date +%s)" -gt "${deadline}" ]; then
      fail "timeout waiting for: ${desc}"
    fi
    sleep 2
  done
}

servers_json() { curl -fsS "http://${DEBUG_ADDR}/servers"; }
count_status() { servers_json | grep -o "\"Status\":\"$1\"" | wc -l | tr -d ' '; }
status_is()    { [ "$(count_status "$1")" = "$2" ]; }

# ─── 0. Preflight ────────────────────────────────────────────────────────
say "preflight"
for bin in kwokctl kwok kubectl go curl; do
  command -v "$bin" >/dev/null || fail "$bin not found (brew install kwok kubectl go)"
done
RUNTIME="${KWOK_RUNTIME:-}"
if [ -z "${RUNTIME}" ]; then
  if command -v podman >/dev/null && podman info >/dev/null 2>&1; then RUNTIME=podman
  elif command -v docker >/dev/null && docker info >/dev/null 2>&1; then RUNTIME=docker
  else fail "no running container runtime (podman or docker) — or set KWOK_RUNTIME=binary"
  fi
fi
mkdir -p "${ARTIFACTS}"
ok "runtime: ${RUNTIME}"

# ─── 1. kwok cluster ─────────────────────────────────────────────────────
say "creating kwok cluster '${CLUSTER}' (runtime ${RUNTIME})"
kwokctl delete cluster --name "${CLUSTER}" >/dev/null 2>&1 || true
kwokctl create cluster --name "${CLUSTER}" --runtime "${RUNTIME}" --wait 120s \
  >"${ARTIFACTS}/kwokctl-create.log" 2>&1 || { tail -20 "${ARTIFACTS}/kwokctl-create.log"; fail "kwokctl create cluster"; }
export KUBECONFIG="${HOME}/.kwok/clusters/${CLUSTER}/kubeconfig.yaml"
[ -f "${KUBECONFIG}" ] || fail "kubeconfig not found at ${KUBECONFIG}"
retry 60 "apiserver ready" kubectl get --raw /readyz
ok "cluster up (KUBECONFIG=${KUBECONFIG})"

# ─── 2. CRDs — karpenter-core (from the pinned module) + ours ────────────
say "installing CRDs"
KARPENTER_DIR="$(cd "${MODULE_ROOT}" && go list -m -f '{{.Dir}}' sigs.k8s.io/karpenter)"
kubectl apply -f "${KARPENTER_DIR}/pkg/apis/crds/" >/dev/null
kubectl apply -f "${MODULE_ROOT}/config/crd/" >/dev/null
ok "CRDs applied (karpenter-core $(basename "${KARPENTER_DIR}") + ScalewayEMNodeClass)"

# ─── 3. e2e controller (core v1.14 + our provider + FakeBackend) ─────────
say "building and starting the e2e controller"
(cd "${MODULE_ROOT}" && go build -o "${ARTIFACTS}/e2e-controller" ./hack/kwok-e2e/controller)
env KUBECONFIG="${KUBECONFIG}" \
  DISABLE_LEADER_ELECTION=true \
  FEATURE_GATES="StaticCapacity=true" \
  METRICS_PORT=8087 HEALTH_PROBE_PORT=8088 \
  LOG_LEVEL=debug \
  E2E_DEBUG_ADDR="${DEBUG_ADDR}" \
  "${ARTIFACTS}/e2e-controller" >"${CONTROLLER_LOG}" 2>&1 &
CONTROLLER_PID=$!
disown "${CONTROLLER_PID}" 2>/dev/null || true
retry 60 "controller health probe" curl -fsS "http://127.0.0.1:8088/healthz"
retry 30 "debug endpoint (3 stopped fake servers)" status_is stopped 3
ok "controller up (pid ${CONTROLLER_PID}), fake pool: 3 stopped servers"

# ─── 4. NodeClass + static NodePool, Ready gate ──────────────────────────
say "applying ScalewayEMNodeClass + static NodePool (replicas 0)"
kubectl apply -f "${HERE}/manifests/" >/dev/null
retry "${TIMEOUT}" "NodeClass Ready=True" \
  kubectl wait --for=condition=Ready scalewayemnodeclass/metal-pool --timeout=5s
ok "NodeClass Ready (pool inventoried by the status controller)"

# ─── 5. Scale up 0→1 : Create() → join → Registered → Initialized ───────
say "scaling NodePool metal: replicas 0 -> 1"
kubectl patch nodepool metal --type=merge -p '{"spec":{"replicas":1}}' >/dev/null
retry "${TIMEOUT}" "a NodeClaim to exist" \
  sh -c 'kubectl get nodeclaims -o name 2>/dev/null | grep -q .'
NC="$(kubectl get nodeclaims -o jsonpath='{.items[0].metadata.name}')"
retry "${TIMEOUT}" "NodeClaim ${NC} providerID" \
  sh -c "kubectl get nodeclaim ${NC} -o jsonpath='{.status.providerID}' | grep -q scaleway-em"
NC_PID="$(kubectl get nodeclaim "${NC}" -o jsonpath='{.status.providerID}')"
case "${NC_PID}" in
  scaleway-em://fr-par-2/e2e00000-*) ok "NodeClaim ${NC} launched with providerID ${NC_PID}" ;;
  *) fail "unexpected providerID: ${NC_PID}" ;;
esac
retry 30 "fake server powered on (1 ready)" status_is ready 1

retry "${TIMEOUT}" "NodeClaim Registered=True" \
  kubectl wait --for=condition=Registered "nodeclaim/${NC}" --timeout=5s
retry "${TIMEOUT}" "NodeClaim Initialized=True" \
  kubectl wait --for=condition=Initialized "nodeclaim/${NC}" --timeout=5s
ok "NodeClaim Registered + Initialized"

NODE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
NODE_PID="$(kubectl get node "${NODE}" -o jsonpath='{.spec.providerID}')"
[ "${NODE_PID}" = "${NC_PID}" ] || fail "providerID mismatch: node='${NODE_PID}' nodeclaim='${NC_PID}'"
ok "byte-identical providerID on Node ${NODE} (C3): ${NODE_PID}"

kubectl get nodeclaim "${NC}" -o yaml >"${ARTIFACTS}/nodeclaim-registered.yaml"
kubectl get node "${NODE}" -o yaml >"${ARTIFACTS}/node-joined.yaml"
servers_json >"${ARTIFACTS}/servers-after-scale-up.json"

# ─── 6. Scale down 1→0 : drain → Delete() → stopped → finalized ─────────
say "scaling NodePool metal: replicas 1 -> 0"
kubectl patch nodepool metal --type=merge -p '{"spec":{"replicas":0}}' >/dev/null
retry "${TIMEOUT}" "NodeClaim ${NC} finalized (deleted)" \
  sh -c "! kubectl get nodeclaim ${NC} >/dev/null 2>&1"
retry "${TIMEOUT}" "Node ${NODE} deleted" \
  sh -c "! kubectl get node ${NODE} >/dev/null 2>&1"
retry 30 "fake server powered off (3 stopped)" status_is stopped 3
servers_json >"${ARTIFACTS}/servers-after-scale-down.json"
ok "NodeClaim finalized, node gone, fake server back to stopped"

echo
ok "kwok e2e PASS in ${SECONDS}s — full NodeClaim cycle 0->1->0 (Create/join/Registered/Initialized/drain/Delete)"
