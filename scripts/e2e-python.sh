#!/usr/bin/env bash
# Terraform's python3 must use the same preflight-checked interpreter.
set -euo pipefail
exec "${E2E_PYTHON:?}" "$@"
