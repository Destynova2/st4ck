#!/usr/bin/env bash
# local-docker-up.sh — Talos-in-containers cluster on podman/docker,
# native arch (arm64 on Apple Silicon), with the platform's real CNI
# config (cni: none + kube-proxy disabled + Cilium from the version
# registry). Validated 2026-07-13 on podman 6 / Talos v1.12.9 / macOS.
#
# What this gives you: a disposable local cluster to exercise k8s
# stacks, Flux manifests and Cilium — WITHOUT libvirt or Scaleway.
# What it does NOT give you: the real Talos OS surface (kernel,
# machine-config install/upgrade paths) — use envs/local (KVM host) or
# Scaleway for that.
#
# Requirements:
#   - talosctl matching contexts/_defaults.yaml (override with TALOSCTL)
#   - podman machine in ROOTFUL mode (Talos' nested containerd needs
#     real privileges):  podman machine stop
#                        podman machine set --rootful
#                        podman machine start
#   - helm, kubectl
#
# Usage: bash scripts/local-docker-up.sh [cluster-name]   (default: st4ck-local)
#
# Sizing (env-overridable): WORKERS=4 MEM_CP=6GB MEM_WORKER=4GB.
# The talosctl defaults (2GiB/node) cgroup-thrash under the full stack —
# both E2E crashes of 2026-07-15 were that limit, not the podman VM.
# The CP needs ~2x a worker: etcd + apiserver watches for 5 nodes and
# the full Flux graph, PLUS every DaemonSet (cilium, tetragon,
# kubescape, log collectors) also runs there. Measured: 3GB CP
# thrashes at 2.9GB while workers sit at ~2.2/3GB idle-ish — but the
# worker hosting vmsingle+trivy-server ALSO thrashes at 3GB once PVCs
# bind (NotReady at 2.9GB) → 4GB per worker. Full-stack budget:
# 6 + 4x4 = 22GB of limits on a 24GiB podman VM (limits != usage;
# measured usage ~14GB total).
# NOTE: the docker provisioner is single-controlplane by CLI design
# (talosctl >= 1.13 only has --controlplanes on qemu, Linux-only) —
# etcd quorum / 3-CP behaviour needs VMs (envs/local or Scaleway).

set -euo pipefail

# Tofu-first mode (test-local.md niveau 3.4 — matches the production
# pipeline order): SKIP_CILIUM=1 leaves the cluster CNI-less (nodes stay
# NotReady, API up — same state a fresh Scaleway cluster is in) so that
# `make k8s-cni-apply ENV=dev INSTANCE=docker REGION=local` owns Cilium
# exactly like day-1. KUBECONFIG_OUT overrides the kubeconfig path (use
# ~/.kube/st4ck-dev-docker-local to match the Makefile context).

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="${1:-st4ck-local}"
KUBECONFIG_OUT="${KUBECONFIG_OUT:-${HOME}/.kube/${NAME}-docker}"
WORKERS="${WORKERS:-4}"
MEM_CP="${MEM_CP:-6GB}"
MEM_WORKER="${MEM_WORKER:-4GB}"
TALOSCTL="${TALOSCTL:-talosctl}"

log() { printf '[local-docker] %s\n' "$*"; }
die() { printf '[local-docker] ERROR: %s\n' "$*" >&2; exit 1; }

command -v "$TALOSCTL" >/dev/null 2>&1 || die "talosctl required (set TALOSCTL to the pinned CLI)"
command -v helm     >/dev/null 2>&1 || die "helm required"
command -v kubectl  >/dev/null 2>&1 || die "kubectl required"

# ── Versions: single sources of truth ───────────────────────────────────
TALOS_VERSION=$(sed -n 's/^talos_version: *"\(.*\)"/\1/p' "${REPO_ROOT}/contexts/_defaults.yaml")
K8S_VERSION=$(sed -n 's/^k8s_version: *"\(.*\)"/\1/p' "${REPO_ROOT}/contexts/_defaults.yaml")
CILIUM_VERSION=$(sed -n 's/^ *cilium_version: "\(.*\)"/\1/p' "${REPO_ROOT}/clusters/management/versions-configmap.yaml")
[ -n "${TALOS_VERSION}" ] && [ -n "${K8S_VERSION}" ] && [ -n "${CILIUM_VERSION}" ] \
  || die "could not read version pins (contexts/_defaults.yaml, versions-configmap.yaml)"

# Container mount layouts are version-specific, even when the API is compatible.
CLI_VERSION=$("$TALOSCTL" version --client --short | awk '/^Talos / {print $2}')
[ "$CLI_VERSION" = "$TALOS_VERSION" ] \
  || die "container provisioning requires talosctl $TALOS_VERSION; found $CLI_VERSION (set TALOSCTL)"

# ── Container runtime socket (podman machine or docker) ────────────────
if [ -z "${DOCKER_HOST:-}" ] && command -v podman >/dev/null 2>&1; then
  SOCK=$(podman machine inspect --format '{{ .ConnectionInfo.PodmanSocket.Path }}' 2>/dev/null || true)
  [ -S "${SOCK}" ] || die "podman machine not running (podman machine start)"
  podman machine inspect --format '{{ .Rootful }}' | grep -q true \
    || die "podman machine must be ROOTFUL (see header) — Talos' nested containerd fails rootless"
  export DOCKER_HOST="unix://${SOCK}"
fi

# ── Cluster ─────────────────────────────────────────────────────────────
# Purge des contextes talosconfig homonymes : les cycles create/destroy
# les accumulent et talosctl renomme alors le nouveau en NAME-<n> — le
# lookup attrape un contexte mort ("failed to determine endpoints",
# E2E run 11). destroy ne nettoie pas toujours derriere lui.
for c in $("$TALOSCTL" config contexts 2>/dev/null | awk 'NR>1 {print $2}' | grep -E "^${NAME}(-[0-9]+)?$" || true); do
  "$TALOSCTL" config remove "$c" --noconfirm >/dev/null 2>&1 || true
done
log "creating Talos ${TALOS_VERSION} / K8s ${K8S_VERSION} cluster '${NAME}' (native arch)"
# Talos 1.12 Docker always waits for CNI, so install it concurrently below.
# REGISTRY_MIRROR=host:port → mirrors containerd vers un store hauler
# servi sur le Mac (E2E rapide / air-gap partiel — ADR-034). Chemins :
# 2-segments servis nus (transparent) ; mono-segment normalises sous
# library/ → fallback upstream par containerd (trou assume, kube-*).
MIRROR_PATCH=""
if [ -n "${REGISTRY_MIRROR:-}" ]; then
  MIRROR_PATCH=$(mktemp)
  cat > "${MIRROR_PATCH}" <<MEOF
machine:
  registries:
    mirrors:
      docker.io:
        endpoints: ["http://${REGISTRY_MIRROR}"]
      ghcr.io:
        endpoints: ["http://${REGISTRY_MIRROR}"]
      quay.io:
        endpoints: ["http://${REGISTRY_MIRROR}"]
      public.ecr.aws:
        endpoints: ["http://${REGISTRY_MIRROR}"]
      registry.k8s.io:
        # Ferme le trou mono-segment (ADR-034 point ouvert n°1, valide
        # au curl 2026-07-18) : hauler normalise kube-* sous library/.
        # Deux endpoints + overridePath : /v2/library sert les
        # mono-segments, /v2 les 2-segments (coredns/...) — containerd
        # bascule sur 404.
        overridePath: true
        endpoints:
          - "http://${REGISTRY_MIRROR}/v2/library"
          - "http://${REGISTRY_MIRROR}/v2"
MEOF
  log "registry mirror actif: ${REGISTRY_MIRROR}"
fi

CREATE_LOG=$(mktemp)
CREATE_PID=""
cleanup() {
  if [ -n "$CREATE_PID" ] && kill -0 "$CREATE_PID" 2>/dev/null; then
    kill "$CREATE_PID"
    wait "$CREATE_PID" || : # Intentional cancellation of our readiness checker.
  fi
  rm -f "$CREATE_LOG"
  [ -z "$MIRROR_PATCH" ] || rm -f "$MIRROR_PATCH"
}
trap cleanup EXIT
check_create() {
  if [ -n "$CREATE_PID" ] && ! kill -0 "$CREATE_PID" 2>/dev/null; then
    if ! wait "$CREATE_PID"; then
      CREATE_PID=""
      cat "$CREATE_LOG" >&2
      die "Talos cluster creation failed"
    fi
    CREATE_PID=""
  fi
}

"$TALOSCTL" cluster create docker \
  --name "${NAME}" \
  --image "ghcr.io/siderolabs/talos:${TALOS_VERSION}" \
  --kubernetes-version "${K8S_VERSION}" \
  --workers "${WORKERS}" \
  --memory-controlplanes "${MEM_CP}" \
  --memory-workers "${MEM_WORKER}" \
  --config-patch "@${REPO_ROOT}/patches/cilium-cni.yaml" \
  ${MIRROR_PATCH:+--config-patch "@${MIRROR_PATCH}"} >"$CREATE_LOG" 2>&1 &
CREATE_PID=$!

# ── Kubeconfig (rewrite the API endpoint to the published port) ────────
CP="${NAME}-controlplane-1"
PORT=""
for _ in $(seq 1 60); do
  check_create
  PORT=$(podman port "${CP}" 6443/tcp 2>/dev/null | head -1 | cut -d: -f2 || true)
  [ -n "${PORT}" ] && break
  sleep 5
done
[ -n "${PORT}" ] || die "no published 6443 port on ${CP} — cluster create failed?"

CTX=$("$TALOSCTL" config contexts | awk -v n="${NAME}" '$2 == n {print $2}' | tail -1)
[ -n "${CTX}" ] || CTX=$("$TALOSCTL" config contexts | awk -v n="${NAME}" '$2 ~ "^"n"-[0-9]+$" {print $2}' | tail -1)
exported=0
for _ in $(seq 1 60); do
  check_create
  if [ -z "$CTX" ]; then
    CTX=$("$TALOSCTL" config contexts | awk -v n="${NAME}" '$2 == n {print $2}' | tail -1)
  fi
  if "$TALOSCTL" --context "${CTX}" -n 10.5.0.2 kubeconfig "${KUBECONFIG_OUT}" --force; then
    exported=1
    break
  fi
  sleep 5
done
[ "$exported" = 1 ] || die "Talos did not export a kubeconfig"
sed -i.bak "s|https://10.5.0.2:6443|https://127.0.0.1:${PORT}|" "${KUBECONFIG_OUT}" && rm -f "${KUBECONFIG_OUT}.bak"
log "kubeconfig: ${KUBECONFIG_OUT}"

ready=0
for _ in $(seq 1 60); do
  check_create
  if kubectl --kubeconfig "${KUBECONFIG_OUT}" --request-timeout=10s get --raw /readyz >/dev/null; then
    ready=1
    break
  fi
  sleep 5
done
[ "$ready" = 1 ] || die "Kubernetes API did not become ready"

# Registered nodes prove creation completed even when CNI readiness is deferred.
registered=0
for _ in $(seq 1 60); do
  check_create
  count=$(kubectl --kubeconfig "$KUBECONFIG_OUT" --request-timeout=10s get nodes -o name | wc -l | tr -d ' ')
  if [ "$count" -eq "$((WORKERS + 1))" ]; then registered=1; break; fi
  sleep 5
done
[ "$registered" = 1 ] || die "not all expected nodes registered"

# Fedora subscription mounts propagate through hostPath /run into node agents.
for ordinal in $(seq 2 "$((WORKERS + 2))"); do
  TALOSCTL="$TALOSCTL" bash "${REPO_ROOT}/scripts/check-talos-container-mounts.sh" \
    "$CTX" "10.5.0.${ordinal}"
done

if [ "${SKIP_CILIUM:-0}" = "1" ]; then
  # Tofu-first mode: leave the cluster CNI-less. Next step:
  #   make k8s-cni-apply ENV=dev INSTANCE=docker REGION=local [VB_PORT=...]
  kubectl --kubeconfig "${KUBECONFIG_OUT}" get nodes
  log "SKIP_CILIUM=1 — nodes stay NotReady until k8s-cni-apply (by design)."
  log "done. Destroy with: make local-docker-down"
  exit 0
fi

# ── Cilium (platform values, version registry pin) ─────────────────────
# helm template + apply instead of `helm install`: same rendered result,
# no release state needed for a disposable cluster.
log "installing Cilium ${CILIUM_VERSION} (kube-proxy-free, platform values)"
helm template cilium cilium --repo https://helm.cilium.io \
  --version "${CILIUM_VERSION}" --namespace kube-system \
  --values "${REPO_ROOT}/stacks/cni/flux/values.yaml" \
  | kubectl --kubeconfig "${KUBECONFIG_OUT}" apply -f - >/dev/null

log "waiting for nodes Ready (CNI up)..."
kubectl --kubeconfig "${KUBECONFIG_OUT}" wait --for=condition=Ready nodes --all --timeout=300s
kubectl --kubeconfig "${KUBECONFIG_OUT}" -n kube-system wait --for=condition=Ready pods -l k8s-app=kube-dns --timeout=300s

if [ -n "$CREATE_PID" ]; then
  if ! wait "$CREATE_PID"; then
    CREATE_PID=""
    cat "$CREATE_LOG" >&2
    die "Talos final health checks failed"
  fi
  CREATE_PID=""
fi

kubectl --kubeconfig "${KUBECONFIG_OUT}" get nodes -o wide
log "done. Destroy with: make local-docker-down"
