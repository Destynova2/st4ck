#!/usr/bin/env bash
# Schedulers must provision a NEW dedicated engine and config for every run.
# Missing prerequisites fail; never push to shared Gitea or report SKIP as PASS.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec bash "$here/e2e-local.sh" "$@"
