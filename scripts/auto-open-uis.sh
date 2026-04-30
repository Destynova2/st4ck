#!/usr/bin/env bash
# scripts/auto-open-uis.sh — wait for known UIs to become Ready, auto-launch them.
#
# Polls each (namespace, service) tuple until the Service exists, then triggers
# the matching `make scaleway-<ui>` target (which port-forwards + open's the
# browser via Make).
#
# Used by `make demo-up` (tmux pane 3). Standalone:
#   CTX_ID=st4ck-dev-demo-fr-par bash scripts/auto-open-uis.sh

set -uo pipefail

CTX_ID="${CTX_ID:-st4ck-dev-demo-fr-par}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/$CTX_ID}"
export KUBECONFIG

REPO_DIR="${REPO_DIR:-/Users/ludwig/workspace/st4ck-demo}"
ENV="${ENV:-dev}"
INSTANCE="${INSTANCE:-demo}"
REGION="${REGION:-fr-par}"

# (UI label, namespace, svc name, make target)
SERVICES=(
  "headlamp|monitoring|headlamp|scaleway-headlamp"
  "grafana|monitoring|grafana|scaleway-grafana"
  "harbor|storage|harbor-portal|scaleway-harbor"
)

wait_for_svc() {
  local label=$1 ns=$2 svc=$3 max=${4:-600}
  local i
  for i in $(seq 1 "$max"); do
    if kubectl -n "$ns" get svc "$svc" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

echo "[auto-open-uis] watching for UI services on $CTX_ID..."

for entry in "${SERVICES[@]}"; do
  IFS='|' read -r label ns svc target <<< "$entry"
  echo "[auto-open-uis] waiting for $label ($ns/$svc) ..."
  if wait_for_svc "$label" "$ns" "$svc" 600; then
    echo "[auto-open-uis] $label READY — invoking 'make $target'"
    (cd "$REPO_DIR" && \
      make "$target" ENV="$ENV" INSTANCE="$INSTANCE" REGION="$REGION" 2>&1 | head -20) || \
      echo "[auto-open-uis] WARN: 'make $target' returned non-zero"
  else
    echo "[auto-open-uis] TIMEOUT waiting for $label after 10min — skipping"
  fi
done

echo "[auto-open-uis] all services attempted. Demo ready."
