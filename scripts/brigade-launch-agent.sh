#!/usr/bin/env bash
# brigade-launch-agent.sh — safe Claude launcher for brigade panes
#
# Usage: brigade-launch-agent.sh <role> <session>
#
# Reads system prompt from .claude/prompts/<role>-<session>.md and the initial
# message from .claude/prompts/<role>-<session>.initial.txt. Both via $(< file)
# to avoid shell re-parsing breakage on backticks, $(...), or unbalanced quotes.

set -euo pipefail

ROLE="${1:?Usage: $0 <role> <session>}"
SESSION="${2:?Usage: $0 <role> <session>}"

PROJECT_ROOT="${PROJECT_ROOT:-/Users/ludwig/workspace/st4ck}"
PROMPT_FILE="${PROJECT_ROOT}/.claude/prompts/${ROLE}-${SESSION}.md"
INITIAL_FILE="${PROJECT_ROOT}/.claude/prompts/${ROLE}-${SESSION}.initial.txt"

if [[ ! -f "${PROMPT_FILE}" ]]; then
  echo "ERROR: prompt file not found: ${PROMPT_FILE}" >&2
  exit 1
fi

PROMPT="$(< "${PROMPT_FILE}")"

if [[ -f "${INITIAL_FILE}" ]]; then
  INITIAL_MSG="$(< "${INITIAL_FILE}")"
else
  INITIAL_MSG="Begin now per the system prompt."
fi

declare -a EXTRA_FLAGS=()
case "${ROLE}" in
  chef|inter|sous-chef-merge|contre-chef-inter)
    EXTRA_FLAGS+=("--teammate-mode" "tmux")
    ;;
esac

PATH="${HOME}/.local/bin:${PATH}"
export PATH

exec claude \
  --dangerously-skip-permissions \
  --permission-mode bypassPermissions \
  ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} \
  --append-system-prompt "${PROMPT}" \
  "${INITIAL_MSG}"
