#!/usr/bin/env bash
# An unsealed pod can lead its own isolated Raft: Ready alone is insufficient.
set -euo pipefail
: "${KUBECONFIG:?Select the target cluster explicitly}"
release=${1:?Expected openbao-infra or openbao-app}
case "$release" in openbao-infra|openbao-app) ;; *) exit 2 ;; esac

for ((attempt=0; attempt<12; attempt++)); do
  leader=""
  leaders=0
  healthy=1
  for ordinal in 0 1 2; do
    if ! state=$(kubectl -n secrets exec "$release-$ordinal" -c openbao -- \
        env BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true BAO_CLIENT_TIMEOUT=10s \
        bao read -format=json sys/leader); then
      healthy=0; break
    fi
    if ! address=$(printf '%s' "$state" | jq -er '(.data // .) | select(.ha_enabled == true) | .leader_address | select(length > 0)'); then
      healthy=0; break
    fi
    if [ -n "$leader" ] && [ "$leader" != "$address" ]; then healthy=0; break; fi
    leader=$address
    if printf '%s' "$state" | jq -e '(.data // .).is_self == true' >/dev/null; then
      leaders=$((leaders + 1))
    fi
  done
  if [ "$healthy" = 1 ] && [ "$leaders" = 1 ]; then
    echo "$release: all three pods agree on one active leader"
    exit 0
  fi
  sleep 5
done
echo "$release: leader agreement failed. Inspect Raft and TLS; PVCs have been preserved." >&2
exit 1
