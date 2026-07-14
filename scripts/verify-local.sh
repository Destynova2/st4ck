#!/usr/bin/env bash
# verify-local.sh — niveau 0 du plan docs/how-to/test-local.md :
# toutes les verifications statiques de la plateforme en une passe.
# Zero infrastructure requise (le premier run telecharge les providers
# tofu ; les suivants tournent en ~2-3 min).
#
# Usage: bash scripts/verify-local.sh   (ou: make verify-local)
#   SKIP_TFTEST=1   saute les suites .tftest.hcl (plus lentes)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

PASS=0
FAIL=0
FAILED_STEPS=""

step() { printf '\n━━ %s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); printf '   ✅ %s\n' "$*"; }
ko()   { FAIL=$((FAIL + 1)); FAILED_STEPS="${FAILED_STEPS}\n  - $*"; printf '   ❌ %s\n' "$*"; }

# ── 1. Formatage tofu ────────────────────────────────────────────────────
step "tofu fmt"
if tofu fmt -check -recursive stacks envs modules bootstrap >/dev/null 2>&1; then
  ok "tofu fmt -check"
else
  ko "tofu fmt -check (lancer: tofu fmt -recursive stacks envs modules bootstrap)"
fi

# ── 2. tofu validate (init -backend=false si besoin) ────────────────────
step "tofu validate"
TF_DIRS=$(find stacks envs modules bootstrap -maxdepth 2 -name main.tf -not -path "*/.terraform/*" -not -path "*/examples/*" -exec dirname {} \; | sort)
for d in ${TF_DIRS}; do
  [ -d "$d/.terraform" ] || tofu -chdir="$d" init -backend=false -input=false >/dev/null 2>&1 || true
  if tofu -chdir="$d" validate >/dev/null 2>&1; then
    ok "validate $d"
  else
    ko "validate $d"
  fi
done

# ── 3. Suites .tftest.hcl ────────────────────────────────────────────────
if [ "${SKIP_TFTEST:-0}" != "1" ]; then
  step "tofu test"
  for d in envs/scaleway/iam envs/scaleway/image envs/scaleway/ci envs/scaleway modules/em-talos-bootstrap; do
    if compgen -G "$d/tests/*.tftest.hcl" >/dev/null || compgen -G "$d/*.tftest.hcl" >/dev/null; then
      if tofu -chdir="$d" test >/dev/null 2>&1; then
        ok "tftest $d"
      else
        ko "tftest $d"
      fi
    fi
  done
fi

# ── 4. Kustomize build ───────────────────────────────────────────────────
step "kustomize build"
KUSTOM_DIRS="clusters/management $(find stacks -maxdepth 2 -type d -name 'flux*' | sort)"
for d in ${KUSTOM_DIRS}; do
  [ -f "$d/kustomization.yaml" ] || continue
  if kubectl kustomize "$d" >/dev/null 2>&1; then
    ok "kustomize $d"
  else
    ko "kustomize $d"
  fi
done

# ── 5. Substitution : zero placeholder residuel ──────────────────────────
step "substitution Flux (registre + vars root)"
# Export des variables de substitution dans l'environnement du script
# (bash 3.2 de macOS + set -u rendent l'expansion de tableau fragile, et
# un `env` qui echoue produirait des faux positifs silencieux).
while IFS= read -r pair; do export "${pair?}"; done < <(python3 - <<'PYEOF'
import yaml
data = yaml.safe_load(open("clusters/management/versions-configmap.yaml"))["data"]
data.update({"s3_url": "http://garage.garage.svc.cluster.local:3900",
              "velero_bucket": "velero-backups", "harbor_bucket": "unused",
              "cnpg_bucket": "cnpg-backups"})
for k, v in data.items():
    print(f"{k}={v}")
PYEOF
)
for d in ${KUSTOM_DIRS}; do
  [ -f "$d/kustomization.yaml" ] || continue
  if ! kubectl kustomize "$d" >/dev/null 2>&1; then
    ko "substitution $d (kustomize build en echec)"
    continue
  fi
  RENDERED=$(kubectl kustomize "$d" 2>/dev/null | flux envsubst 2>/dev/null)
  if [ -z "${RENDERED}" ]; then
    # arbre legitimement vide (ex. stacks/capi/flux placeholder resources: [])
    ok "substitution $d (arbre vide)"
    continue
  fi
  # shellcheck disable=SC2016  # ${...} litteral voulu (placeholder Flux)
  LEFT=$(printf '%s' "${RENDERED}" | grep -c '\${[a-z_]*}' || true)
  if [ "${LEFT}" = "0" ]; then
    ok "substitution $d"
  else
    ko "substitution $d (${LEFT} placeholder(s) non resolus)"
  fi
done

# ── 6. Provider karpenter (si present sur la branche) ────────────────────
if [ -d karpenter-provider-scaleway ]; then
  step "provider karpenter"
  if (cd karpenter-provider-scaleway && go build ./... >/dev/null 2>&1 && go test -race ./... >/dev/null 2>&1); then
    ok "go build + test -race"
  else
    ko "provider karpenter (go build/test)"
  fi
fi

# ── 7. Shellcheck ────────────────────────────────────────────────────────
step "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  for f in scripts/*.sh envs/scaleway/ci/launch.sh; do
    if shellcheck -x "$f" >/dev/null 2>&1; then
      ok "shellcheck $f"
    else
      ko "shellcheck $f"
    fi
  done
else
  ko "shellcheck absent (brew install shellcheck)"
fi

# ── 8. Determinisme du manifest hauler ───────────────────────────────────
step "hauler manifest (determinisme)"
TMP_MANIFEST=$(mktemp)
trap 'rm -f "${TMP_MANIFEST}"' EXIT
if python3 scripts/hauler-manifest-gen.py -o "${TMP_MANIFEST}" >/dev/null 2>&1 \
   && diff -q "${TMP_MANIFEST}" hauler-manifest.yaml >/dev/null 2>&1; then
  ok "hauler-manifest.yaml a jour et deterministe"
else
  ko "hauler-manifest.yaml diverge (lancer: make hauler-manifest)"
fi

# ── Bilan ────────────────────────────────────────────────────────────────
printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
printf 'verify-local : %d ✅ / %d ❌\n' "${PASS}" "${FAIL}"
if [ "${FAIL}" -gt 0 ]; then
  printf 'Echecs :%b\n' "${FAILED_STEPS}"
  exit 1
fi
