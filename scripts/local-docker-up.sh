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
#   - talosctl >= 1.13 (brew install siderolabs/tap/talosctl)
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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="${1:-st4ck-local}"
KUBECONFIG_OUT="${HOME}/.kube/${NAME}-docker"
WORKERS="${WORKERS:-4}"
MEM_CP="${MEM_CP:-6GB}"
MEM_WORKER="${MEM_WORKER:-4GB}"

log() { printf '[local-docker] %s\n' "$*"; }
die() { printf '[local-docker] ERROR: %s\n' "$*" >&2; exit 1; }

command -v talosctl >/dev/null 2>&1 || die "talosctl required (brew install siderolabs/tap/talosctl)"
command -v helm     >/dev/null 2>&1 || die "helm required"
command -v kubectl  >/dev/null 2>&1 || die "kubectl required"

# ── Versions: single sources of truth ───────────────────────────────────
TALOS_VERSION=$(sed -n 's/^talos_version: *"\(.*\)"/\1/p' "${REPO_ROOT}/contexts/_defaults.yaml")
K8S_VERSION=$(sed -n 's/^k8s_version: *"\(.*\)"/\1/p' "${REPO_ROOT}/contexts/_defaults.yaml")
CILIUM_VERSION=$(sed -n 's/^ *cilium_version: "\(.*\)"/\1/p' "${REPO_ROOT}/clusters/management/versions-configmap.yaml")
[ -n "${TALOS_VERSION}" ] && [ -n "${K8S_VERSION}" ] && [ -n "${CILIUM_VERSION}" ] \
  || die "could not read version pins (contexts/_defaults.yaml, versions-configmap.yaml)"

# ── Container runtime socket (podman machine or docker) ────────────────
if [ -z "${DOCKER_HOST:-}" ] && command -v podman >/dev/null 2>&1; then
  SOCK=$(podman machine inspect --format '{{ .ConnectionInfo.PodmanSocket.Path }}' 2>/dev/null || true)
  [ -S "${SOCK}" ] || die "podman machine not running (podman machine start)"
  podman machine inspect --format '{{ .Rootful }}' | grep -q true \
    || die "podman machine must be ROOTFUL (see header) — Talos' nested containerd fails rootless"
  export DOCKER_HOST="unix://${SOCK}"
fi

# ── Cluster ─────────────────────────────────────────────────────────────
log "creating Talos ${TALOS_VERSION} / K8s ${K8S_VERSION} cluster '${NAME}' (native arch)"
# The built-in wait fails on coredns: expected — there is no CNI until
# Cilium lands below. `|| true` tolerates exactly that.
talosctl cluster create docker \
  --name "${NAME}" \
  --image "ghcr.io/siderolabs/talos:${TALOS_VERSION}" \
  --kubernetes-version "${K8S_VERSION}" \
  --workers "${WORKERS}" \
  --memory-controlplanes "${MEM_CP}" \
  --memory-workers "${MEM_WORKER}" \
  --config-patch "@${REPO_ROOT}/patches/cilium-cni.yaml" || true

# ── Kubeconfig (rewrite the API endpoint to the published port) ────────
CP="${NAME}-controlplane-1"
PORT=""
for _ in $(seq 1 60); do
  PORT=$(podman port "${CP}" 6443/tcp 2>/dev/null | head -1 | cut -d: -f2 || true)
  [ -n "${PORT}" ] && break
  sleep 5
done
[ -n "${PORT}" ] || die "no published 6443 port on ${CP} — cluster create failed?"

CTX=$(talosctl config contexts | awk -v n="${NAME}" '$0 ~ n {print $2}' | tail -1)
talosctl --context "${CTX}" -n 10.5.0.2 kubeconfig "${KUBECONFIG_OUT}" --force
sed -i.bak "s|https://10.5.0.2:6443|https://127.0.0.1:${PORT}|" "${KUBECONFIG_OUT}" && rm -f "${KUBECONFIG_OUT}.bak"
log "kubeconfig: ${KUBECONFIG_OUT}"

until kubectl --kubeconfig "${KUBECONFIG_OUT}" get nodes >/dev/null 2>&1; do sleep 5; done

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

kubectl --kubeconfig "${KUBECONFIG_OUT}" get nodes -o wide
log "done. Destroy with: make local-docker-down"
