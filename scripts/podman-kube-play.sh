#!/usr/bin/env bash
# Disable implicit builds on local engines; remote clients cannot build.
set -euo pipefail
help=$(podman kube play --help)
options=()
if [[ "$help" == *--build* ]]; then
  options+=(--build=false)
fi
exec podman kube play ${options[@]+"${options[@]}"} "$@"
