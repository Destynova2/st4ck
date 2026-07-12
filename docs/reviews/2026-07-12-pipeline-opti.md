# st4ck — optimisation pipeline (CI + déploiement)

**Date :** 2026-07-12
**Audit :** `/cli-forge-pipeline` — biomimétisme (fourmis coupeuses, physarum,
fourmis légionnaires, abeilles, mycélium, mitose)
**Périmètre :** `.woodpecker.yml` (16 steps) + pipeline `make k8s-up`
(7 stacks, ~18-20 min mesurés)
**Méthode :** DAG réel reconstruit depuis les `depends_on`, `terraform_remote_state`,
et les CR appliquées — pas depuis la doc.

---

## Résumé exécutif

Le code d'infra est mûr (postmortems, recovery idempotent, détection de split-brain).
**C'est le pipeline qui est en retard.** Trois constats structurants :

1. **La séquentialité de `k8s-up` n'est plus justifiée.** Les deux races citées en
   commentaire dans `CLAUDE.md` (« VMSingle PVC Pending, webhooks Kyverno ») ont
   **toutes les deux été éliminées** par Fix #4 (local-path déplacé vers `cni`) et
   ADR-028 (Kyverno/VictoriaMetrics passés à Flux). Le commentaire est devenu un
   fossile qui bloque une optimisation légitime.

2. **`pki` = ~10 min sur ~18-20 = 55 % du wall-clock.** Toute parallélisation des
   6 autres stacks plafonne à ~25-30 % de gain. Le vrai levier est *dans* `pki`.

3. **Deux bugs de correction, pas de perf** — dont un **faux-vert** qui laisse le
   pipeline déployer contre une API server morte (§B1). À corriger avant toute
   optimisation.

| Axe | Aujourd'hui | Cible réaliste | Gain |
|---|---|---|---|
| `make k8s-up` | ~18-20 min | ~13-14 min (parallèle) → ~8-9 min (pki Helm-native) | 30 % → 55 % |
| `.woodpecker.yml` validate | 16 × `tofu init` séquentiels, 0 cache | matrix + cache providers | 60-80 % |
| `.woodpecker.yml` push docs-only | ~20 min (redéploie les 7 stacks) | ~0 min (skip) | 100 % |
| Score pipeline | **13/60 (22 %)** | 40+/60 | — |

---

## Partie A — Pipeline de déploiement (`make k8s-up`)

### A0. Le DAG documenté est faux

`CLAUDE.md` documente `cni → pki → monitoring → identity → security → storage → flux`
et le présente comme une chaîne de dépendances. **Ce n'est pas le DAG réel.**

Voici le DAG reconstruit depuis le code (`Makefile:425-441`, les `depends_on`, les
`data.terraform_remote_state`, et les CR effectivement appliquées) :

```
cni  (Cilium + local-path-provisioner → StorageClass par défaut)
 │
 └─> pki  (~10 min — CHEMIN CRITIQUE)
      │    openbao-infra + openbao-app + cert-manager + ESO + ClusterIssuer
      │
      ├─> monitoring       ← n'a besoin QUE d'openbao-infra (seed Grafana)
      │                       AUCUNE dépendance à identity/security/storage
      │
      └─> identity         ← pki remote_state + ClusterIssuer
           │                 installe l'opérateur CNPG  ◄── clé
           │
           ├─> security    ← a besoin du CRD CNPG (opérateur installé par identity)
           │
           └─> storage     ← pki remote_state + écrit cnpg-s3-credentials DANS le ns identity
                │
                └─> flux-bootstrap  (n'a besoin que de pki, mais doit rester en dernier)
```

**Deux arêtes réelles que la doc ne mentionne pas — et que le code n'applique pas :**

- **`security` → `identity`** : `stacks/security/main.tf:100` applique
  `kubectl_manifest.openclarity_pg_cluster`, une CR `postgresql.cnpg.io/v1 Cluster`.
  Le CRD vient de `helm_release.cnpg_operator`, qui vit dans **`stacks/identity`**
  (`stacks/identity/main.tf:76`). Le stack `security` n'a **ni `depends_on`, ni
  `terraform_remote_state`** vers `identity` — l'ordre n'est garanti que par la
  séquence de `k8s-up`.
  → **Bug latent** : `make k8s-security-apply` seul sur un cluster frais échoue avec
  `resource [postgresql.cnpg.io/v1/Cluster] isn't valid for cluster`. Exactement le
  même motif que le chicken/egg Kyverno déjà documenté ligne 234 du même fichier.

- **`storage` → `identity`** : `stacks/storage/main.tf:256` crée le secret
  `cnpg-s3-credentials` **dans le namespace `identity`**. Si le ns n'existe pas,
  l'apply échoue. Là encore, aucune dépendance déclarée.

> Ces deux arêtes sont *invisibles* à OpenTofu. Elles ne tiennent que par la
> discipline du Makefile. C'est de la stigmergie sans phéromone : la trace existe
> dans l'ordre d'exécution, pas dans le graphe.

### A1. Les deux races qui justifiaient la séquentialité sont mortes

`CLAUDE.md` :
> *« Note: pipeline was initially parallel (make -j2) but race conditions
> (VMSingle PVC Pending, Kyverno webhooks) imposed sequential mode. »*

**Race 1 — VMSingle PVC Pending.** Cause racine : `local-path-provisioner` vivait
dans le stack `storage`, déployé **après** `monitoring`. La StorageClass par défaut
n'existait donc pas quand `monitoring` créait sa PVC. **Corrigé deux fois :**
- Fix #4 (commit `9acf931`) a déplacé `local-path-provisioner` vers le stack `cni`
  (`stacks/cni/main.tf:66`). La StorageClass existe désormais avant *tout* stack.
- ADR-028 : `monitoring` **n'installe plus VMSingle du tout** en Tofu. Le stack ne
  contient plus que ns + secret Grafana + seed OpenBao + ConfigMap
  (`stacks/monitoring/main.tf` — aucun `helm_release`). VictoriaMetrics est Flux-owned.

→ La race n'a plus de support matériel. Elle ne peut plus se produire.

**Race 2 — webhooks Kyverno.** Kyverno est **Flux-owned** depuis ADR-028. Le stack
`security` en Tofu ne crée que : ns, cluster CNPG, ExternalSecrets, et une
`ClusterPolicy` **gardée par `count`** sur l'existence du CRD
(`stacks/security/main.tf:237-244`) :

```hcl
data "kubernetes_resources" "kyverno_clusterpolicy_crd" { ... }
resource "kubectl_manifest" "cosign_verify_policy" {
  count = length(data.kubernetes_resources.kyverno_clusterpolicy_crd.objects) > 0 ? 1 : 0
```

→ **Aucun webhook Kyverno n'est vivant pendant les `tofu apply`.** Kyverno arrive
après, via Flux. La race est structurellement impossible.

**Conclusion : la contrainte séquentielle est vestigiale.** Elle coûte ~5 min par
déploiement pour se protéger de deux bugs qui n'existent plus.

### A2. Plan de parallélisation (vagues sûres)

Le `k8s-up` actuel enchaîne des `$(MAKE) x-apply` en lignes de recette successives —
`make -j` n'y peut rien, les lignes d'une recette sont séquentielles par
construction. Il faut passer par de vraies **prérequis-cibles** pour que
l'ordonnanceur de make puisse paralléliser.

```make
# ─── k8s-up : vagues parallèles (remplace le k8s-up séquentiel) ──────────
# DAG réel (voir docs/reviews/2026-07-12-pipeline-opti.md) :
#   cni → pki → { monitoring ∥ identity } → { security ∥ storage } → flux
#
# Les arêtes security→identity (CRD CNPG) et storage→identity (ns identity,
# secret cnpg-s3-credentials) sont RÉELLES : ne pas les casser.
#
# Les races historiques (VMSingle PVC / webhooks Kyverno) sont éteintes :
#   - local-path-provisioner est dans cni depuis Fix #4 (StorageClass dispo)
#   - Kyverno + VictoriaMetrics sont Flux-owned (ADR-028) — aucun webhook
#     vivant, aucun VMSingle créé, pendant les tofu apply.

.PHONY: k8s-up k8s-wave1 k8s-wave2

k8s-up: ## Deploy every k8s stack (parallel waves — use with -j4)
	@curl -so /dev/null -w '%{http_code}' $(VB_URL)/state/test 2>/dev/null | grep -qE '^(2|4)' \
		|| { echo "ERROR: vault-backend unreachable at $(VB_URL)."; exit 1; }
	$(MAKE) k8s-cni-apply
	$(MAKE) k8s-pki-apply
	$(MAKE) -j2 k8s-wave1
	$(MAKE) -j2 k8s-wave2
	$(MAKE) flux-bootstrap-apply

k8s-wave1: k8s-monitoring-apply k8s-identity-apply   # indépendants
k8s-wave2: k8s-security-apply   k8s-storage-apply    # tous deux après identity
```

**Sûreté — ce qui NE peut PAS entrer en conflit :**
- États Tofu : un chemin distinct par stack (`$(CTX_PATH)/{stack}`) → pas de lock partagé.
- Répertoires : `tofu -chdir=` par stack → pas de `.terraform/` concurrent.
- Seeds OpenBao concurrents (`monitoring` + `identity` font tous deux `bao login`) :
  OpenBao gère les sessions concurrentes ; les seeds sont idempotents (`seed_if_absent`).
- Helm concurrent sur des namespaces distincts : sans risque.

**Gain :** vague1 = max(monitoring 2, identity 1) = 2 min au lieu de 3.
vague2 = max(security 2, storage 2) = 2 min au lieu de 4.
→ **~3 min gagnées** sur la partie post-pki (7,5 min → 4,5 min).

Wall-clock : **~18-20 min → ~14-16 min**. C'est réel, mais ça révèle surtout que
`pki` est le vrai sujet.

### A3. `pki` = 55 % du wall-clock — les vrais leviers

**A3-a. L'optimisation « Pattern 1 » n'a jamais été appliquée aux deux plus longues
attentes du pipeline.**

Le repo documente une optimisation systématique (`stacks/pki/secrets.tf:154-159`) :

> *« Phase F-bis: 60×sleep 5 (max 5min) → 300×sleep 1 (max 5min) […] dropping sleep
> to 1s gives a [gain] […] Explicit timeout exit instead of fall-through »*

Elle a bien été appliquée à `stacks/pki/secrets.tf:163`, `stacks/monitoring/main.tf`
(seq 300, sleep 1) et `stacks/storage/main.tf` (seq 300/150, sleep 1).

**Elle a été oubliée exactement là où elle compte le plus** — les deux boucles
`scale_to_ha`, qui gardent les deux attentes les plus longues du déploiement :

| Fichier:ligne | Boucle | Intervalle | Devrait être |
|---|---|---|---|
| `stacks/pki/main.tf:259` | attente `openbao-infra-0` Ready + leader + init blocks | `seq 1 90` / **`sleep 5`** | `seq 1 450` / `sleep 1` |
| `stacks/pki/main.tf:429` | attente `openbao-app-0` Ready + leader + init blocks | `seq 1 90` / **`sleep 5`** | `seq 1 450` / `sleep 1` |
| `stacks/pki/main.tf:319,329,349` | boucles recovery split-brain infra | `sleep 5` | `sleep 1` |
| `stacks/pki/main.tf:479,489` | boucles recovery split-brain app | `sleep 5` | `sleep 1` |

À budget de timeout identique (450 s), passer à `sleep 1` réduit la latence de
détection moyenne de 2,5 s à 0,5 s par transition d'état. Sur ~5 boucles × 2 OpenBao,
**gain ~30-60 s**, à risque nul, et cohérent avec une convention déjà écrite dans le repo.

> Gain modeste, mais c'est une dette d'optimisation déjà décidée et à moitié livrée.

**A3-b. `openbao-infra` et `openbao-app` sont des frères parallèles dans le graphe —
vérifier qu'ils le sont vraiment à l'exécution.**

`helm_release.openbao_app` (`stacks/pki/main.tf:370`) déclare :
```hcl
depends_on = [kubernetes_namespace.secrets, kubernetes_secret.openbao_seal_key,
              kubectl_manifest.openbao_app_cert]
```
**Aucune arête vers `openbao_infra`.** Idem pour `openbao_app_scale_to_ha`, qui ne
dépend que de son propre `helm_release`. OpenTofu (parallelism=10 par défaut)
**devrait** donc dérouler les deux danses HA en parallèle → `pki ≈ max(infra, app)`,
pas `infra + app`.

Or `CLAUDE.md` note : *« ~10min avec scripts scale 1→3 séquentiels »*. Deux hypothèses :
- **(H1)** ils sont déjà parallèles, et les 10 min sont le coût réel de la danse HA
  (helm install → pod-0 ready → init blocks séquentiels → scale 1→3 → attente raft join).
- **(H2)** quelque chose les sérialise → **~4-5 min à récupérer immédiatement**.

**À mesurer avant de coder** (c'est la mesure qui décide, pas l'intuition) :
```bash
TF_LOG=INFO tofu -chdir=stacks/pki apply -auto-approve \
  -var="kubeconfig_path=$HOME/.kube/$CTX_ID" 2>&1 \
  | grep -E 'openbao_(infra|app).*(Creating|Creation complete|Still creating)' \
  | ts '[%H:%M:%S]'
```
Si les timestamps de `openbao_infra` et `openbao_app` se chevauchent → H1 (passer à A3-c).
S'ils sont disjoints → H2, et la sérialisation est le bug à traquer.

**A3-c. Le vrai gain : `openbao-app` n'est sur le chemin critique de personne.**

Le `ClusterSecretStore` (`stacks/pki/main.tf:604`) pointe vers **`openbao-infra`**.
ESO lit depuis `openbao-infra`. `openbao-app` sert les secrets *applicatifs*, consommés
en day-2. Dans le graphe Tofu, `terraform_data.openbao_app_scale_to_ha` est une
**feuille** : rien n'en dépend.

→ Sortir la montée en HA d'`openbao-app` du chemin day-1 (la laisser à 1 réplica,
puis laisser Flux la porter à 3 en day-2) retire une danse de ~4-5 min du wall-clock
**si H2 est vraie**. Si H1 est vraie, le gain est nul — d'où la mesure d'abord.

**A3-d. Fix structurel (déjà sur la roadmap) : HA Helm-native.**

`CLAUDE.md` mentionne déjà « Helm-native HA migration (Phase F-bis-2 roadmap) viserait
~3-4min ». C'est le seul changement qui attaque les 10 min à la racine : supprimer les
deux `terraform_data.*_scale_to_ha` (et leurs ~200 lignes de recovery split-brain) au
profit d'un chart qui gère le `retry_join` correctement.

C'est **le** ticket à ~6 min de gain. Il est hors périmètre de cet audit, mais c'est
lui qui domine tout le reste.

### A4. Deux frottements mineurs dans `k8s-up`

**Le pré-`-target` sur le ns `storage` repose sur un commentaire faux.**
`Makefile:433-438` :
```make
@# Pre-create storage namespace before pki (cnpg-s3 secret target ns).
$(TF) -chdir=$(TF_STORAGE) apply ... -target=kubernetes_namespace.storage
```
Vérification : `cnpg-s3-credentials` est créé par **`storage` dans le ns `identity`**
(`stacks/storage/main.tf:256,265`), pas par `pki` dans le ns `storage`. `pki` ne
référence le mot « storage » que comme **chemin KV OpenBao**
(`secret/storage/garage`, `secret/storage/harbor` — `stacks/pki/secrets.tf:211-216`),
pas comme namespace K8s.

→ Le commentaire décrit une dépendance qui n'existe pas (ou plus). Ce pré-apply coûte
un `tofu init` complet du stack storage **+ le `curl` de `garage-chart`** (via
`k8s-storage-init`) au tout début du pipeline. À vérifier puis probablement supprimer :
```bash
grep -rn 'namespace *= *"storage"' stacks/pki/   # → attendu : aucun résultat
```

**`garage-chart` : SPOF réseau + tarball non vérifiée.**
`Makefile:241-243` — à **chaque** `k8s-up` :
```make
curl -sL "https://git.deuxfleurs.fr/Deuxfleurs/garage/archive/$(GARAGE_CHART_VERSION).tar.gz" | tar -xz ...
```
- Aucun cache : re-téléchargé à chaque déploiement (violation physarum — pas de mémoire).
- Aucune vérification d'intégrité : une tarball tierce est pipée directement dans `tar -xz`.
- Aucun fallback : `git.deuxfleurs.fr` down = `k8s-up` mort (violation mycélium).

Correctif (cache + checksum + idempotence) :
```make
garage-chart: $(GARAGE_CHART)/Chart.yaml
$(GARAGE_CHART)/Chart.yaml:
	@test -n "$(GARAGE_CHART_VERSION)" || { echo "Error: garage_chart_version missing"; exit 1; }
	@mkdir -p $(GARAGE_CHART)
	@curl -sfL --retry 3 --retry-delay 2 \
		"https://git.deuxfleurs.fr/Deuxfleurs/garage/archive/$(GARAGE_CHART_VERSION).tar.gz" \
		-o $(OUT_DIR)/garage-$(GARAGE_CHART_VERSION).tar.gz
	@echo "$(GARAGE_CHART_SHA256)  $(OUT_DIR)/garage-$(GARAGE_CHART_VERSION).tar.gz" | sha256sum -c -
	@tar -xz --strip-components=4 -C $(GARAGE_CHART) \
		-f $(OUT_DIR)/garage-$(GARAGE_CHART_VERSION).tar.gz "garage/script/helm/garage/"
```
(`GARAGE_CHART_SHA256` à épingler dans `versions-configmap.yaml`, à côté du pin de version
— cohérent avec l'esprit du registre de versions et avec ADR-034/hauler.)

---

## Partie B — `.woodpecker.yml`

### DAG actuel : une chaîne de 14 maillons

```
validate ─┬─> test-tftest
          └─> update-bootstrap   (path: bootstrap/**)

start-builder (path: image) ─> wait-image-upload ─> build-image ─> deploy-cluster
   └─ AUCUN depends_on ! tourne en parallèle de validate
                                                          │
                                                   wait-api
                                                          │
   deploy-cni → deploy-pki → deploy-monitoring → deploy-identity
              → deploy-security → deploy-storage → deploy-flux
```

Le tronçon de déploiement est un **calque exact du `k8s-up` séquentiel** — il hérite
donc de tous les constats de la Partie A, plus ses propres pathologies.

### B1. 🔴 BUG — `wait-api` est un faux-vert

`.woodpecker.yml:208-213` :
```yaml
echo "Waiting for API server..."
for i in $$(seq 1 30); do
  tofu output -raw kubeconfig | kubectl --kubeconfig /dev/stdin get nodes >/dev/null 2>&1 && break
  echo "  attempt $$i/30..." && sleep 10
done
echo "API server ready."          # ← s'exécute MÊME si les 30 tentatives ont échoué
```

**Il n'y a aucun contrôle post-boucle.** Si l'API server ne répond jamais, la boucle
s'épuise (300 s), affiche `API server ready.`, et **sort en 0**. `deploy-cni` démarre
alors contre un cluster mort, et l'échec réel remonte 3 steps plus loin, déguisé.

Aggravant, ligne 202 : `apk add --no-cache kubectl >/dev/null 2>&1 || true`. Si l'ajout
de `kubectl` échoue (registre alpine indisponible), le binaire est absent, **chaque**
itération échoue, et le faux-vert se déclenche systématiquement.

C'est exactement l'anti-pattern que le repo a déjà identifié et corrigé côté Tofu
(`stacks/pki/secrets.tf:159` : *« Explicit timeout exit instead of fall-through »*).
Le même bug survit dans la CI.

**Correctif :**
```yaml
commands:
  - |
    set -eu
    VB=http://host.containers.internal:8080
    apk add --no-cache kubectl        # PAS de `|| true` : échec = échec
    cd envs/scaleway
    tofu init -input=false \
      -backend-config="address=$$VB/state/scaleway" \
      -backend-config="lock_address=$$VB/state/scaleway" \
      -backend-config="unlock_address=$$VB/state/scaleway" >/dev/null
    tofu output -raw kubeconfig > /tmp/kubeconfig     # produit UNE fois (cf. B4)
    echo "Waiting for API server..."
    READY=0
    for i in $$(seq 1 30); do
      if kubectl --kubeconfig /tmp/kubeconfig get nodes >/dev/null 2>&1; then
        READY=1; break
      fi
      echo "  attempt $$i/30..."; sleep 10
    done
    [ "$$READY" -eq 1 ] || { echo "ERROR: API server not ready after 5 min"; exit 1; }
    echo "API server ready."
```

### B2. 🔴 `start-builder` peut brûler une VM facturée sur un arbre qui ne compile pas

`start-builder` (ligne 76) n'a **aucun `depends_on`** → Woodpecker le lance
immédiatement, en parallèle de `validate`. Il crée `scaleway_instance_server.builder`
(facturé). Si `validate` échoue, le pipeline s'arrête… mais la VM a déjà été créée, et
`build-image` (qui la détruit/consomme) ne tournera jamais → **VM orpheline facturée**.

**Correctif :** `depends_on: [validate]`. Coût : quelques dizaines de secondes.
Bénéfice : plus jamais de VM orpheline sur un arbre cassé.

### B3. 🔴 Aucun cache — 20+ `tofu init` par pipeline, providers re-téléchargés à chaque fois

Le step `validate` boucle **séquentiellement** sur 16 répertoires, chacun faisant
`tofu init -backend=false` → **16 téléchargements complets de providers** depuis
`registry.opentofu.org`. `test-tftest` en refait 4. Chaque step de déploiement (7) en
refait 2 (envs/scaleway + le stack). **Zéro `TF_PLUGIN_CACHE_DIR`, zéro volume de cache,
zéro miroir.**

C'est le poste n°1 de wall-clock CI **et** un SPOF (violation mycélium : si
`registry.opentofu.org` tousse, tout le pipeline tombe).

Bonne nouvelle : **les 18 `.terraform.lock.hcl` sont commités** → la clé de cache
content-hashed est déjà là, gratuite.

```yaml
variables:
  - &tofu_image ghcr.io/opentofu/opentofu:1.9
  - &tofu_cache
    environment:
      TF_PLUGIN_CACHE_DIR: /woodpecker/cache/tofu-plugins
      TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE: "0"

steps:
  - name: restore-cache
    image: meltwater/drone-cache
    settings:
      restore: true
      # Clé content-hashed sur les lockfiles : cache invalidé si et seulement si
      # un provider change (physarum : renforcer le chemin, l'oublier s'il change).
      cache_key: 'tofu-{{ checksum ".terraform.lock.hcl" }}'
      mount: [ /woodpecker/cache/tofu-plugins ]
```

Puis **fan-out** du `validate` (fourmis légionnaires — 16 dirs indépendants) au lieu
de la boucle `for` séquentielle :

```yaml
  - name: validate
    image: *tofu_image
    <<: *tofu_cache
    matrix:
      DIR:
        - envs/scaleway/iam
        - envs/scaleway/image
        - envs/scaleway
        - envs/scaleway/ci
        - stacks/cni
        - stacks/monitoring
        - stacks/pki
        - stacks/identity
        - stacks/security
        - stacks/storage
        - stacks/flux-bootstrap
        - stacks/autoscaling
        - stacks/capi
        - stacks/kamaji
        - stacks/managed-cluster
        - stacks/gateway-api
    commands:
      - test -d "$${DIR}" || { echo "skip $${DIR} (absent on this branch)"; exit 0; }
      - cd "$${DIR}"
      - tofu init -backend=false -input=false
      - tofu fmt -check -recursive      # gate gratuit, actuellement absent
      - tofu validate
```

**Gain attendu : 60-80 %** sur le step le plus lent (cache + parallélisme).
Bonus : un échec ne masque plus les 15 autres dirs (aujourd'hui `FAIL=1` continue mais
noie le signal dans un seul log géant).

### B4. 🟠 Le kubeconfig est reconstruit 7 fois (chacune = un `tofu init` complet)

L'ancre `&deploy_stack` (ligne 225) est répliquée par les 7 steps de déploiement, et
chacune fait :
```sh
cd envs/scaleway && vb_init scaleway && tofu output -raw kubeconfig > /tmp/kubeconfig
```
→ **7 × `tofu init` du module `envs/scaleway`** (téléchargement providers scaleway +
talos inclus) uniquement pour relire un output.

C'est la fourmi qui refait 7 fois le trajet au lieu de déposer la feuille (violation
stigmergie). Le kubeconfig doit être **produit une fois par `wait-api`** (cf. correctif
B1) et **transporté comme artefact** :

```yaml
  - name: wait-api
    # ... (voir B1) ... produit /woodpecker/src/.kubeconfig
    commands:
      - tofu output -raw kubeconfig > /woodpecker/src/.kubeconfig

  - name: deploy-cni
    commands: &deploy_stack
      - |
        set -eu
        VB=http://host.containers.internal:8080
        cd /woodpecker/src/stacks/$${STACK}
        tofu init -input=false \
          -backend-config="address=$$VB/state/$${STACK}" \
          -backend-config="lock_address=$$VB/state/$${STACK}" \
          -backend-config="unlock_address=$$VB/state/$${STACK}"
        tofu apply -auto-approve -var="kubeconfig_path=/woodpecker/src/.kubeconfig"
```
(`/woodpecker/src` est le workspace partagé entre steps — pas besoin de plugin artefact.)

**Gain : ~7 `tofu init` supprimés** (+ cohérent avec B3 : ceux qui restent tapent le cache).

### B5. 🟠 Aucun élagage — un push docs-only redéploie les 7 stacks

`validate`, `test-tftest` et les 7 `deploy-*` n'ont **aucun filtre `path:`**. Corriger
une faute de frappe dans un README déclenche : validate (16 dirs) + tofu test + build-image
+ deploy-cluster + les 7 stacks. **~20 min pour zéro changement fonctionnel.**

Seuls `start-builder` et `update-bootstrap` sont path-filtrés — la preuve que le réflexe
existe déjà, il n'a juste pas été généralisé.

```yaml
  - name: deploy-pki
    when:
      - event: push
        branch: main
        path:
          - "stacks/pki/**"
          - "clusters/management/versions-configmap.yaml"   # les pins vivent ici
          - "modules/**"
```
…et ainsi de suite par stack. Attention : conserver le chaînage `depends_on` — dans
Woodpecker un step *skippé* est traité comme réussi pour ses dépendants, donc un skip
de `deploy-pki` ne bloque pas `deploy-monitoring`. C'est bien le comportement voulu
(le stack est déjà en place ; Flux tient le day-2).

### B6. 🟠 `wait-image-upload` : un marqueur périmé = succès instantané, un marqueur absent = 15 min de mort

`wait-image-upload` (ligne 106) sonde `.upload-complete` dans le bucket S3. Mais :
- il **n'a pas** le filtre `path:` de `start-builder` → il tourne à chaque push sur main ;
- si `start-builder` a été skippé (pas de changement d'image), le `.upload-complete` du
  **build précédent** est toujours dans le bucket → HTTP 200 → passe instantanément
  (correct par accident) ;
- mais sur un bucket frais / après rotation, il **poll 60 × 15 s = 15 min** puis échoue.

Le marqueur n'est pas versionné : il ne dit pas *quelle* image a été uploadée.
→ Aligner le `path:` de `start-builder` sur `wait-image-upload` et `build-image`, et
versionner le marqueur (`.upload-complete-${schematic_sha7}`) pour que la sonde
teste **l'image attendue**, pas « une » image.

### B7. 🔴 79 manifestes Flux ne sont **jamais** validés

```
stacks/*/flux*/**.yaml   → 79 fichiers
clusters/**/*.yaml       →  6 fichiers
```
Depuis ADR-028, **la majorité des workloads (Kyverno, VictoriaMetrics, Kratos, Hydra,
Pomerium, Trivy, Tetragon, OpenClarity…) sont Flux-owned** — donc décrits dans ces YAML.
Or la CI ne lance que `tofu validate`, qui **ne les regarde pas**.

**Une YAML cassée dans `stacks/*/flux/` passe la CI au vert et n'échoue qu'au reconcile
Flux, en cluster, sans gate.** C'est aujourd'hui le plus gros trou de couverture du
pipeline : le centre de gravité du déploiement a migré vers Flux, la validation est
restée sur Tofu.

```yaml
  - name: validate-manifests
    image: ghcr.io/yannh/kubeconform:latest-alpine
    commands:
      - |
        set -eu
        # CRDs custom (Flux, Kyverno, CNPG, ESO, VictoriaMetrics…) → schémas distants
        find stacks clusters -path '*flux*' -name '*.yaml' -print0 \
          | xargs -0 -P 8 -n 16 kubeconform \
              -strict -ignore-missing-schemas -summary \
              -schema-location default \
              -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
    depends_on: []          # lane indépendante — feedback rapide
```
Et un `kustomize build` sur `clusters/management/` pour attraper les kustomizations cassées :
```yaml
  - name: validate-kustomize
    image: registry.k8s.io/kustomize/kustomize:v5.4.3
    commands:
      - kustomize build clusters/management > /dev/null
    depends_on: []
```

### B8. 🟠 `gitleaks` est en pre-commit, pas en CI

`.pre-commit-config.yaml` déclare `gitleaks`, et `.gitleaks.toml` existe. Mais
**aucun step CI ne le lance** → un contributeur sans hook installé (ou un `--no-verify`)
pousse un secret sans filet. Le pre-commit est une politesse ; la CI est le gate.

```yaml
  - name: gitleaks
    image: zricethezav/gitleaks:latest
    commands: [ gitleaks detect --source=. --config=.gitleaks.toml --redact --verbose ]
    depends_on: []
```
Manquent aussi (D8) : scan de config IaC (`trivy config .` / `checkov`), et le
`shellcheck` des 5 scripts shell de `scripts/` (dont `mirror-images-to-scr.sh`, 7 Ko).

### B9. 🟠 Mitose — un méga-pipeline de 16 steps

`.woodpecker.yml` mélange trois cycles de vie qui n'ont ni la même fréquence, ni le même
rayon d'action, ni le même profil de risque :
- **validation** (chaque PR, secondes, zéro secret, zéro coût),
- **build d'image** (rare, path-gated, VM facturée),
- **déploiement** (push main, ~20 min, tous les secrets, mute le cluster).

Woodpecker supporte les workflows multiples (`.woodpecker/*.yml`). Scinder :
```
.woodpecker/validate.yml   # PR + push : fmt, validate (matrix), tftest, kubeconform,
                           #             kustomize, gitleaks — tout en parallèle, 0 secret
.woodpecker/image.yml      # push main + path: image → builder VM
.woodpecker/deploy.yml     # push main + path: stacks/** → cluster + stacks
```
Bénéfice immédiat : les PR n'attendent plus derrière la machinerie de déploiement, et
les secrets de déploiement ne sont plus chargés dans un pipeline déclenché par une PR.

---

## Scorecard — 15 dimensions

| # | Dimension | Score | Justification |
|---|---|:---:|---|
| D1 | DAG | 1/4 | Quelques `depends_on`, mais chaîne quasi-linéaire de 14 maillons ; `start-builder` sans dépendance |
| D2 | Cache | **0/4** | Aucun. 20+ `tofu init` par run, providers re-téléchargés à chaque fois |
| D3 | Parallélisme | 1/4 | `validate` = boucle `for` séquentielle sur 16 dirs ; pas de matrix |
| D4 | Résilience | 1/4 | Aucun retry, aucun fallback registre, `\|\| true` qui masque (B1). Le *code* est résilient (recovery split-brain), pas le pipeline |
| D5 | Feedback | 1/4 | Premier signal = `validate` (lent) ; pas de lane smoke ; deploy ~20 min |
| D6 | Élagage | 1/4 | `path:` sur 2 steps / 16. Un push docs-only redéploie tout |
| D7 | Artefacts | **0/4** | Aucun. Kubeconfig reconstruit 7× via 7 `tofu init` |
| D8 | Sécurité | 1/4 | gitleaks en pre-commit seulement ; pas de scan IaC, pas de shellcheck, pas de SBOM en CI |
| D9 | Observabilité | 1/4 | Durées par step (natif Woodpecker) ; aucun timeout, aucune alerte de dérive |
| D10 | Mitose | **0/4** | 1 méga-pipeline : validation + build + déploiement mélangés |
| D11 | Coût | 1/4 | `path:` sur `start-builder` = conscience du coût, mais VM orpheline possible (B2) |
| D12 | DX | 3/4 | Makefile excellent (`make help`, `make context`), docs solides, ADR — le point fort |
| D13 | Fuzzing | 1/4 | `.tftest.hcl` présents (4 dirs) = tests de propriété embryonnaires |
| D14 | Matrice | 1/4 | `contexts/` est l'axe de matrice naturel, mais la CI ne teste qu'un contexte implicite |
| D15 | Chaos | **0/4** | Aucune injection de panne |

**TOTAL : 13/60 (22 %)** — cible production : > 45/60.

> Le décalage entre D12 (3/4) et le reste raconte l'histoire : **l'outillage
> développeur est mûr, le pipeline ne l'est pas.** Toute l'intelligence est dans le
> Makefile et dans les postmortems ; la CI n'en a presque rien capitalisé.

---

## Mutation testing du pipeline

| Mutation | Attendu | Réel | Verdict |
|---|---|---|---|
| Casser l'API server pendant `wait-api` | pipeline rouge | **vert**, `deploy-cni` démarre | 🔴 **B1 confirmé** |
| Retirer `kubectl` de l'image `wait-api` | pipeline rouge | **vert** (`\|\| true` + faux-vert) | 🔴 **B1 confirmé** |
| YAML invalide dans `stacks/pki/flux/` | pipeline rouge | **vert** (jamais validé) | 🔴 **B7 confirmé** |
| Secret en clair dans un `.tf` | pipeline rouge | **vert** (gitleaks absent de la CI) | 🔴 **B8 confirmé** |
| `validate` échoue | pas de VM facturée | **VM créée** (pas de `depends_on`) | 🔴 **B2 confirmé** |
| `make k8s-security-apply` sur cluster frais | succès | **échec** (CRD CNPG absent) | 🔴 **A0 confirmé** |
| Retirer un `depends_on` de deploy | step trop tôt | rouge | 🟢 OK |

**6 mutations sur 7 passent silencieusement.** Le seuil du skill est « > 2 = le pipeline
a des trous ». Il en a six.

---

## Plan d'action priorisé

### P0 — Correction (avant toute optimisation)
1. **B1** — faux-vert `wait-api` : ajouter le contrôle post-boucle + retirer le `|| true`
   sur `apk add`. *(15 min, corrige un gate qui ment)*
2. **B2** — `start-builder: depends_on: [validate]`. *(2 min, stoppe la fuite de coût)*
3. **A0** — déclarer les arêtes réelles `security → identity` et `storage → identity`
   (a minima : commentaire + garde `data.kubernetes_resources` sur le CRD CNPG, comme
   celle déjà en place pour Kyverno). *(30 min, supprime un bug latent)*

### P1 — Wall-clock CI (gros gains, faible risque)
4. **B3** — `TF_PLUGIN_CACHE_DIR` + cache content-hashed sur les 18 `.terraform.lock.hcl`,
   et `validate` en `matrix:`. *(2 h, −60-80 % sur le step le plus lent)*
5. **B4** — kubeconfig produit une fois, passé via `/woodpecker/src`. *(1 h, −7 `tofu init`)*
6. **B5** — filtres `path:` par stack. *(1 h, un push docs-only ≈ 0 min au lieu de 20)*

### P2 — Couverture (les trous, pas la vitesse)
7. **B7** — `kubeconform` + `kustomize build` sur les 79+6 manifestes Flux.
   *(2 h — c'est le plus gros trou de couverture du repo)*
8. **B8** — `gitleaks` + `trivy config` + `shellcheck` en CI. *(1 h)*

### P3 — Wall-clock déploiement
9. **A3-b** — **mesurer** si `openbao-infra` et `openbao-app` se chevauchent
   (commande fournie §A3-b). Décide si A3-c vaut 0 ou ~5 min. *(30 min — mesurer avant de coder)*
10. **A2** — `k8s-up` en vagues parallèles. *(1 h, −3 min)*
11. **A3-a** — appliquer « Pattern 1 » (`sleep 5` → `sleep 1`) aux boucles `scale_to_ha`
    oubliées. *(30 min, −30-60 s, dette déjà décidée)*
12. **A4** — vérifier/supprimer le pré-`-target` du ns storage ; mettre en cache +
    checksum `garage-chart`. *(1 h)*

### P4 — Structure
13. **B9** — mitose : `.woodpecker/{validate,image,deploy}.yml`. *(3 h)*
14. **A3-d** — **HA OpenBao Helm-native** (Phase F-bis-2, déjà en roadmap).
    *(le seul ticket qui attaque les 10 min de `pki` à la racine : ~−6 min)*

---

## Pre-mortem — ce qui casse si on parallélise

| Scénario | Mitigation existante ? | Verdict |
|---|---|---|
| `monitoring` + `identity` seedent OpenBao en même temps | Oui — seeds idempotents (`seed_if_absent`), OpenBao gère les sessions concurrentes | ✅ sûr |
| Deux `tofu apply` concurrents sur le même état | Oui — un chemin d'état par stack (`$(CTX_PATH)/{stack}`) | ✅ sûr |
| `security` démarre avant que le CRD CNPG existe | **Non** — ordre implicite seulement | ⚠️ **corriger via P0-3** |
| `storage` écrit `cnpg-s3-credentials` avant que le ns `identity` existe | **Non** | ⚠️ **corriger via P0-3** |
| VMSingle PVC Pending (race historique) | Oui — local-path dans `cni` (Fix #4) **et** VMSingle Flux-owned (ADR-028) | ✅ éteint |
| Webhooks Kyverno bloquants (race historique) | Oui — Kyverno Flux-owned, policy `count`-gated sur le CRD | ✅ éteint |
| Flux reconcile pendant qu'un `tofu apply` tourne encore | Partiel — `flux-bootstrap` reste en dernier | ✅ garder flux en dernier |

**Les deux seuls risques réels de la parallélisation sont les deux arêtes non déclarées
(A0).** Les déclarer est un prérequis, pas une option — et c'est de toute façon un bug
à corriger même en séquentiel.

---

## Ce qu'il faut retenir

Le pipeline est un **fossile de ses propres postmortems** : chaque race passée a laissé
une barrière séquentielle, mais quand la cause racine a été corrigée ailleurs (Fix #4,
ADR-028), **la barrière est restée**. La séquentialité protège aujourd'hui contre des
bugs qui ne peuvent plus se produire, tandis que les vrais trous (faux-vert `wait-api`,
79 manifestes Flux non validés, gitleaks absent de la CI) ne sont gardés par rien.

L'inversion à opérer : **desserrer là où c'est sûr (l'ordre), resserrer là où c'est
troué (les gates).**
