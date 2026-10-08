#!/usr/bin/env bash
# Only the explicitly isolated workflow is supported. No implicit reuse/cleanup.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ "$#" -eq 0 ]; then
  : "${E2E_CONFIG:?Set E2E_CONFIG to a private isolated-run JSON file; see docs/how-to/e2e-isolated.md}"
  set -- --config "$E2E_CONFIG"
fi
exec "${E2E_PYTHON:-python3}" "$here/e2e-isolated.py" "$@"
