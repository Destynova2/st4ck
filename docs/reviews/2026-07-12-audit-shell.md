# st4ck — audit shell (SQI)

**Date :** 2026-07-12
**Audit :** `/cli-audit-shell` — Shell Quality Index sur 12 dimensions (Google Shell
Style Guide + sémantique bash au-delà de shellcheck)
**Périmètre :** `scripts/*.sh` (5 scripts bash), `envs/scaleway/ci/launch.sh`,
recettes shell inline du Makefile (`garage-chart`, `k8s-up`, `hauler-*` —
`k8s-down` et `arbor` notés en adjacence), provisioners `local-exec` de
`modules/em-talos-bootstrap/main.tf` (5 blocs + 2 heredocs distants).
`scripts/hauler-manifest-gen.py` : hors périmètre (Python).
**Shellcheck :** 0.11.0 — `shellcheck -x -S style` sur les 6 scripts : **0 warning,
0 erreur**. Corpus shellcheck-clean ; tout ce qui suit est sémantique
(invisible pour un linter).

**SQI : 7.4/10 — Bon** (production-worthy). Cible pour du bootstrap infra : 7.0+
→ **cible atteinte**. Aucune violation critique (Tier 3). Le corpus porte les
traces des postmortems (seal key, wait loops, Bug #35) : les patterns dangereux
classiques ont déjà été payés puis corrigés.

---

## Scores par catégorie

Types détectés : installer/bootstrap (`launch.sh`, provisioners EM — S9/S10/S12
pondérés ×1.25), build/CI (recettes Makefile — S2 ×1.25), wrappers
(`cosign-sign.sh`, `brigade-launch-agent.sh`), outillage opérateur
(`mirror-images-to-scr.sh`, `register-hydra-oidc-client.sh`). Poids re-normalisés.

| # | Catégorie | Poids | Score | Constats clés |
|---|-----------|-------|-------|---------------|
| S1 | Strict mode coherence | 11,0 % | 0,85 | `set -euo pipefail` partout ; déviation documentée (`set -eu` + justification SIGPIPE, worktrees:4) ; 1 piège pipefail réel (EM main.tf:138) |
| S2 | Error surfaces | 13,7 % | 0,70 | Erreurs git avalées (worktrees:28-34), `curl` sans `-f` (garage-chart), no-op auth_check (mirror:94-99), gardes hauler incohérentes |
| S3 | Logging & observabilité | 7,3 % | 0,60 | Helpers `log/warn/err` préfixés sur stderr (mirror) ; pas de timestamps, pas de `--verbose/--quiet` ; `logger(1)` non pertinent ici (pas de service systemd) |
| S4 | Stderr hygiene | 4,6 % | 0,70 | Majoritairement `>&2` ; exceptions : cosign-sign.sh:24-25, launch.sh:39-43 (WARN sur stdout) |
| S5 | Variable discipline | 9,2 % | 0,80 | `local` systématique, déclaration/affectation séparées (mirror:136-137) ; heredocs distants single-quotés (EM) ; interpolation YAML dans register-hydra (mitigée) |
| S6 | Quoting & expansion | 7,3 % | 0,85 | Expansions quotées, idiome tableau-vide-sous-`set -u` (brigade-launch:45) ; style accolades incohérent (`$TOOL` vs `${TOOL}`) |
| S7 | Control flow & structure | 7,3 % | 0,60 | Aucun `main()` ; code exécutable entrelacé entre fonctions (mirror:78,107) ; nesting faible partout |
| S8 | Naming conventions | 4,6 % | 0,75 | snake_case/UPPER_CASE cohérents ; aucune constante `readonly` (SCRIPT_DIR, SCR_BASE, WORKDIR) |
| S9 | CLI ergonomics | 11,4 % | 0,75 | mirror exemplaire (`--help --dry-run --tool --filter`) ; `${1:?Usage}` ailleurs ; pas de `--version` ; Loi 3 couverte (dry-run / `tofu plan`) |
| S10 | Idempotency & safety | 11,4 % | 0,80 | Seal key never-overwrite + garde 32 octets, signature disque avant wipe, 201/409, `mktemp`+trap ; garage-chart re-télécharge à chaque init |
| S11 | Namespace & env hygiene | 6,4 % | 0,70 | Préfixes OIDC_/HYDRA_/COSIGN_ propres ; chemin `/Users/ludwig/...` codé en dur ×2 (brigade) |
| S12 | Security & injection | 5,7 % | 0,75 | Zéro `eval`, secret monté en fichier (jamais interpolé) ; `pod-with-secrets.yaml` en clair sans 0600 ; interpolation TF→shell single-quotée ×2 |
| | **SQI** | **100 %** | | **7,4/10** |

---

## Anti-patterns détectés

| # | Pattern | Sévérité | Fichier:ligne | Recommandation |
|---|---------|----------|---------------|----------------|
| AP3 | Silent Swallower | Majeur | scripts/brigade-setup-worktrees.sh:28-34 | Capturer stderr de `git worktree add`, l'afficher sur échec |
| — | Piège pipefail/SIGPIPE | Majeur | modules/em-talos-bootstrap/main.tf:138 | Retirer `head -n 500` (entrée déjà bornée à 4 MiB) |
| AP10 | Lazy Default | Majeur | scripts/brigade-launch-agent.sh:15, brigade-setup-worktrees.sh:6 | Dériver la racine de `git rev-parse --show-toplevel` |
| AP9 | Heredoc Injector (adjacent) | Mineur (mitigé) | envs/scaleway/ci/main.tf:417, modules/em-talos-bootstrap/main.tf:181 | Bloc `validation {}` TF interdisant `'` dans les vars interpolées |
| — | No-op guard | Mineur | scripts/mirror-images-to-scr.sh:94-99 | La branche skopeo d'`auth_check` ne vérifie rien — supprimer ou tester le code retour |
| AP7 | Sed Surgeon | Mineur (toléré) | Makefile:238 ; Makefile:1144-1177 (arbor, legacy) | 1 clé plate ancrée = sed OK ; arbor → supprimer (remplacé par hauler, ADR-034) |
| AP13 | Platform Assumption | Info | envs/scaleway/ci/launch.sh:53 (`stat -c %s`) | OK — cible Ubuntu VM explicite ; noté pour conscience |

Aucune occurrence : AP1 (dead fallback), AP2 (garde redondante), AP5, AP6, AP8,
AP11, AP12, `eval`. C'est rare sur un corpus de cette taille.

---

## Violations critiques (à corriger immédiatement)

**Aucune.** Pas de Tier 3 : pas de secret interpolé dans du shell, pas de
fallback mort sous `set -e`, pas d'opération destructive sans garde-fou.

---

## Flags (Tier 2 — à corriger, tri par effort croissant)

### S1/S10 : SIGPIPE sous `pipefail` dans le garde-fou anti-wipe — CONFIRMED
- **Fichier** : `modules/em-talos-bootstrap/main.tf:138`
- **Quoi** : `FIRSTMB=$(dd if="$DISK" bs=1M count=4 … | strings | head -n 500)`
  sous `set -euxo pipefail`. Quand `strings` produit plus de 500 lignes (probable
  sur 4 MiB de disque Ubuntu), `head` ferme le pipe → SIGPIPE (code 141) sur
  `strings`/`dd` → `pipefail` fait échouer l'affectation → `set -e` avorte le
  provisioner avec une erreur cryptique.
- **Pourquoi** : BashPitfalls — `head` dans un pipeline sous `pipefail` est
  non-déterministe. La direction est fail-safe (abort au lieu de wipe), mais le
  bootstrap EM devient intermittent au pire endroit (étape rescue payée ~10 min).
- **Fix** : l'entrée est déjà bornée à 4 MiB, retirer `head -n 500` ; sinon
  `| awk 'NR<=500'` (consomme tout, pas de SIGPIPE).

### S2 : erreurs `git worktree add` avalées — CONFIRMED
- **Fichier** : `scripts/brigade-setup-worktrees.sh:28-34`
- **Quoi** : `git worktree add … >/dev/null 2>&1 && echo "✓" || echo "✗ FAILED"`.
  En cas d'échec (branche déjà checkoutée ailleurs, dir non vide), l'opérateur
  voit `✗ FAILED` sans la cause.
- **Pourquoi** : AP3 Silent Swallower — le debugging devient de la devinette.
  Google SSG « Checking Return Values » : capturer et exposer l'erreur.
- **Fix** : pattern déjà présent dans `launch.sh:101-111` —
  `out="$(git worktree add … 2>&1)" || { echo "✗ FAILED: ${out}" >&2; }`.

### S2/S10 : `garage-chart` — curl sans `-f`, ni intégrité, ni cache — CONFIRMED
- **Fichier** : `Makefile:240-245`
- **Quoi** : `curl -sL … | tar -xz --strip-components=4 …`. Un 404 upstream
  (tag renommé, git.deuxfleurs.fr down) sert une page HTML à `tar` →
  « not in gzip format », erreur trompeuse. Aucun contrôle SHA du chart tiers.
  Cible dépendance de `k8s-storage-init` → re-téléchargement réseau à **chaque**
  init, y compris hors ligne.
- **Pourquoi** : erreur masquée (S2) + dépendance réseau dans le chemin d'init
  (S10) + supply chain non vérifiée sur un chart appliqué en cluster.
- **Fix** : `curl -fsSL` ; garde
  `test -f $(GARAGE_CHART)/Chart.yaml && exit 0` (ou cible make conditionnée par
  fichier) ; à terme sourcer le chart depuis le store hauler qui porte déjà le
  pin et les digests (ADR-034).

### S1/S2 : recettes Makefile sans `pipefail` ni `.DELETE_ON_ERROR` — CONFIRMED
- **Fichier** : `Makefile:1` (global — aucune directive `SHELL`/`.SHELLFLAGS`)
- **Quoi** : les recettes tournent sous `/bin/sh -c` : dans `curl | tar`
  (garage-chart:243), `curl | grep` (k8s-up:426), et les pipelines arbor, seul
  le code du dernier segment compte. Un fichier cible partiellement écrit sur
  échec n'est pas supprimé.
- **Pourquoi** : force concrète (le masquage de garage-chart ci-dessus est déjà
  observable) — pas un caprice de style.
- **Fix** : `SHELL := bash`, `.SHELLFLAGS := -eu -o pipefail -c`,
  `.DELETE_ON_ERROR:` en tête de Makefile ; re-tester les recettes qui tolèrent
  volontairement l'échec (`k8s-down` est déjà blindée de `|| true` documentés).

### S12 : `pod-with-secrets.yaml` en clair, ni 0600 ni nettoyé — CONFIRMED
- **Fichier** : `envs/scaleway/ci/launch.sh:69-77`
- **Quoi** : la concaténation `platform-pod.yaml` + `secrets.yaml` est écrite
  dans `/opt/woodpecker/pod-with-secrets.yaml` avec l'umask par défaut (0644
  root) et persiste après `podman play kube`.
- **Pourquoi** : secrets world-readable sur disque (S12 « world-readable
  secrets ») sur une VM qui héberge aussi CI et Gitea.
- **Fix** : `umask 077` avant l'écriture (ou `install -m 0600 /dev/null …`)
  puis `rm -f` après le `podman play kube` (trap EXIT).

### S10 : fallback docker/podman casse sur une entrée `@sha256:` — PLAUSIBLE
- **Fichier** : `scripts/mirror-images-to-scr.sh:127-159`
- **Quoi** : `copy_one` construit `target=…@sha256:…` pour une entrée digest ;
  or `docker tag`/`docker push` refusent une référence digest en cible. Latent :
  `mirror-images.txt` ne contient aucune entrée digest aujourd'hui (vérifié).
- **Pourquoi** : le jour où une image pinnée par digest entre dans la liste
  (pratique encouragée par ADR-034), le fallback échoue avec une erreur docker
  déroutante.
- **Fix** : si `TOOL != skopeo` et entrée `@digest` → `die` explicite («
  digest pinning requiert skopeo »), ou re-tagger `sha256-<7c>` comme tag.

### S12 : interpolation TF dans du shell single-quoté — PLAUSIBLE
- **Fichiers** : `envs/scaleway/ci/main.tf:417`
  (`GITEA_ADMIN='${var.gitea_admin_user}' GITEA_PASSWORD='${…}' bash launch.sh`),
  `modules/em-talos-bootstrap/main.tf:181` (`"IMAGE_URL='$IMAGE_URL' bash -s"`)
- **Quoi** : un `'` dans la valeur casse la ligne / injecte du shell. Mitigé
  aujourd'hui : `random_password.gitea_admin` a `special = false` (vérifié,
  ci/main.tf:66-73) et les deux autres vars sont opérateur ; mais rien ne
  l'impose côté schéma.
- **Fix** : bloc `validation {}` TF (`can(regex("^[^']*$", var.…))`) sur
  `gitea_admin_user` et `talos_image_url`, ou passer par le bloc `environment`
  du provisioner (comme le font déjà les stages 1-2-4-5 du module EM).

### S11 : racine projet codée en dur `/Users/ludwig/workspace/st4ck` — CONFIRMED
- **Fichiers** : `scripts/brigade-launch-agent.sh:15`,
  `scripts/brigade-setup-worktrees.sh:6`
- **Quoi** : défaut machine-spécifique (AP10 Lazy Default). Tout autre poste ou
  CI utilise silencieusement le mauvais chemin (worktrees créés à côté, prompts
  introuvables).
- **Fix** : `PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"`
  ou dérivation depuis `BASH_SOURCE[0]`.

---

## Mineurs (Tier 1 — au prochain passage sur le fichier)

1. **S4** — `scripts/cosign-sign.sh:24-25` : messages `ERROR:` sur stdout →
   ajouter `>&2`.
2. **S2** — `Makefile:1213-1220` : `hauler-verify/save/serve` n'ont pas la garde
   `command -v hauler` (présente sur `hauler-sync:1210`) → 127 brut ;
   `hauler-manifest` sans garde `python3`. Uniformiser.
3. **S2** — `scripts/mirror-images-to-scr.sh:94-99` : no-op `auth_check` (voir
   AP table) — le commentaire promet une vérification que le code ne fait pas.
4. **S7** — pas de `main()` dans mirror (201 l.) ni register-hydra (152 l.) ;
   code top-level entrelacé entre fonctions (mirror:78, 107). Google SSG.
5. **S8** — aucune constante `readonly` (`SCRIPT_DIR`, `SCR_HOST`, `SCR_BASE`,
   `WORKDIR`).
6. **S9** — `scripts/mirror-images-to-scr.sh:44-46` : `usage()` auto-parse
   l'en-tête via `sed -n '2,/^set -euo pipefail/p' | head -n 30` — le `head`
   tronquera la liste d'options quand elle s'allongera.
7. **S2** — `scripts/brigade-setup-worktrees.sh:48` : `cp -n … || true` — le
   `|| true` masque un échec réel (perm denied) ; `-n` retourne déjà 0 sur skip.
8. **S3** — pas de timestamps ni `--quiet/--verbose` dans les scripts longs ;
   acceptable pour de l'interactif, à revoir si un script passe en cron/CI.

---

## Recommandations tooling (échelle de complexité)

| Outil actuel | Usage | Recommandé | Pourquoi |
|--------------|-------|------------|----------|
| `sed -n` sur YAML (Makefile:238) | 1 clé plate ancrée (`garage_chart_version`) | **Garder sed** | Rung 2 adapté — yq serait de la sur-ingénierie pour 1 clé ; basculer sur yq seulement si le Makefile extrait d'autres clés du registre |
| grep/sed sur HCL + JSON par `echo` (Makefile:1140-1195, arbor) | Extraction charts/versions + manifest.json | **Supprimer la cible** | Déjà remplacé par `hauler-manifest-gen.py` + hauler (ADR-034) ; maintenir deux chemins = drift garanti |
| Heredoc YAML interpolé (register-hydra:58-142) | Manifest Pod one-shot, 6 variables | **Garder (documenté)** | Rung 3 limite mais le secret n'est jamais interpolé (monté en fichier) et le choix est tracé en en-tête ; alternative : manifest statique + `kubectl apply -f` |
| `curl \| tar` (garage-chart) | Fetch chart tiers | **hauler store** | Le store hauler porte déjà pin + digest ; supprime la dépendance réseau du chemin d'init |

---

## Bonnes pratiques relevées

- **Corpus shellcheck-clean** : 6 scripts, 0 finding à `-S style` — rare.
- **Strict mode documenté** : `set -eu  # NOT pipefail — git | grep -q triggers
  SIGPIPE` (worktrees:4) — la déviation est expliquée, pas subie.
- **Idiome tableau-vide sous `set -u`** :
  `${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}` (brigade-launch:45).
- **Conception post-postmortem** de `launch.sh` : seal key jamais régénérée,
  `cmp` + garde 32 octets, « on-disk wins » avec procédure de récupération
  affichée (l.37-49) — le bug de 2026-04-26 ne peut structurellement plus se
  reproduire.
- **Garde-fou signature disque** avant `wipefs`/`dd` (EM main.tf:131-144) :
  refuse de wiper un disque Talos ou inconnu — fail-safe sur du destructif.
- **Secret jamais interpolé** : register-hydra monte le secret OIDC en fichier
  dans le pod et le lit via `jq --rawfile` — zéro passage par env/JSON shell.
- **Idempotence méthodique** : 201/409 tolérés (register-hydra:132-140),
  `cp -n`, check-before-create worktrees, skopeo copy idempotent,
  `--ignore-not-found`, trap cleanup partout où un artefact temporaire existe.
- **Ergonomie CLI de mirror-images-to-scr.sh** : `--help`, `--dry-run`,
  `--filter`, `--tool` avec détection en échelle skopeo→docker→podman, rapport
  final, `exit 2` sur échec partiel, logs préfixés sur stderr.
- **Compteur `total=$((total + 1))`** (mirror:178) — évite le piège `((i++))`
  sous `set -e`.
- **Boucles d'attente bornées** avec deadline + message d'échec actionnable
  (launch.sh:88-98, 117-128 ; EM main.tf:101-110) — fix b735312 appliqué
  uniformément.
- **Vars TF typées `number`** pour `WAIT_MIN` → pas d'injection arithmétique
  possible dans `$((… WAIT_MIN * 60))`.
- **`k8s-up` fail-fast** : probe vault-backend avant toute action (Makefile:426),
  séquencement par lignes make séparées → arrêt au premier échec.

---

## Prochaines étapes recommandées

1. **Retirer le `head -n 500`** du garde-fou EM (main.tf:138) — 1 ligne,
   supprime un abort intermittent du bootstrap metal (le plus coûteux à
   re-payer : ~10 min de cycle rescue).
2. **Durcir `garage-chart`** : `curl -fsSL` + garde d'existence + (sprint
   suivant) bascule sur le store hauler — supprime une dépendance réseau du
   chemin d'init et une erreur trompeuse.
3. **`SHELL := bash` + `.SHELLFLAGS := -eu -o pipefail -c` +
   `.DELETE_ON_ERROR:`** en tête de Makefile, puis re-passer les recettes à
   pipelines.
4. **`umask 077` + `rm -f pod-with-secrets.yaml`** dans launch.sh (2 lignes).
5. **Dé-hardcoder `/Users/ludwig/...`** des deux scripts brigade
   (`git rev-parse --show-toplevel`).
6. En lot Tier 1 : stderr cosign-sign, gardes hauler, erreurs git worktree
   visibles, `readonly` sur les constantes.

**Handoffs** : les boucles wait-for de register-hydra et launch.sh sont des
responsabilités déplacées déjà tracées par l'audit hanoi du même jour
(`docs/reviews/2026-07-12-audit-hanoi.md`) — pas de nouveau handoff.
La suppression d'arbor relève d'une décision métier (validation hauler
préalable) : DEFERRED, non auto-corrigeable.
