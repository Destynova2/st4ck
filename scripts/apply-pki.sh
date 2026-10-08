#!/usr/bin/env bash
# Bootstrap at one replica only when needed, then persist three in Helm state.
set -euo pipefail
: "${KUBECONFIG:?Select the target cluster explicitly}"
[ "$#" -gt 0 ] || { echo 'Expected the PKI tofu apply command' >&2; exit 2; }
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
bootstrap='[]'
for release in openbao-infra openbao-app; do
  state=$(kubectl -n secrets get statefulset "$release" --ignore-not-found -o json)
  if [ -z "$state" ]; then
    volumes=$(kubectl -n secrets get pvc -l "app.kubernetes.io/instance=$release" -o json)
    if ! printf '%s' "$volumes" | jq -e '.items | length == 0' >/dev/null; then
      echo "$release: existing PVCs without StatefulSet require an explicit recovery; refusing bootstrap." >&2
      exit 1
    fi
    replicas=0
  else
    replicas=$(printf '%s' "$state" | jq -er '.spec.replicas')
  fi
  case "$replicas" in
    0|1) bootstrap=$(printf '%s' "$bootstrap" | jq -c --arg name "$release" '. + [$name]') ;;
    3) bash "$here/check-openbao-ha.sh" "$release" ;;
    *) echo "$release: unexpected replica count $replicas; inspect before applying." >&2; exit 1 ;;
  esac
done
if [ "$bootstrap" != '[]' ]; then
  "$@" "-var=openbao_bootstrap_releases=$bootstrap"
fi
# Do not leave a successful bootstrap with one replica stored in Helm's manifest.
"$@" '-var=openbao_bootstrap_releases=[]'
