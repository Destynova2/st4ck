#!/usr/bin/env bash
# ADR-043: stop legacy bootstrap reconciliation without uninstalling releases.
set -euo pipefail
: "${KUBECONFIG:?Select the target cluster explicitly}"
case "${1:---check}" in
  --check) apply=0 ;;
  --prepare) apply=1 ;;
  *) echo 'Usage: flux-migrate-ownership.sh [--check|--prepare]' >&2; exit 2 ;;
esac
if [ "$apply" = 1 ]; then
  kubectl -n flux-system patch kustomization management --type merge \
    -p '{"spec":{"suspend":true,"prune":false}}'
fi
for entry in kube-system:cilium secrets:openbao-infra secrets:openbao-app cert-manager:cert-manager; do
  IFS=: read -r namespace name <<< "$entry"
  release=$(kubectl -n "$namespace" get helmrelease "$name" --ignore-not-found -o json)
  [ -n "$release" ] || continue
  echo "Legacy HelmRelease: $namespace/$name"
  [ "$apply" = 1 ] || continue
  kubectl -n "$namespace" patch helmrelease "$name" --type merge -p '{"spec":{"suspend":true}}'
  # Never remove a finalizer while a Helm operation is still running.
  release=$(kubectl -n "$namespace" get helmrelease "$name" -o json)
  if ! printf '%s' "$release" | jq -e '
    .metadata.deletionTimestamp == null
    and ([.status.conditions[]? | select(.type == "Reconciling" and .status == "True")] | length) == 0
    and ([.metadata.finalizers[]? | select(. != "finalizers.fluxcd.io")] | length) == 0' >/dev/null; then
    echo "Release $namespace/$name is deleting, reconciling or has another finalizer; leave suspended and inspect." >&2
    exit 1
  fi
  # Orphan only the exact safe revision inspected above. A concurrent status
  # or finalizer update must fail closed rather than erase another owner.
  patch=$(printf '%s' "$release" | jq -c '[
    {op:"test", path:"/metadata/uid", value:.metadata.uid},
    {op:"test", path:"/metadata/resourceVersion", value:.metadata.resourceVersion},
    {op:"add", path:"/metadata/finalizers", value:[]}
  ]')
  kubectl -n "$namespace" patch helmrelease "$name" --type json -p "$patch"
  kubectl -n "$namespace" delete helmrelease "$name" --wait=true
done
if [ "$apply" = 1 ]; then
  echo 'Prepared. Keep root pruning disabled through the first new revision (ADR-043).'
fi
