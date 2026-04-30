#!/usr/bin/env bash
# scripts/tmux-demo-attach.sh — convenience wrapper to attach to the demo session.
set -euo pipefail
SESSION="${SESSION:-st4ck-demo}"
exec tmux attach -t "$SESSION"
