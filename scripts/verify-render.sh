#!/usr/bin/env bash
# Render only reachable HelmReleases, including vendored Git charts.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
for bin in kubectl helm kubeconform python3; do
  command -v "$bin" >/dev/null || { echo "Missing tool: $bin" >&2; exit 1; }
done
python3 scripts/verify-gitops.py --render-helm "$@"
