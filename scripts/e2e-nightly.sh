#!/usr/bin/env bash
# e2e-nightly.sh — wrapper launchd de la porte e2e-local (test-local.md).
# Pousse HEAD sur le Gitea du bootstrap puis lance make e2e-local.
# Skip proprement (exit 0 + log) si l'infra locale n'est pas la —
# machine podman arretee, platform pod down — pour ne pas spammer de
# faux rouges quand le poste est autrement occupe.
#
# Ports : herites de l'environnement (launchd les fixe dans le plist).
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}" || exit 1

VB_PORT="${VB_PORT:-8080}"
GITEA_PORT="${GITEA_PORT:-3000}"
LOG_DIR="${HOME}/Library/Logs/st4ck-e2e"
mkdir -p "${LOG_DIR}"
STAMP=$(date +%Y%m%d-%H%M%S)
LOG="${LOG_DIR}/e2e-${STAMP}.log"

note() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "${LOG}"; }

if ! curl -so /dev/null --max-time 5 "http://localhost:${VB_PORT}/state/test"; then
  note "SKIP: vault-backend absent sur :${VB_PORT} (machine podman ou platform pod down)"
  exit 0
fi

PASS=$(tofu -chdir=bootstrap output -raw admin_password 2>/dev/null || true)
if [ -n "${PASS}" ]; then
  AUTH=$(printf 'talos:%s' "${PASS}" | base64)
  if git -c credential.helper= -c http.extraHeader="Authorization: Basic ${AUTH}" \
      push "http://localhost:${GITEA_PORT}/talos/talos.git" HEAD:main >/dev/null 2>&1; then
    note "HEAD pousse sur le Gitea local"
  else
    note "WARN: push Gitea en echec (HEAD peut etre deja a jour)"
  fi
fi

note "lancement make e2e-local (VB_PORT=${VB_PORT} GITEA_PORT=${GITEA_PORT})"
if VB_PORT="${VB_PORT}" GITEA_PORT="${GITEA_PORT}" make e2e-local >> "${LOG}" 2>&1; then
  note "E2E NIGHTLY: PASS"
else
  note "E2E NIGHTLY: FAIL — voir ${LOG}"
  exit 1
fi
