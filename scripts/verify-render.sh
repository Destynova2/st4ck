#!/usr/bin/env bash
# verify-render.sh — niveau 1 du plan docs/how-to/test-local.md.
#
# Rend (`helm template`) CHAQUE HelmRelease Flux a la version epinglee dans
# le registre clusters/management/versions-configmap.yaml, avec ses values
# reelles (le/les ConfigMap valuesFrom, passes par `flux envsubst`), puis
# valide tout le rendu avec kubeconform (schemas K8s + CRDs du datree
# catalog).
#
# Ce que ca attrape que le niveau 0 (verify-local) ne voit pas : un chart
# qui refuse nos values AU BUMP de version (ex. vm-k8s-stack 14 minors de
# bundle) et les apiVersion/champs invalides que `kustomize build` laisse
# passer.
#
# Reseau requis : `helm template --repo` pull chaque chart. Les secrets ESO
# (${cookie_secret}, ${system_secret}, ...) ne sont PAS dans le registre :
# `flux envsubst` les vide, les charts templatent sans broncher (verifie) et
# ESO fournit la vraie valeur au deploiement.
#
# Usage: bash scripts/verify-render.sh   (ou: make verify-render)
# Prerequis : helm, flux, kubeconform (auto-installe via brew si absent),
#             python3 + pyyaml.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

REGISTRY="clusters/management/versions-configmap.yaml"

PASS=0
FAIL=0
COUNT=0
FAILED_STEPS=""

step() { printf '\n━━ %s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); printf '   ✅ %s\n' "$*"; }
ko()   { FAIL=$((FAIL + 1)); FAILED_STEPS="${FAILED_STEPS}\n  - $*"; printf '   ❌ %s\n' "$*"; }

# ── 0. Prerequis ─────────────────────────────────────────────────────────
step "prerequis"
for bin in helm flux python3; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    printf '   ❌ %s introuvable\n' "${bin}"
    exit 1
  fi
done
if ! command -v kubeconform >/dev/null 2>&1; then
  printf '   … kubeconform absent — installation via brew\n'
  if ! brew install kubeconform >/dev/null 2>&1; then
    printf '   ❌ echec de "brew install kubeconform"\n'
    exit 1
  fi
fi
printf '   ✅ helm / flux / kubeconform / python3\n'

# ── 1. Variables de substitution (registre + valeurs runtime) ────────────
# Exportees dans l'environnement pour `flux envsubst`. On merge le registre
# (versions des charts) avec quelques valeurs runtime attendues dans les
# values. NB : on passe par `eval "$(...)"` (command substitution) et NON
# par `while read < <(python3 <<HEREDOC)` : sur le bash 3.2 de macOS, un
# heredoc DANS une process substitution est mal parse (« ambiguous
# redirect » + le corps du heredoc fuit et subit la brace expansion).
eval "$(python3 - "${REGISTRY}" <<'PYEOF'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1]))["data"]
data.update({"s3_url": "http://garage.garage.svc.cluster.local:3900",
             "velero_bucket": "velero-backups", "harbor_bucket": "unused",
             "cnpg_bucket": "cnpg-backups"})
for k, v in data.items():
    print(f"export {k}={v!r}")
PYEOF
)"

# ── 2. Plan de rendu : une ligne TSV par HelmRelease ─────────────────────
# Colonnes : name \t namespace \t chart \t version_brute \t repo_url \t values(csv)
# On resout le repo via le sourceRef (name → url de la HelmRepository) et le
# fichier de values via le configMapGenerator du kustomization.yaml du dossier.
PLAN=$(python3 - <<'PYEOF'
import glob, os, yaml

# name de HelmRepository -> url (scan large : stacks + clusters)
repo_url = {}
for f in glob.glob("stacks/**/*.yaml", recursive=True) + \
         glob.glob("clusters/**/*.yaml", recursive=True):
    try:
        docs = list(yaml.safe_load_all(open(f)))
    except Exception:
        continue
    for d in docs:
        if isinstance(d, dict) and d.get("kind") == "HelmRepository":
            repo_url[d["metadata"]["name"]] = d["spec"]["url"]

rows = []
flux_dirs = sorted({os.path.dirname(p) for p in glob.glob("stacks/*/flux*/*.yaml")})
for d in flux_dirs:
    # name de ConfigMap -> fichier de values (via configMapGenerator)
    cm_to_file = {}
    kf = os.path.join(d, "kustomization.yaml")
    if os.path.exists(kf):
        k = yaml.safe_load(open(kf)) or {}
        for g in (k.get("configMapGenerator") or []):
            for fe in (g.get("files") or []):
                path = fe.split("=", 1)[1] if "=" in fe else fe
                cm_to_file[g["name"]] = os.path.join(d, path)
    for f in sorted(glob.glob(os.path.join(d, "*.yaml"))):
        try:
            docs = list(yaml.safe_load_all(open(f)))
        except Exception:
            continue
        for doc in docs:
            if not isinstance(doc, dict) or doc.get("kind") != "HelmRelease":
                continue
            spec = doc["spec"]["chart"]["spec"]
            name = doc["metadata"]["name"]
            ns = doc["metadata"].get("namespace", "default")
            chart = spec["chart"]
            ver = spec["version"]
            src = spec["sourceRef"]["name"]
            url = repo_url.get(src, "!!MISSINGREPO:" + src)
            vfiles = []
            for vf in (doc["spec"].get("valuesFrom") or []):
                if vf.get("kind") == "ConfigMap":
                    vfiles.append(cm_to_file.get(vf["name"], "!!NOFILE:" + vf["name"]))
            rows.append((name, ns, chart, ver, url, ",".join(vfiles)))

for r in sorted(rows):
    print("\t".join(r))
PYEOF
)

TMPD=$(mktemp -d)
trap 'rm -rf "${TMPD}"' EXIT

# ── 3. Rendu + validation, une HelmRelease a la fois ─────────────────────
step "helm template + kubeconform"
while IFS=$'\t' read -r name ns chart ver_raw url vfiles; do
  [ -n "${name}" ] || continue
  COUNT=$((COUNT + 1))

  case "${url}" in
    "!!MISSINGREPO:"*)
      ko "${name} — HelmRepository '${url#!!MISSINGREPO:}' introuvable"
      continue ;;
  esac

  # Version : resoudre le placeholder ${x_version} via le registre exporte.
  ver=$(printf '%s' "${ver_raw}" | flux envsubst)
  # shellcheck disable=SC2016  # ${...} litteral voulu (detection de placeholder residuel)
  if [ -z "${ver}" ] || printf '%s' "${ver}" | grep -q '\${'; then
    ko "${name} — version '${ver_raw}' non resolue par le registre"
    continue
  fi

  # Values : chaque ConfigMap valuesFrom → fichier passe par flux envsubst.
  IFS=',' read -r -a vf_list <<< "${vfiles}" || true
  vals_args=()
  vals_err=""
  idx=0
  for vf in "${vf_list[@]}"; do
    case "${vf}" in
      "") continue ;;
      "!!NOFILE:"*) vals_err="ConfigMap '${vf#!!NOFILE:}' sans fichier de values"; break ;;
    esac
    if [ ! -f "${vf}" ]; then
      vals_err="fichier de values absent : ${vf}"
      break
    fi
    rendered_vals="${TMPD}/${name}-values-${idx}.yaml"
    if ! flux envsubst < "${vf}" > "${rendered_vals}"; then
      vals_err="flux envsubst a echoue sur ${vf}"
      break
    fi
    vals_args+=(-f "${rendered_vals}")
    idx=$((idx + 1))
  done
  if [ -n "${vals_err}" ]; then
    ko "${name} — ${vals_err}"
    continue
  fi
  if [ "${#vals_args[@]}" -eq 0 ]; then
    ko "${name} — aucune values ConfigMap resolue"
    continue
  fi

  # helm template a la version du registre.
  render="${TMPD}/${name}-render.yaml"
  herr="${TMPD}/${name}-helm.err"
  if ! helm template "${name}" "${chart}" --repo "${url}" --version "${ver}" \
         --namespace "${ns}" "${vals_args[@]}" > "${render}" 2> "${herr}"; then
    msg=$(grep -m1 -i 'error' "${herr}" | head -c 220 || true)
    [ -n "${msg}" ] || msg=$(tail -1 "${herr}" 2>/dev/null || true)
    ko "${name}@${ver} — helm template : ${msg}"
    continue
  fi

  # kubeconform sur tout le rendu (schemas K8s par defaut + CRDs datree).
  # NB kubeconform 0.8 : le champ template est .ResourceAPIVersion (l'ancien
  # .ResourceVersion n'existe plus dans la struct → erreur d'init sinon).
  kerr="${TMPD}/${name}-kubeconform.err"
  if kubeconform -strict -ignore-missing-schemas \
       -schema-location default \
       -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
       -summary "${render}" > "${kerr}" 2>&1; then
    docs=$(grep -c '^kind:' "${render}" || true)
    ok "${name}@${ver} (${docs} docs)"
  else
    msg=$(grep -m1 -iE 'invalid|error|failed' "${kerr}" | head -c 300 || true)
    [ -n "${msg}" ] || msg=$(tail -1 "${kerr}" 2>/dev/null || true)
    ko "${name}@${ver} — kubeconform : ${msg}"
  fi
done < <(printf '%s\n' "${PLAN}")

if [ "${COUNT}" -eq 0 ]; then
  ko "aucune HelmRelease decouverte (stacks/*/flux*) — plan vide"
fi

# ── Bilan ────────────────────────────────────────────────────────────────
printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
printf 'verify-render : %d ✅ / %d ❌ (%d HelmRelease)\n' "${PASS}" "${FAIL}" "${COUNT}"
if [ "${FAIL}" -gt 0 ]; then
  printf 'Echecs :%b\n' "${FAILED_STEPS}"
  exit 1
fi
