#!/usr/bin/env bash
# mirror-images-to-scr.sh — copy upstream container images into the
# Scaleway Container Registry mirror provisioned by stacks/registry-mirror/.
#
# Reads scripts/mirror-images.txt (one upstream image per line, # comments
# allowed). For each entry, copies it into the SCR namespace under a
# deterministic, sanitized path so Talos can resolve it transparently via
# patches/registry-mirror-scr.yaml.
#
# Tools (in order of preference):
#   1. skopeo  — fastest, no daemon, copies by digest
#   2. docker  — fallback (pull/tag/push)
#   3. podman  — fallback (same surface as docker)
#
# Usage:
#   bash scripts/mirror-images-to-scr.sh [OPTIONS]
#
# Options:
#   --dry-run                Print what would be mirrored, don't push
#   --scr-namespace=NAME     SCR namespace (default: st4ck-mirror)
#   --region=REGION          SCR region    (default: fr-par)
#   --filter=PATTERN         grep -E pattern; mirror only matching lines
#   --list=PATH              Override input list (default scripts/mirror-images.txt)
#   --tool=auto|skopeo|docker|podman   Force a specific tool
#   -h | --help              Show this help

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────
DRY_RUN=false
SCR_NAMESPACE="st4ck-mirror"
REGION="fr-par"
FILTER=""
TOOL="auto"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIST_FILE="${SCRIPT_DIR}/mirror-images.txt"

# ─── Logging ─────────────────────────────────────────────────────────────
log()  { printf '[mirror] %s\n' "$*" >&2; }
warn() { printf '[mirror][WARN] %s\n' "$*" >&2; }
err()  { printf '[mirror][ERR ] %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  sed -n '2,/^set -euo pipefail/p' "$0" | sed 's/^# \{0,1\}//' | head -n 30
}

# ─── Argument parsing ────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --dry-run)             DRY_RUN=true ;;
    --scr-namespace=*)     SCR_NAMESPACE="${arg#*=}" ;;
    --region=*)            REGION="${arg#*=}" ;;
    --filter=*)            FILTER="${arg#*=}" ;;
    --list=*)              LIST_FILE="${arg#*=}" ;;
    --tool=*)              TOOL="${arg#*=}" ;;
    -h|--help)             usage; exit 0 ;;
    *)                     die "Unknown argument: $arg (use --help)" ;;
  esac
done

# ─── Tool detection ──────────────────────────────────────────────────────
detect_tool() {
  if [[ "$TOOL" != "auto" ]]; then
    command -v "$TOOL" >/dev/null 2>&1 || die "Requested --tool=$TOOL is not installed."
    echo "$TOOL"
    return
  fi
  for candidate in skopeo docker podman; do
    if command -v "$candidate" >/dev/null 2>&1; then
      echo "$candidate"
      return
    fi
  done
  die "No image tool found. Install one of: skopeo (preferred), docker, podman."
}

TOOL="$(detect_tool)"
log "Using tool: $TOOL"
log "Target SCR: rg.${REGION}.scw.cloud/${SCR_NAMESPACE}"
log "List file:  ${LIST_FILE}"
[[ "$DRY_RUN" == "true" ]] && log "DRY-RUN — nothing will actually push."

[[ -f "$LIST_FILE" ]] || die "List file not found: $LIST_FILE"

SCR_HOST="rg.${REGION}.scw.cloud"
SCR_BASE="${SCR_HOST}/${SCR_NAMESPACE}"

# ─── Auth check (warn if creds missing, but don't block dry-run) ─────────
auth_check() {
  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi
  case "$TOOL" in
    skopeo)
      if ! skopeo inspect --no-tags "docker://${SCR_BASE}/__nonexistent__" >/dev/null 2>&1; then
        : # 404 expected — we just want to be sure host responds
      fi
      ;;
    docker|podman)
      if ! "$TOOL" info >/dev/null 2>&1; then
        die "$TOOL daemon unreachable. Start it (e.g. 'colima start' or 'podman machine start')."
      fi
      ;;
  esac
}
auth_check

# ─── Image-name sanitizer ────────────────────────────────────────────────
# SCR enforces lowercase + restricted charset on the path component.
# We flatten the upstream registry into the target name so reverse-resolution
# is unambiguous:
#   quay.io/openbao/openbao:2.5.1
#     → rg.fr-par.scw.cloud/st4ck-mirror/quay.io-openbao-openbao:2.5.1
sanitize() {
  local upstream="$1"
  local name_part="${upstream%@*}"   # drop @sha256:... if any
  local repo="${name_part%:*}"       # drop :tag
  echo "${repo}" | tr '/' '-'
}

# ─── Single-image copy logic ─────────────────────────────────────────────
copy_one() {
  local upstream="$1"
  local tag_or_digest=""

  if [[ "$upstream" == *@* ]]; then
    tag_or_digest="@${upstream#*@}"
  elif [[ "$upstream" == *:* ]]; then
    tag_or_digest=":${upstream##*:}"
  else
    tag_or_digest=":latest"
    upstream="${upstream}:latest"
  fi

  local sanitized
  sanitized="$(sanitize "$upstream")"
  local target="${SCR_BASE}/${sanitized}${tag_or_digest}"

  printf '  upstream → %s\n' "$upstream"
  printf '  target   → %s\n' "$target"

  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi

  case "$TOOL" in
    skopeo)
      # --multi-arch all preserves manifest lists (Cilium, busybox, …)
      # Idempotent: skopeo refuses to overwrite same digest, just exits 0.
      skopeo copy --multi-arch all \
        "docker://${upstream}" \
        "docker://${target}"
      ;;
    docker|podman)
      "$TOOL" pull "$upstream"
      "$TOOL" tag  "$upstream" "$target"
      "$TOOL" push "$target"
      ;;
  esac
}

# ─── Main loop ───────────────────────────────────────────────────────────
total=0
ok=0
failed=()

while IFS= read -r raw_line; do
  line="${raw_line%%#*}"               # strip in-line comments
  line="${line#"${line%%[![:space:]]*}"}"  # ltrim
  line="${line%"${line##*[![:space:]]}"}"  # rtrim
  [[ -z "$line" ]] && continue

  if [[ -n "$FILTER" ]] && ! echo "$line" | grep -qE "$FILTER"; then
    continue
  fi

  total=$((total + 1))
  log "[$total] copying $line"
  if copy_one "$line"; then
    ok=$((ok + 1))
  else
    warn "FAILED: $line"
    failed+=("$line")
  fi
done < "$LIST_FILE"

# ─── Report ──────────────────────────────────────────────────────────────
log "──────────────────────────────────────────────────────"
log "Total processed: $total"
log "Succeeded:       $ok"
log "Failed:          $((total - ok))"
if (( ${#failed[@]} > 0 )); then
  log "Failed images:"
  for f in "${failed[@]}"; do
    printf '  - %s\n' "$f" >&2
  done
  exit 2
fi
exit 0
