# st4ck — audit Hanoi (ordre des couches)

**Date :** 2026-07-12
**Audit :** `/cli-audit-hanoi` — ordre des couches bootstrap/stacks/Makefile/pipeline
de déploiement (cni avant tout, pki avant identity, registre de versions, handoff
Tofu → Flux)
**Périmètre :** tout le repo — Makefile (1706 l.), bootstrap/, envs/scaleway/,
stacks/*, clusters/management/, patches/, scripts/
**Limite de mesure :** l'historique git ne couvre que 50 commits
(2026-04-30 → 2026-06-13, probablement squashé) avec une chaleur quasi plate
(max 3 touches par fichier). La colonne « fréquence » est donc **estimée** à
partir des scénarios de changement typiques (bump de version, redéploiement
fresh, modification de patch) — confiance abaissée d'un cran là où elle pèse.

---

## Verdict

| Artefact | Stabilité | Légalité | Économie | Déplacement | Pire inversion |
|---|---|---|---|---|---|
| Makefile `k8s-up`/`scaleway-up` | 8 | 6 | 6 | 5 | 12 applies tofu + 2 gestes manuels pour un fresh deploy qui en vaut 8-9 + 0 |
| Registre de versions | 7 | — | 6 | 8 | `vars.mk` : 4 pins morts dont 2 **divergents** (Talos v1.12.6 vs v1.12.4 réel) |
| Handoff Tofu → Flux (ADR-028) | 9 | 7 | 8 | 8 | `clusters/management-eso/` : cadavre pointant sur un HelmRelease ESO que tofu possède déjà |
| Stack pki (interne) | 8 | 5 | 4 | 3 | scale 1→3 séquentiel ×2 en bash local-exec (~10 min mesurées) — déjà au roadmap F-bis-2 |
| Bootstrap (launch.sh + pod + tofu sidecar) | 9 | 7 | 7 | 6 | readiness Gitea payée 2× (script VM + sidecar), ordonnancement par polling croisé |
| Stages envs/scaleway (iam→image→ci→cluster) | 9 | 9 | 8 | 8 | bump Talos = 2 fichiers vivants à synchroniser à la main (+2 pièges morts) |

**Lecture d'ensemble.** Le macro-ordre du pipeline est correct et légal :
cni d'abord (Makefile `k8s-up:422`, gros disque le plus bas), pki avant
identity (ClusterIssuer), flux-bootstrap en dernier (le handoff GitOps).
Bug #31 (PN possédé par le CI) est encodé en fail-fast propre
(`envs/scaleway/main.tf:183` data source par nom → échec bruyant au plan).
Les problèmes sont dans les étages intermédiaires : ordonnancement par
retry/geste manuel là où le graphe pourrait le déclarer, et un registre de
versions excellent au centre mais entouré de pins morts qui mentent.

---

## Inversions et coups perdus (classés par fréquence × coût de redo)

| # | Artefact | Étape mal placée | Loi | Rayon d'impact aujourd'hui | Après correction | Tier / Confiance |
|---|---|---|---|---|---|---|
| 1 | `vars.mk:2-5` | TALOS_VERSION v1.12.6, KUBERNETES_VERSION 1.35.4, CILIUM_VERSION, IMAGER_IMAGE : **zéro consommateur** (seul OUT_DIR est utilisé, `Makefile:1286`). Les vrais pins disent v1.12.4 / 1.35.0 (`contexts/_defaults.yaml:14-16`) | 1+3 | Un bump Talos via vars.mk = no-op silencieux ; CLAUDE.md documente vars.mk comme « Shared version variables » | 1 fichier de moins, 0 piège | T2 / HIGH |
| 2 | Bump Talos réel | Pin vivant en 2 endroits qui doivent matcher : `contexts/_defaults.yaml:14` (machine configs) et `envs/scaleway/image/variables.tf:22` (default, non passé par `SCW_IMAGE_VARS`, `Makefile:608`) + default fallback `modules/talos-cluster/variables.tf:14` | 3 | 1 bump = 2-3 éditions coordonnées ; désynchronisation = image ≠ config déclarée | 1 édition (registre ou contexts comme SSOT, defaults supprimés ou dérivés) | T2 / HIGH |
| 3 | `Makefile:236-240` (`garage-chart`) | Version chart Garage `v2.2.0` en dur dans une URL curl — hors registre (`versions-configmap.yaml` ne connaît pas garage), invisible pour hauler/arbor | 1+3 | Bump garage = éditer le Makefile ; le registre prétend « Version bumps = edit this one file » (`clusters/management/kustomization.yaml:10`) | pin dans versions-configmap, lu par le target | T2 / HIGH |
| 4 | `contexts/_defaults.yaml:16` | `cilium_version: "1.17.13"` : aucun consommateur trouvé (envs/, modules/, patches/) — le vrai pin vit dans versions-configmap (consommé par `stacks/cni/main.tf:40`) | 1 | 3e pin cilium dont 2 morts ; un bump du registre laisse 2 valeurs périmées qui piègent le prochain lecteur | supprimer (ou brancher réellement) | T2 / MEDIUM |
| 5 | `clusters/management-eso/kustomization.yaml:8` | Répertoire mort référençant `stacks/external-secrets/flux/` (HelmRelease ESO) alors que la Kustomization `management-eso` a été supprimée (`stacks/flux-bootstrap/main.tf:382-388`) et qu'ESO est tofu-owned (`stacks/pki/main.tf:578`) | 2 | Re-câblage accidentel = double propriétaire du release ESO — exactement le bug « CRD storedVersions invalid » qui a motivé l'ADR-028. 3 commentaires prétendent encore que le dependsOn existe (`clusters/management/kustomization.yaml:3-6`, `stacks/external-secrets/flux/kustomization.yaml:6`, `flux-config/kustomization.yaml:5`) | supprimer management-eso/ + external-secrets/flux/ ; corriger les 3 commentaires | T2 / HIGH |
| 6 | `stacks/monitoring/main.tf:224-231` | VMRule flux-alerts gated sur `count = CRD existe ?` : premier apply → count=0, silencieux. Rien dans le pipeline ne rejoue `k8s-monitoring-apply` après que Flux ait posé le CRD | 2+3 | **Un cluster fresh n'a aucune alerte Flux** tant qu'un humain ne rejoue pas l'apply — le coup manquant n'est jamais joué | déplacer la VMRule côté Flux, split deux-phases Kustomization (le pattern existe déjà 3× : `security-kyverno.yaml:28-31`, openclarity, harbor) | T2 / HIGH |
| 7 | `Makefile:198-207, 219-227` | identity et security en 3 phases chacune (apply `-target` → `kubectl wait --for=create secret` → full apply) : l'ordonnancement CNPG vit dans l'orchestrateur | 2+4 | Fresh deploy = 6 applies au lieu de 2 ; `tofu apply` lancé hors-make casse au premier coup (ordering par retry) | wait CNPG dans la stack (terraform_data, pattern déjà omniprésent dans le repo) → 1 apply par stack | T2 / MEDIUM |
| 8 | `Makefile:429` | Apply `-target=kubernetes_namespace.storage` de la stack storage AVANT pki (le secret cnpg-s3 seedé par pki cible ce namespace) | 4 | Chaque fresh deploy paie 1 init+apply supplémentaire de storage ; connaissance d'ordre codée dans k8s-up | le propriétaire du besoin (pki) crée/garantit le namespace, ou le secret passe par ESO côté storage — NEEDS-REVIEW (conflit de propriété du ns) | T2 / MEDIUM |
| 9 | `Makefile:304-309, 922` | `oidc-register` (Bug #35) n'est chaîné nulle part : `scaleway-up` se termine sans lui et sans même l'annoncer | 3 | 1 geste manuel oubliable par fresh deploy → login OIDC K8s cassé, découvert plus tard | chaîner en fin de `scaleway-up` (le `kubectl wait` interne borne à 5 min) — NEEDS-REVIEW (délai de reconcile Flux) | T2 / MEDIUM |
| 10 | `stacks/pki/main.tf:235-366, 409-520` | Bring-up HA OpenBao : scale 1→3 séquentiel ×2 instances, gate 90×5s + recovery split-brain automatisée (~130 lignes de bash par instance) | 2+4 | ~10 min mesurées (CLAUDE.md) sur les ~3-4 min cibles ; le plus gros disque wall-clock du pipeline | migration Helm-native HA — **déjà au roadmap Phase F-bis-2**, rien de nouveau à décider | T2 / HIGH (connu) |

Tier 1 (mineurs, en passant) : commentaires « Pin matches
stacks/monitoring/variables.tf … keep them in sync » sur des variables
supprimées (`helmrelease-vlogs-single.yaml:11-12`, `-collector.yaml:13-14`
— les HR utilisent bien `${…_version}`, seul le commentaire ment) ; échos
Makefile périmés (« full apply (Kratos/Hydra/Pomerium…) » `Makefile:206`,
« Trivy + Tetragon + Kyverno + OpenClarity » `Makefile:226` — tout cela est
Flux-owned depuis ADR-028) ; note « Pomerium/OpenClarity restent
tofu-managed » de l'ADR-028 (§Decision) périmée — la migration est allée
plus loin que le texte (`stacks/identity/main.tf` : seul cnpg_operator ;
`stacks/security/main.tf` : zéro helm_release) ; `stacks/registry-mirror/`
absent de `STACKS` (`Makefile:1239`) et de tout target — vérifer si voulu.

---

## Piles réordonnées

### 1. Registre de versions — un seul disque au fond

Aujourd'hui (pins pour le même artefact, du plus bas au plus haut) :

```
versions-configmap.yaml   ← SSOT réel (tofu yamldecode + Flux substituteFrom + hauler)  ✓
contexts/_defaults.yaml   ← talos v1.12.4 ✓ (machine configs) | cilium 1.17.13 ✗ mort
envs/scaleway/image/variables.tf ← talos v1.12.4 (default silencieux, non injecté)
modules/talos-cluster/variables.tf ← talos v1.12.4 (default fallback)
Makefile garage-chart     ← garage v2.2.0 ✗ hors registre
vars.mk                   ← talos v1.12.6 ✗ / k8s 1.35.4 ✗ / cilium ✗ / imager ✗  MORTS + DIVERGENTS
```

Après :

```
versions-configmap.yaml   ← charts + garage_chart_version
contexts/_defaults.yaml   ← talos_version, k8s_version (infra — par cluster, c'est son rôle)
                            image stage reçoit -var="talos_version=…" depuis le contexte
vars.mk                   ← OUT_DIR uniquement (ou suppression, include retiré)
```

Patch sketch : (a) supprimer les 4 lignes de versions de `vars.mk` +
mettre à jour la mention dans CLAUDE.md ; (b) supprimer
`cilium_version` de `contexts/_defaults.yaml` (ou le brancher s'il devait
servir d'override — il ne l'est pas) ; (c) ajouter
`garage_chart_version: "v2.2.0"` au ConfigMap et le lire dans le target
`garage-chart` (`yq`/`grep` une ligne) ; (d) faire passer
`talos_version` du contexte au stage image via `SCW_IMAGE_VARS`.
Gain : bump chart = 1 fichier partout, y compris garage ; bump Talos =
1 fichier ; 0 pin menteur. Effort : faible. Risque : (d) change la valeur
effective si contexts et default divergeaient — vérifier avant.

### 2. Makefile `k8s-up` — déclarer au lieu de rejouer

```
Avant (12 applies + 2 gestes manuels)          Après (8 applies + 0-1 geste)
─────────────────────────────────              ─────────────────────────────
cni                                            cni
storage  -target=ns.storage   ✗ #8            pki           (garantit le ns qu'il seed,
pki                                                           wait CNPG interne si besoin)
monitoring        (VMRule silencieuse ✗ #6)    monitoring    (VMRule partie côté Flux)
identity ×3       ✗ #7                         identity ×1   (wait CNPG in-stack)
security ×3       ✗ #7                         security ×1
storage                                        storage
flux-bootstrap                                 flux-bootstrap
[manuel] k8s-monitoring-apply (VMRule) ✗       [chaîné] oidc-register (NEEDS-REVIEW)
[manuel] oidc-register        ✗
```

La VMRule migre dans `stacks/monitoring/flux/` avec un split deux-phases
(`monitoring-alerts` dependsOn la Kustomization portant vm-stack) — même
recette que Bug #41 kyverno-policies. Le wait CNPG descend dans chaque
stack en `terraform_data` + `kubectl wait --for=create` (le repo utilise
déjà ce pattern partout) ; les cibles `-target` disparaissent et
`tofu apply` nu redevient légal.

### 3. Flux — graphe actuel (pour référence, il est sain)

```
GitRepository management
  └─ Kustomization management (wait:true, prune:true, substituteFrom platform-versions)
       ├─ cni/monitoring/pki/identity/security/storage flux/   (HR avec dependsOn internes :
       │    kratos→hydra→pomerium ; vlogs-single→collector)
       ├─ security-openclarity-eso → security-openclarity      (split deux-phases)
       ├─ storage-harbor-eso      → storage-harbor             (split deux-phases)
       └─ security-kyverno        → security-kyverno-policies  (split deux-phases)
```

Une seule Kustomization racine pour 6 stacks : un HR en échec rend
`management` NotReady en bloc et le prune est global. Split par stack =
meilleure isolation de panne, mais churn réel et risque de prune —
optimization card ci-dessous, pas une recommandation ferme.

---

## Responsabilités déplacées (Loi 4)

| Capacité manquante | Couche naturelle | Compensations trouvées (couche : fichier:ligne) | Fix à la source / consolidation |
|---|---|---|---|
| « OpenBao prêt + login admin » comme gate réutilisable | chart/opérateur OpenBao, ou 1 helper partagé | tofu local-exec : `pki/main.tf:259` (90×5s ×2), `pki/secrets.tf:163` (300×1s), `monitoring/main.tf:151` (300×1s), `flux-bootstrap/main.tf:176` (300×1s) · Makefile : `_scw_seed_iam_body` `Makefile:569` (30×5s) · K8s Job : `pki/flux/job-bootstrap-openbao-pki.yaml:166` (300×1s) · podman : `bootstrap/platform-pod.yaml:339` (until wget) — **7 sites, 4 couches**, budgets divergents (30×5 vs 300×1 vs 90×5) | un `scripts/wait-openbao.sh` (poll + login) invoqué par les couches shell/tofu/Make ; le Job K8s garde sa copie (couche isolée). Préserver les budgets tunés Phase F-bis (commentaires en place) |
| Orchestration raft join HA day-1 | chart Helm OpenBao | `pki/main.tf:235-366` + `409-520` : scale 1→3 séquentiel, gate init-blocks, recovery split-brain (~260 lignes bash en HCL, ×2 instances) | Helm-native HA — roadmap Phase F-bis-2 (~10 min → ~3-4 min). Rien à re-décider ici |
| « Secret CNPG matérialisé » exposé au graphe TF | provider/stack | Makefile : `Makefile:205` (identity), `Makefile:225` (security) — 2 sites, 1 couche mais payé par 2 stacks + interdit le `tofu apply` nu | wait in-stack (terraform_data) — voir pile réordonnée #2 |
| Readiness Gitea (HTTP up) | pod (podman kube play n'a pas de healthcheck-ordering) | `envs/scaleway/ci/launch.sh:88` (60×2s) · `bootstrap/tofu/gitea.tf:29` (300×1s) — 2 payeurs pour le même événement ; les autres boucles (`gitea.tf:47` admin user, `woodpecker.tf:36` OAuth) attendent des événements distincts, légitimes | gap plateforme réel (pas de primitive d'ordre dans podman play kube) — consolidation possible mais gain faible ; laisser, documenté |
| CRD établi avant CR | Flux (le pattern deux-phases existe) | `monitoring/main.tf:224-231` : count-gate VMRule = apply silencieusement incomplet | inversion #6 — migrer côté Flux |
| API K8s joignable post-bootstrap | provider talos (`talos_cluster_health`) | `Makefile:924-938` `scaleway-wait` (30×10s) — 1 site, 1 couche | acceptable tel quel ; candidat data source si le provider s'avère fiable |

Ce qui n'est PAS du déplacement (vérifié, à ne pas « corriger ») :
les probes readiness des charts, le split deux-phases Flux (c'est la
*déclaration* d'ordre, pas un retry), le gate vault-backend de `k8s-up:421`
et le préflight `Makefile:1087` (fail-fast légitime), la boucle
`scaleway-image-wait` (attente d'un processus externe réel, upload S3),
le pattern seed-then-share du ConfigMap platform-versions (tofu day-1,
Flux day-2 — propriétaire unique par période, documenté).

---

## Optimization cards

### Card HANOI-001 — VMRule flux-alerts : count-gate → split Flux deux-phases

**Location** : `stacks/monitoring/main.tf:224-291`
**Observed structure** : la VMRule est créée par tofu seulement si le CRD
existe déjà ; sur cluster fresh le CRD arrive après flux-bootstrap → la
ressource n'existe jamais sans re-apply manuel.
**Operational issue** : cluster fresh sans alerting Flux ; coup manuel non
joué par le pipeline ; drift de plan (+1 ressource après coup).
**Candidate rewrite** : déplacer la VMRule dans `stacks/monitoring/flux/`
appliquée par une Kustomization `monitoring-alerts` qui dependsOn celle qui
porte vm-stack (recette Bug #41).
**Required invariants** : la VMRule ne référence aucun output tofu ;
le prune de l'ancienne ressource tofu est propre (`tofu state rm` ou destroy
ciblé) ; substituteFrom couvre les éventuels placeholders.
**Validation** : fresh deploy chainsaw/manuel → `kubectl get vmrule -n
monitoring flux-alerts` présent sans second apply.
**Expected impact** : correctness high (alerting présent day-1), latence nulle.
**Risk** : low. **Status** : provable_under_assumptions. **Confidence** : 0.85.
**Next owner** : patch direct.

### Card HANOI-002 — Split de la Kustomization racine `management` par stack

**Location** : `stacks/flux-bootstrap/main.tf:390-431`,
`clusters/management/kustomization.yaml`
**Observed structure** : 1 Kustomization (wait:true, prune:true, timeout 5m)
porte 6 stacks + 3 sous-Kustomizations.
**Operational issue** : un HR en échec ⇒ `management` NotReady en bloc
(alerte FluxKustomizationNotReady globale, diagnostic moins précis) ; prune
global = rayon d'impact maximal d'une erreur de kustomization.
**Candidate rewrite** : une Kustomization par stack (cni, monitoring, pki…)
avec dependsOn là où l'ordre est réel, substituteFrom partagé.
**Required invariants** : aucun manifest ne change de propriétaire pendant
la transition (prune !) ; les placeholders `${…}` restent résolus dans
chaque nouvelle Kustomization.
**Validation** : cluster jetable, migration à blanc, `flux tree` avant/après.
**Expected impact** : observabilité/robustesse medium ; wall-clock nul.
**Risk** : medium (prune mal scopé = suppression de ressources vivantes).
**Status** : needs_invariant / NEEDS-REVIEW. **Confidence** : 0.5.
**Next owner** : décision architecture (ADR courte si retenu).

---

## Points à vérifier

- **`vars.mk` v1.12.6 vs contexts v1.12.4** : lequel est l'intention ? Si
  v1.12.6 est la cible d'upgrade, le bump réel n'a jamais été fait (piège
  confirmé) ; si v1.12.4 est la vérité, vars.mk ment depuis son écriture.
- **ClusterSecretStore double-applique** : tofu (`pki/main.tf:603`) et Flux
  (`clusters/management/kustomization.yaml:12` → flux-config) appliquent le
  même fichier. Convergent tant que c'est le même YAML, mais `tofu destroy`
  de pki supprimerait un CR que Flux croit posséder, et l'ADR-028 liste la
  CSS comme tofu-owned sans mentionner le co-applique. À trancher dans
  l'ADR (une ligne).
- **`oidc-register` chaîné à `scaleway-up`** : le `kubectl wait` borne à
  5 min mais dépend du premier reconcile Flux complet (identity HR chain
  kratos→hydra) — mesurer sur un fresh deploy avant de chaîner.
- **Namespace storage pré-créé par k8s-up** : le déplacer dans pki crée un
  conflit de propriété avec `kubernetes_namespace.storage` de la stack
  storage — la variante ESO/PushSecret est peut-être plus propre. Décision
  à prendre avant de toucher (`NEEDS-REVIEW`).
- **`stacks/registry-mirror/`** : hors STACKS, hors clusters/management,
  hors Makefile. Stack en cours, legacy, ou oubli ?
- **Fréquences estimées** : l'historique squashé empêche de pondérer les
  inversions par la chaleur réelle. Si un reflog/historique complet existe
  ailleurs, re-pondérer #7/#8 (leur coût ne pèse que sur les fresh deploys).

## Priorités (gain ÷ effort)

1. **Registre** — inversions #1-#4 : suppressions + 1 clé ConfigMap + 1 var
   passée au stage image. Effort minimal, tue tous les pins menteurs.
2. **Cadavre management-eso + commentaires** — inversion #5 : suppression
   pure, désamorce le retour du bug ADR-028.
3. **VMRule → Flux** — inversion #6 (Card HANOI-001) : pattern existant,
   rend le fresh deploy complet sans geste manuel.
4. **Waits CNPG in-stack** — inversion #7 : 4 applies économisés par fresh
   deploy, `tofu apply` nu redevient valide.
5. **`wait-openbao.sh` partagé** — 7 sites → 1 helper + 1 copie Job.
6. Le reste (#8, #9, Card HANOI-002) après décision — churn réel, gain
   conditionnel. La pile pki (#10) est déjà arbitrée au roadmap : ne pas
   re-litiger ici.
