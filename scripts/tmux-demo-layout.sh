#!/usr/bin/env bash
# scripts/tmux-demo-layout.sh — 4-pane tmux session for `make demo-up`.
#
# Layout:
#   ┌──────────────┬──────────────┐
#   │ pane 0       │ pane 1       │
#   │ scaleway-up  │ pods watch   │
#   ├──────────────┼──────────────┤
#   │ pane 2       │ pane 3       │
#   │ healthmap    │ flux events  │
#   │              │ + auto-open  │
#   └──────────────┴──────────────┘
#
# Required env: ENV, INSTANCE, REGION (defaults: dev/demo/fr-par)
# Required tools: tmux, jq, scw, kubectl, make

set -euo pipefail

SESSION="st4ck-demo"
ENV="${ENV:-dev}"
INSTANCE="${INSTANCE:-demo}"
REGION="${REGION:-fr-par}"
NAMESPACE="${NAMESPACE:-st4ck-demo}"
CTX_ID="${NAMESPACE}-${ENV}-${INSTANCE}-${REGION}"
KC="$HOME/.kube/$CTX_ID"
REPO_DIR="${REPO_DIR:-/Users/ludwig/workspace/st4ck-demo}"

# Kill any stale session.
tmux kill-session -t "$SESSION" 2>/dev/null || true

# Create new session (default geometry 220x60 — adjust if terminal smaller).
tmux new-session -d -s "$SESSION" -x 220 -y 60 -c "$REPO_DIR"

# Splits:
#   0 -> 0 + 1 (horizontal: left | right)
tmux split-window -h -t "$SESSION:0" -c "$REPO_DIR"
#   0.0 -> 0.0 + 0.2 (vertical on left)
tmux split-window -v -t "$SESSION:0.0" -c "$REPO_DIR"
#   0.1 -> 0.1 + 0.3 (vertical on right)
tmux split-window -v -t "$SESSION:0.1" -c "$REPO_DIR"

# Pane 0 — scaleway-up: pick freshest Talos image and launch end-to-end deploy.
tmux send-keys -t "$SESSION:0.0" \
  "SCW_IMAGE_NAME=\$(scw instance image list zone=${REGION}-1 -o json 2>/dev/null | jq -r '.[] | select(.name | startswith(\"${NAMESPACE}-talos\")) | .name' | head -1) && echo \"Using image: \$SCW_IMAGE_NAME\" && make scaleway-up ENV=${ENV} INSTANCE=${INSTANCE} REGION=${REGION} NAMESPACE=${NAMESPACE} 2>&1 | tee /tmp/demo-up.log" C-m

# Pane 1 — pod watcher: blocks until kubeconfig appears, then watches pods.
tmux send-keys -t "$SESSION:0.1" \
  "echo 'Waiting for kubeconfig at ${KC}...' && while [ ! -f ${KC} ]; do sleep 5; done && KUBECONFIG=${KC} watch -n2 'kubectl get pods -A | tail -40'" C-m

# Pane 2 — healthmap (auto-refresh every 3s).
tmux send-keys -t "$SESSION:0.2" \
  "echo 'Waiting for kubeconfig at ${KC}...' && while [ ! -f ${KC} ]; do sleep 5; done && KUBECONFIG=${KC} CTX_ID=${CTX_ID} bash ${REPO_DIR}/scripts/healthmap.sh" C-m

# Pane 3 — auto-open UIs then stream flux events.
tmux send-keys -t "$SESSION:0.3" \
  "echo 'Waiting for kubeconfig at ${KC}...' && while [ ! -f ${KC} ]; do sleep 5; done && KUBECONFIG=${KC} CTX_ID=${CTX_ID} ENV=${ENV} INSTANCE=${INSTANCE} REGION=${REGION} REPO_DIR=${REPO_DIR} bash ${REPO_DIR}/scripts/auto-open-uis.sh; KUBECONFIG=${KC} kubectl -n flux-system get events --watch" C-m

# Title-bar each pane for clarity.
tmux select-pane -t "$SESSION:0.0" -T "scaleway-up"
tmux select-pane -t "$SESSION:0.1" -T "pods watch"
tmux select-pane -t "$SESSION:0.2" -T "healthmap"
tmux select-pane -t "$SESSION:0.3" -T "flux + UIs"
tmux set-option -t "$SESSION" pane-border-status top 2>/dev/null || true

echo "tmux session '$SESSION' created."
echo "Attach with:  tmux attach -t $SESSION"
echo "Detach with:  Ctrl-B then D"
echo "Kill all:     tmux kill-session -t $SESSION"
