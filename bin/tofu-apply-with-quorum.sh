#!/usr/bin/env bash
# shellcheck shell=bash
#
# tofu-apply-with-quorum.sh — gated `tofu apply` for the apply pane.
#
# Refuses to run unless ALL of the following hold:
#   1. PWD == /Users/ludwig/workspace/st4ck-wt-apply (apply pane only).
#   2. --plan points to an existing OpenTofu plan file.
#   3. --quorum-meta points to a JSON file containing >= 3 APPROVE entries.
#   3b. The SHA-256 of the --plan file matches the .plan_sha256 field in
#       --quorum-meta (defends against plan-swap between vote and apply).
#   4. --reason is a non-empty human string (recorded in stdout for audit).
#   5. `scw -p st4ck-admin info` succeeds (admin profile reachable).
#
# On entry, exports SCW_PROFILE=st4ck-admin for the wrapped `tofu apply` call.
# An EXIT trap unconditionally unsets SCW_PROFILE / SCW_ACCESS_KEY /
# SCW_SECRET_KEY so the admin scope cannot leak to the parent shell.
#
# Captures the apply's stderr to a temp file and prints its last 40 lines
# along with APPLIED/FAILED on completion.
#
# Usage:
#   bin/tofu-apply-with-quorum.sh \
#       --plan ./plan.bin \
#       --quorum-meta ./.claude/plans/<plat>.quorum.json \
#       --reason "P15 EM smoke apply"

set -euo pipefail

# ─── Constants ─────────────────────────────────────────────────────────
readonly REQUIRED_PWD="/Users/ludwig/workspace/st4ck-wt-apply"
readonly REQUIRED_PROFILE="st4ck-admin"
readonly MIN_APPROVALS=3
readonly STDERR_TAIL_LINES=40

# ─── Trap: scrub admin scope from the environment on any exit ──────────
# shellcheck disable=SC2329  # invoked via `trap cleanup EXIT` below
cleanup() {
    local rc=$?
    unset SCW_PROFILE SCW_ACCESS_KEY SCW_SECRET_KEY
    if [[ -n "${stderr_log:-}" && -f "${stderr_log}" ]]; then
        rm -f "${stderr_log}"
    fi
    return "${rc}"
}
trap cleanup EXIT

# ─── Logging helpers ───────────────────────────────────────────────────
log()  { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
err()  { printf '[%s] ERROR: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ─── Usage ─────────────────────────────────────────────────────────────
usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") --plan <file> --quorum-meta <file> --reason <text>

Required flags:
  --plan <file>          Path to an OpenTofu plan file produced by 'tofu plan -out'.
  --quorum-meta <file>   Path to a JSON file with >= ${MIN_APPROVALS} APPROVE entries.
  --reason <text>        Short human reason recorded in stdout for audit trail.

Refuses to run unless PWD == ${REQUIRED_PWD}.
EOF
    exit 2
}

# ─── Parse flags (long-only; getopts long support is not portable) ─────
plan=""
quorum_meta=""
reason=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --plan)
            [[ $# -ge 2 ]] || die "--plan requires a value"
            plan="$2"
            shift 2
            ;;
        --quorum-meta)
            [[ $# -ge 2 ]] || die "--quorum-meta requires a value"
            quorum_meta="$2"
            shift 2
            ;;
        --reason)
            [[ $# -ge 2 ]] || die "--reason requires a value"
            reason="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            err "unknown flag: $1"
            usage
            ;;
    esac
done

[[ -n "${plan}" ]]        || { err "--plan is required"; usage; }
[[ -n "${quorum_meta}" ]] || { err "--quorum-meta is required"; usage; }
[[ -n "${reason}" ]]      || { err "--reason is required"; usage; }

# ─── Guard 1: PWD must be the apply worktree ───────────────────────────
if [[ "${PWD}" != "${REQUIRED_PWD}" ]]; then
    die "refusing to run outside the apply worktree (PWD=${PWD}, expected=${REQUIRED_PWD})"
fi

# ─── Guard 2: plan file must exist ─────────────────────────────────────
[[ -f "${plan}" ]]        || die "plan file not found: ${plan}"

# ─── Guard 3: quorum-meta must exist + carry >= 3 APPROVE entries ──────
[[ -f "${quorum_meta}" ]] || die "quorum-meta file not found: ${quorum_meta}"
command -v jq >/dev/null 2>&1 || die "jq is required to parse quorum-meta"

approvals=$(jq '[.. | objects | select(.vote? == "APPROVE")] | length' "${quorum_meta}" 2>/dev/null) \
    || die "failed to parse quorum-meta as JSON: ${quorum_meta}"

if [[ "${approvals}" -lt "${MIN_APPROVALS}" ]]; then
    die "quorum-meta has ${approvals} APPROVE entries, need >= ${MIN_APPROVALS}: ${quorum_meta}"
fi

# ─── Guard 3b: plan-hash check (defends against plan-swap between vote and apply) ─
# Quorum-meta MUST carry a top-level "plan_sha256" field with the SHA-256 of the
# exact plan file the voters approved. We recompute the hash here and abort on
# mismatch so a swapped plan cannot ride a stale quorum signature.
expected_sha=$(jq -r '.plan_sha256 // empty' "${quorum_meta}" 2>/dev/null)
[[ -n "${expected_sha}" ]] \
    || die "quorum-meta is missing required field .plan_sha256: ${quorum_meta}"
[[ "${expected_sha}" =~ ^[a-fA-F0-9]{64}$ ]] \
    || die ".plan_sha256 must be a 64-hex-char SHA-256, got: ${expected_sha}"

# Pick a portable SHA-256 binary (Linux: sha256sum; macOS: shasum -a 256).
if command -v sha256sum >/dev/null 2>&1; then
    actual_sha=$(sha256sum "${plan}" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
    actual_sha=$(shasum -a 256 "${plan}" | awk '{print $1}')
else
    die "no SHA-256 binary available (need sha256sum or shasum)"
fi

# Compare case-insensitively via `tr` (portable; ${var,,} would need bash 4+).
expected_lc=$(printf '%s' "${expected_sha}" | tr '[:upper:]' '[:lower:]')
actual_lc=$(printf '%s' "${actual_sha}"   | tr '[:upper:]' '[:lower:]')
if [[ "${actual_lc}" != "${expected_lc}" ]]; then
    err "plan-hash mismatch — refusing to apply a plan the quorum did not approve"
    err "  expected (from quorum-meta): ${expected_sha}"
    err "  actual   (from --plan file): ${actual_sha}"
    exit 1
fi

# ─── Guard 4: admin profile must be reachable ──────────────────────────
command -v scw   >/dev/null 2>&1 || die "scw CLI is required"
command -v tofu  >/dev/null 2>&1 || die "tofu CLI is required"

if ! scw -p "${REQUIRED_PROFILE}" info >/dev/null 2>&1; then
    die "scw profile '${REQUIRED_PROFILE}' is not reachable (check ~/.config/scw/config.yaml)"
fi

# ─── Audit banner ──────────────────────────────────────────────────────
log "tofu-apply-with-quorum: starting"
log "  plan          : ${plan}"
log "  plan sha256   : ${actual_sha}"
log "  quorum-meta   : ${quorum_meta} (${approvals} APPROVE entries)"
log "  reason        : ${reason}"
log "  pwd           : ${PWD}"
log "  scw profile   : ${REQUIRED_PROFILE}"

# ─── Switch to admin profile JUST for the apply call ───────────────────
export SCW_PROFILE="${REQUIRED_PROFILE}"

stderr_log="$(mktemp -t tofu-apply-stderr.XXXXXX)"

set +e
tofu apply -auto-approve "${plan}" 2> >(tee "${stderr_log}" >&2)
apply_rc=$?
set -e

# ─── Report outcome ────────────────────────────────────────────────────
if [[ "${apply_rc}" -eq 0 ]]; then
    log "APPLIED: tofu apply succeeded (rc=${apply_rc})"
else
    err "FAILED: tofu apply failed (rc=${apply_rc})"
fi

echo
echo "─── last ${STDERR_TAIL_LINES} lines of stderr ───"
tail -n "${STDERR_TAIL_LINES}" "${stderr_log}" || true
echo "─── end stderr ───"

exit "${apply_rc}"
