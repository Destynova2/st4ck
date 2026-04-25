#!/usr/bin/env bash
# brigade-setup-worktrees.sh — idempotent worktree + permission setup

set -eu  # NOT pipefail — git | grep -q triggers SIGPIPE on git side

ROOT="${1:-/Users/ludwig/workspace/st4ck}"
SESSION="${2:?Usage: $0 <project_root> <session_name>}"

cd "${ROOT}"

declare -a SOLO_ROLES=(gate maitre apply vote-scope vote-secu vote-qualite)
declare -a COMMIS_ROLES=(bootstrap scaleway k8s-day1 docs em)

ensure_worktree() {
  local wt_path="$1"
  local branch="$2"

  if [[ -d "${wt_path}" ]] && ! git worktree list --porcelain | grep -q "^worktree ${wt_path}$"; then
    echo "  cleaning orphan dir: ${wt_path}" >&2
    rm -rf "${wt_path}"
  fi

  if git worktree list --porcelain | grep -q "^worktree ${wt_path}$"; then
    return 0
  fi

  if git show-ref --verify --quiet "refs/heads/${branch}"; then
    git worktree add "${wt_path}" "${branch}" >/dev/null 2>&1 \
      && echo "  ✓ ${wt_path} → ${branch}" \
      || echo "  ✗ FAILED ${wt_path} → ${branch}" >&2
  else
    git worktree add "${wt_path}" -b "${branch}" >/dev/null 2>&1 \
      && echo "  ✓ ${wt_path} → ${branch} (new)" \
      || echo "  ✗ FAILED ${wt_path} -b ${branch}" >&2
  fi
}

copy_perms() {
  local wt_path="$1"
  local role_dir="$2"
  local src="${ROOT}/.claude/permissions-brigade/${role_dir}/settings.local.json"
  local dst="${wt_path}/.claude/settings.local.json"

  [[ -f "${src}" ]] || { echo "  SKIP perms (src missing): ${src}" >&2; return; }
  [[ -d "${wt_path}" ]] || { echo "  SKIP perms (wt missing): ${wt_path}" >&2; return; }

  mkdir -p "${wt_path}/.claude"
  cp -n "${src}" "${dst}" 2>/dev/null || true
}

echo "=== Brigade worktrees setup (${SESSION}) ==="

for role in "${SOLO_ROLES[@]}"; do
  ensure_worktree "${ROOT}-wt-${role}" "wt/${role}"
  copy_perms "${ROOT}-wt-${role}" "${role}"
done

for role in "${COMMIS_ROLES[@]}"; do
  ensure_worktree "${ROOT}-wt-commis-${role}" "chore/phase-a-${SESSION}-${role}"
  copy_perms "${ROOT}-wt-commis-${role}" "commis-${role}"
done

if ! git show-ref --verify --quiet "refs/heads/chore/phase-a-${SESSION}"; then
  git branch "chore/phase-a-${SESSION}" 2>&1 | head -1
fi

mkdir -p "${ROOT}/.claude/plans"

echo "=== Setup complete ==="
git worktree list
