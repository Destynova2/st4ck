#!/usr/bin/env bash
# Keep Flux controllers alive while their workloads and child graphs are pruned.
set -euo pipefail
: "${KUBECONFIG:?Select the target cluster explicitly}"
case "${1:-}" in
  ''|--check) ;;
  *) echo 'Usage: flux-down.sh [--check]' >&2; exit 2 ;;
esac
base_children=(identity-apps identity-database identity-backup-credentials cnpg-operator
               identity-prerequisites storage-zot storage-zot-eso storage-backup
               storage-bootstrap storage-garage storage-secrets autoscaling monitoring-flux-alerts
               monitoring-vm-stack security-kyverno-policies security-kyverno)

check_disarmed() {
  local controllers crd releases graphs allowed
  # Deployment metadata has no chart label; inspect its pod-template label too.
  # This is deliberately restricted to the maintained native release/namespace.
  controllers=$(kubectl -n autoscaling get deployments,pods -o json)
  if ! printf '%s' "$controllers" | jq -e '
    def native_name: . == "karpenter-scaleway" or . == "autoscaling-karpenter-scaleway";
    (.items | type == "array") and
    ([.items[] | select(
      (.metadata.name | native_name) or
      .metadata.labels["app.kubernetes.io/name"] == "karpenter-scaleway" or
      (.metadata.labels["app.kubernetes.io/instance"] | native_name) or
      (.spec.template.metadata.labels["app.kubernetes.io/instance"] | native_name) or
      .spec.template.metadata.labels["app.kubernetes.io/name"] == "karpenter-scaleway") |
      select((.kind == "Deployment" and
        ((.spec.replicas // 1) > 0 or (.status.replicas // 0) > 0)) or
        (.kind == "Pod" and .status.phase != "Succeeded" and .status.phase != "Failed"))]
      | length == 0)' >/dev/null; then
    echo 'Disarm native provider allocation and wait for its pods to stop before base teardown; this script never scales controllers.' >&2
    return 1
  fi
  crd=$(kubectl get crd helmreleases.helm.toolkit.fluxcd.io --ignore-not-found -o name)
  if [ -n "$crd" ]; then
    releases=$(kubectl -n autoscaling get helmreleases -o json)
    if ! printf '%s' "$releases" | jq -e '
      (.items | type == "array") and
      ([.items[] | select(.metadata.name == "karpenter-scaleway" or
        .metadata.labels["app.kubernetes.io/name"] == "karpenter-scaleway" or
        .spec.chart.spec.chart == "./karpenter-provider-scaleway/charts/karpenter-scaleway") |
        select(.spec.suspend != true)] | length == 0)' >/dev/null; then
      echo 'Suspend or remove the native provider HelmRelease so it cannot rearm allocation during base teardown.' >&2
      return 1
    fi
  fi
  crd=$(kubectl get crd kustomizations.kustomize.toolkit.fluxcd.io --ignore-not-found -o name)
  [ -n "$crd" ] || return 0
  graphs=$(kubectl -n flux-system get kustomizations -o json)
  allowed=$(printf '%s\n' management "${base_children[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')
  if ! printf '%s' "$graphs" | jq -e --argjson allowed "$allowed" '
    (.items | type == "array") and
    ([.items[].metadata.name | select(. as $name | $allowed | index($name) == null)] | length == 0)' >/dev/null; then
    echo 'Remove optional/unexpected Flux graphs explicitly before base teardown; only the maintained base graph is supported.' >&2
    return 1
  fi
}

check_handles() {
  # Leases can outlive a failed launch even when the core removed its NodeClaim.
  local reservations nodeclaims_crd claims
  reservations=$(kubectl get leases -A -l karpenter.scaleway.st4ck.io/reservation=true -o json)
  if ! printf '%s' "$reservations" | jq -e '(.items | type == "array") and (.items | length == 0)' >/dev/null; then
    echo 'Reconcile all Scaleway reservations before removing Flux or its controller.' >&2
    return 1
  fi
  nodeclaims_crd=$(kubectl get crd nodeclaims.karpenter.sh --ignore-not-found -o name)
  if [ -n "$nodeclaims_crd" ]; then
    claims=$(kubectl get nodeclaims -o json)
    if ! printf '%s' "$claims" | jq -e '(.items | type == "array") and (.items | length == 0)' >/dev/null; then
      echo 'Drain all Karpenter NodeClaims before removing Flux or the autoscaling controller.' >&2
      return 1
    fi
  fi
}

check_disarmed
check_handles
[ "${1:-}" != "--check" ] || exit 0
crd=$(kubectl get crd kustomizations.kustomize.toolkit.fluxcd.io --ignore-not-found -o name)
[ -n "$crd" ] || exit 0
root=$(kubectl -n flux-system get kustomization management --ignore-not-found -o name)
[ -n "$root" ] || exit 0
kubectl -n flux-system patch kustomization management --type merge -p '{"spec":{"suspend":true}}'
# Recheck after suspending the root, before the first destructive operation.
check_disarmed
check_handles
# Leaves before their dependencies; management is suspended throughout.
for name in "${base_children[@]}"; do
  child=$(kubectl -n flux-system get kustomization "$name" --ignore-not-found -o name)
  [ -n "$child" ] || continue
  kubectl -n flux-system patch kustomization "$name" --type merge \
    -p '{"spec":{"prune":true,"deletionPolicy":"WaitForTermination"}}'
  kubectl -n flux-system delete kustomization "$name" --ignore-not-found --wait=true --timeout=10m
done
kubectl -n flux-system patch kustomization management --type merge \
  -p '{"spec":{"prune":true,"deletionPolicy":"WaitForTermination"}}'
kubectl -n flux-system delete kustomization management --wait=true --timeout=15m
