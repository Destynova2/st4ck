#!/usr/bin/env bash
# scripts/healthmap.sh — real-time cluster health map (auto-refresh every 3s).
#
# Reads KUBECONFIG (or derives it from CTX_ID) and prints a snapshot of:
#   - node Ready states + age
#   - per-namespace pod counts (Running / total) with status icon
#   - HelmRelease Ready totals (if any)
#
# Used by `make demo-up` (tmux pane 2). Safe to run standalone:
#   CTX_ID=st4ck-dev-demo-fr-par bash scripts/healthmap.sh

set -uo pipefail

CTX_ID="${CTX_ID:-st4ck-dev-demo-fr-par}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/$CTX_ID}"
export KUBECONFIG

while true; do
  clear
  printf '════════════ CLUSTER HEALTHMAP %s ═══════════\n' "$(date +%H:%M:%S)"
  printf 'KUBECONFIG=%s\n\n' "$KUBECONFIG"

  if ! kubectl version --client=false >/dev/null 2>&1; then
    echo "  (cluster not reachable yet — retry in 3s)"
    sleep 3
    continue
  fi

  echo "▶ NODES"
  kubectl get nodes --no-headers 2>/dev/null \
    | awk '{printf "  %-40s %-10s age=%s\n", $1, $2, $4}'
  echo ""

  echo "▶ PODS BY NAMESPACE"
  while IFS= read -r ns; do
    [ -z "$ns" ] && continue
    total=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [ "$total" -eq 0 ] && continue
    running=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -c " Running ")
    bad=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null \
            | grep -vE " (Running|Completed) " | wc -l | tr -d ' ')
    icon="OK "
    [ "$bad" -gt 0 ] && icon="..."
    printf '  [%s] %-30s %d/%d Running\n' "$icon" "$ns" "$running" "$total"
  done < <(kubectl get ns --no-headers 2>/dev/null | awk '{print $1}')
  echo ""

  echo "▶ HELMRELEASES"
  hr_total=$(kubectl get hr -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  hr_ready=$(kubectl get hr -A --no-headers 2>/dev/null | awk '$4=="True"' | wc -l | tr -d ' ')
  printf '  %s/%s Ready\n' "$hr_ready" "$hr_total"
  echo ""

  echo "▶ FLUX KUSTOMIZATIONS"
  ks_total=$(kubectl get ks -n flux-system --no-headers 2>/dev/null | wc -l | tr -d ' ')
  ks_ready=$(kubectl get ks -n flux-system --no-headers 2>/dev/null | awk '$2=="True"' | wc -l | tr -d ' ')
  printf '  %s/%s Ready\n' "$ks_ready" "$ks_total"

  sleep 3
done
