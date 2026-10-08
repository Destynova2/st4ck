#!/usr/bin/env bash
# Detect host-injected read-only mounts before deploying nested Kubernetes pods.
set -euo pipefail
context=${1:?Expected an explicit Talos context}
shift
[ "$#" -gt 0 ] || { echo "Expected at least one node address" >&2; exit 2; }
for node in "$@"; do
  mounts=$("${TALOSCTL:-talosctl}" --context "$context" -n "$node" read /proc/1/mountinfo)
  if printf '%s\n' "$mounts" | awk '
      $5 == "/run/secrets" && ("," $6 ",") ~ /,ro,/ { found = 1 }
      END { exit !found }'; then
    echo "ERROR: $node has a read-only /run/secrets injected by the container host." >&2
    echo "Use a dedicated Podman VM without default mounts.conf injections; see docs/how-to/test-local.md." >&2
    exit 1
  fi
done
