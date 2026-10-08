# st4ck — audit Hanoi passe 2 (simplification)

**Date :** 2026-07-12
**Audit :** `/cli-audit-hanoi` — passe 2, orientée SIMPLIFICATION, après les fixes
du jour (registre + substituteFrom, arbor→hauler, VMRule two-phase, garage au
registre, triggers CI)
**Périmètre :** les NEEDS-REVIEW restants de la passe 1 + toute nouvelle inversion
**Limite de mesure :** inchangée depuis la passe 1 — historique git plat, aucune
mesure runtime disponible. Les **coups** (applies, inits, waits, gestes manuels)
sont **comptés exactement** ; les **secondes** sont estimées et signalées comme
telles.

---

## Ce que la passe 1 a fermé

| # passe 1 | État | Preuve |
|---|---|---|
| #1 `vars.mk` pins morts | ✅ fermé | `vars.mk` = `OUT_DIR` seul |
| #3 garage hors registre | ✅ fermé | `Makefile:238` lit `garage_chart_version` du ConfigMap |
| #4 `cilium_version` mort | ✅ fermé | supprimé de `contexts/_defaults.yaml:15-16` |
| #5 cadavre `management-eso/` | ✅ fermé | répertoire supprimé |
| #6 VMRule count-gate | ✅ fermé | `clusters/management/monitoring-vm.yaml:44-55` (split deux-phases) |
| #2 bump Talos = 2 éditions | ⚠️ **maquillé, pas fermé** | les deux pins ont été *alignés* sur v1.12.9 (`contexts/_defaults.yaml:13`, `envs/scaleway/image/variables.tf:22`) mais `SCW_IMAGE_VARS` (`Makefile:613-617`) ne passe toujours pas `talos_version`. Aligner n'est pas dériver : le prochain bump peut redésynchroniser en silence (image v1.12.9 / machine config v1.12.10). |

---

## Verdict

| Artefact | Stabilité | Légalité | Économie | Déplacement | Pire inversion |
|---|---|---|---|---|---|
| Makefile `k8s-up` | 8 | 6 | 5 | 5 | 3 phases identity + 3 phases security qui **ne gardent rien** dans le graphe tofu |
| `stacks/security` (cosign) | 6 | **2** | 5 | 4 | `verify-images.yaml` : doublon divergent de la ClusterPolicy Flux, avec le champ `key:` que l'autre copie documente comme rejeté par le CRD |
| `stacks/identity` | 8 | 7 | 5 | 4 | `data.terraform_remote_state.pki` **jamais lu** mais rend `pki_state_password` obligatoire |
| `.woodpecker.yml` (deploy) | 7 | **3** | 6 | 3 | 2ᵉ encodage de l'ordre, déjà divergent : `deploy-identity`/`deploy-storage` échouent sur une variable requise absente |
| registry-mirror (stack + patch) | 4 | **2** | 5 | 5 | le disque le plus bas de la tour (machine config Talos) dépend d'un stack qu'aucune cible n'applique |
| Registre de versions | 8 | — | 8 | 9 | talos aligné à la main entre 2 fichiers (cf. #2 ci-dessus) |
| `stacks/pki` | 8 | 5 | 4 | 3 | inchangé — arbitré au roadmap F-bis-2, non re-litigé ici |

**Lecture d'ensemble.** La passe 1 avait laissé 5 NEEDS-REVIEW en supposant qu'ils
encodaient des contraintes réelles. Ils n'en encodent aucune : **quatre des cinq
sont des fossiles** — la migration ADR-028/ESO a retiré la *cause*, personne n'a
retiré la *compensation*. Le wait CNPG garde un secret que plus aucune ressource
tofu ne lit ; le pré-apply du namespace storage servait local-path-provisioner,
parti dans le stack cni depuis le Fix #4 ; le commentaire qui le justifie
aujourd'hui (`Makefile:429`) est factuellement faux. Ce ne sont pas des réordonnancements
à arbitrer, ce sont des **suppressions**.

Le cinquième (registry-mirror) est l'inverse : un prérequis qui n'est jamais joué.
Et une nouvelle inversion, de la même famille que la VMRule corrigée ce matin,
est encore en place dans `stacks/security` — avec, cette fois, un piège armé.

---

## Inversions (classées par fréquence × coût de redo)

| # | Artefact | Étape mal placée | Loi | Rayon d'impact aujourd'hui | Après | Tier / Conf. |
|---|---|---|---|---|---|---|
| 1 | `stacks/security/verify-images.yaml` + `main.tf:228-257` | ClusterPolicy `verify-image-signatures` déclarée **deux fois** : copie Flux (`flux-kyverno-policies/cosign-policy.yaml`, schéma correct) **et** copie tofu count-gatée (schéma **invalide** : champ `key: cosign.pub` que le commentaire de l'autre copie documente comme rejeté par le CRD v1.17) | 2+3 | Cluster fresh : count=0 → policy tofu jamais créée (la copie Flux, elle, arrive). Le commentaire `main.tf:234-236` **prescrit** de rejouer `k8s-security-apply` → sur cluster chaud le CRD existe, count=1, tofu applique le YAML invalide → **apply en échec** ou écrasement de la policy valide. La procédure de rattrapage documentée déclenche la panne. | supprimer la ressource tofu + le fichier ; Flux possède déjà la policy correcte via la Kustomization phase-2 `security-kyverno-policies` (`clusters/management/security-kyverno.yaml:60-73`) | T3 / HIGH |
| 2 | `Makefile:198-207` (identity), `219-227` (security) | 3 phases (`apply -target` → `kubectl wait --for=create secret` → apply complet) pour attendre un secret CNPG que **plus aucune ressource tofu ne lit** | 2+3+4 | identity : `main.tf` ne contient aucun `data "kubernetes_secret"` ; le seul consommateur d'`identity-pg-app` est le PushSecret de `flux/external-secrets-kratos.yaml:45`, **Flux-owned, jamais appliqué par tofu**. Le wait ne garde rien. security : le PushSecret est tofu-appliqué mais son propre commentaire (`main.tf:220-223`) pose le retry ESO comme mécanisme. Coût : +2 applies, +2 waits bloquants par déploiement fresh ; `tofu apply` nu illégal hors make | 1 apply par stack, 0 wait | T2 / HIGH |
| 3 | `Makefile:428-434` (`k8s-up`) | `k8s-storage-init` + `apply -target=kubernetes_namespace.storage` **avant pki** — fossile du Fix #4 | 2+3 | Origine réelle (git `cc66be0`) : déployer local-path-provisioner avant pki. Il vit dans le stack **cni** depuis le Fix #4 — le Makefile l'admet ligne 431-433 mais garde le `-target` et lui invente une justification **fausse** (l.429 « cnpg-s3 secret target ns ») : `cnpg-s3-credentials` est écrit par **storage** dans le namespace **identity** (`stacks/storage/main.tf:256,265`), et pki seede garage/harbor dans **OpenBao** (`pki/secrets.tf:211-218`), rien dans `ns/storage`. Coût : 1 init + 1 apply inutiles, et `garage-chart` (curl+untar) **fetché 2×** par `k8s-up` (l.428 puis l.439 via `k8s-storage-init`) | supprimer les 3 lignes | T2 / HIGH |
| 4 | `.woodpecker.yml:225-239` | L'ancre `deploy_stack` fait un `tofu apply` **nu** (ni `-target`, ni wait, ni `pki_state_password`) : 2ᵉ encodage de l'ordre du pipeline, déjà divergent du Makefile | 4 | `pki_state_password` est **requis sans défaut** (`identity/variables.tf:21`, `storage/variables.tf:19`) → `deploy-identity` et `deploy-storage` échouent sur `push: main` (« No value for required variable »). Le pipeline de deploy CI n'a donc jamais pu passer au vert sur ces 2 étapes | après #2+#5, la recette Makefile **devient** un apply nu → un seul ordre, encodé une fois ; +1 `-var` dans l'ancre CI pour storage | T3 / HIGH |
| 5 | `stacks/identity/main.tf:30-46` | `data.terraform_remote_state.pki` + `locals.secrets` : **zéro référence** dans tout le stack (les 4 secrets passent par OpenBao/ESO depuis ADR-028, cf. commentaire `main.tf:195-198`) | 1+3 | Une lecture d'état morte rend `pki_state_password` obligatoire → force `K8S_PKI_REMOTE_STATE_VARS` dans le Makefile, interdit le `tofu apply` nu, et casse `deploy-identity` en CI (#4). Couplage inter-stacks fantôme | -18 lignes, -1 couplage, `tofu apply` nu redevient légal | T2 / HIGH |
| 6 | `patches/registry-mirror-scr.yaml` + `envs/scaleway/main.tf:133` | Le patch machine config Talos — **le disque le plus bas de la tour**, scellé à la création des nœuds — redirige 6 registries vers `rg.fr-par.scw.cloud/st4ck-mirror`, un namespace SCR que **`stacks/registry-mirror/` crée et qu'aucune cible make, aucune entrée `STACKS`, aucune étape CI n'applique** | 2 | Prérequis jamais joué : chaque pull des 6 registries tente d'abord un miroir que le pipeline ne garantit pas (fallback Talos vers l'upstream : les pulls aboutissent, au prix d'un aller-retour perdu). Région **codée en dur** alors que les contextes sont region-scoped — tous les contextes actuels sont `fr-par`, le premier `nl-ams` arme la bombe. Et le bénéfice a déjà été **mesuré marginal** : `docs/roadmap.md:533-539` corrige l'hypothèse (pulls PKI = 30-60 s, pas 10 min) | **supprimer** le patch du `common_config_patches` + le stack + `scripts/mirror-images-to-scr.sh` ; ADR-034 (hauler `serve registry`) porte déjà la suite | T2 / MEDIUM |
| 7 | `Makefile:308-314, 927` | `oidc-register` toujours non chaîné à `scaleway-up` | 3 | 1 geste manuel oubliable par déploiement fresh → login OIDC K8s cassé, découvert plus tard | fix à la source = **Hydra Maester** (CRD `OAuth2Client`), déjà nommé « Phase F-bis-3 » dans `identity/main.tf:250-252` : la registration devient un CR que Flux réconcilie, zéro post-étape impérative. Intérim : chaîner, gaté sur la Kustomization Flux (voir *Points à vérifier*) | T2 / MEDIUM |
| 8 | `Makefile:1195-1200` (`STACKS`) | Liste **inversée** : `stacks/external-secrets` (0 fichier `.tf` — ESO est tofu-owned dans pki depuis ADR-033) **est** dans STACKS ; `stacks/registry-mirror` (4 fichiers `.tf`) **n'y est pas** | 3 | `make validate` valide un répertoire vide et ignore le seul stack non couvert. `.woodpecker.yml:14-15` a déjà corrigé sa liste de son côté — 3ᵉ divergence Makefile/CI | aligner sur la liste CI ; trancher registry-mirror avec #6 | T1 / HIGH |

Tier 1, en passant : `scripts/mirror-images.txt:46-49` épingle encore les images
kube-* en `v1.35.0` alors que le cluster déploie `1.35.6`. Inoffensif — le
générateur hauler retague depuis `k8s_version` avec un `warn` (`hauler-manifest-gen.py:87-89`).
Le rayon d'impact est nul, seule la ligne de warning est bruyante : mettre les 4
pins à jour ou laisser. **Ne pas** transformer ça en chantier.

---

## Piles réordonnées

### 1. `k8s-up` — supprimer, ne pas réordonner

```
Avant (10 applies, 8 inits, 2 waits, 1 geste)   Après (7 applies, 7 inits, 0 wait, 0 geste)
────────────────────────────────────────────    ──────────────────────────────────────────
cni                                             cni
storage-init  (garage-chart #1)  ✗ #3           pki
storage apply -target=ns.storage ✗ #3           monitoring
pki                                             identity        (1 apply — le wait ne gardait rien)
monitoring                                      security        (1 apply — idem)
identity  apply -target                ✗ #2     storage         (garage-chart, 1 seule fois)
identity  kubectl wait 180s            ✗ #2     flux-bootstrap
identity  apply                                 oidc-register   (chaîné — cf. Points à vérifier)
security  apply -target                ✗ #2
security  kubectl wait 180s            ✗ #2
security  apply
storage   (garage-chart #2)      ✗ #3
flux-bootstrap
[manuel]  oidc-register                ✗ #7
```

Patch sketch :

```make
# k8s-up : supprimer les lignes 428-434 (init + apply -target=ns.storage)
# k8s-identity-apply :
k8s-identity-apply: k8s-identity-init ## Deploy CNPG + certs (Kratos/Hydra/Pomerium = Flux, ADR-028)
	$(TF) -chdir=$(TF_IDENTITY) apply -auto-approve $(K8S_COMMON_VARS)
#   ^ K8S_PKI_REMOTE_STATE_VARS disparaît aussi, une fois #5 appliqué
# k8s-security-apply : idem, une seule ligne d'apply
```

**Invariant à préserver** (vérifié) : `-target=kubectl_manifest.identity_pg_cluster`
tirait `identity_pg_certs` avec lui (dépendance `main.tf:167-171`), ce qui garantit
l'ordre « Certificates avant Cluster CR » exigé par le commentaire `main.tf:86-93`.
L'apply complet le garantit tout autant — `depends_on` est dans le graphe, pas dans
le `-target`. Aucune régression.

### 2. `stacks/security` — la policy a déjà déménagé, la vieille copie est restée

```
Avant                                         Après
─────                                         ─────
Flux  security-kyverno (HR)                   Flux  security-kyverno (HR)
  └─ security-kyverno-policies                  └─ security-kyverno-policies
       ├─ cosign-policy.yaml        ✓ valide        ├─ cosign-policy.yaml       ✓ seul propriétaire
       └─ external-secret-cosign.yaml                └─ external-secret-cosign.yaml
tofu  kubectl_manifest.cosign_verify_policy    (supprimé)
      count = CRD kyverno existe ?  ✗
      → verify-images.yaml          ✗ schéma invalide (`key:`)
```

Patch : supprimer `stacks/security/verify-images.yaml`,
`data.kubernetes_resources.kyverno_clusterpolicy_crd` et
`resource.kubectl_manifest.cosign_verify_policy` (`main.tf:228-257`). La
Kustomization phase-2 existe déjà et porte la version correcte de la même
ClusterPolicy. −30 lignes de HCL, −1 count-gate, −1 double propriétaire, −1 piège.

> **La convention du repo est saine, elle a juste été violée ici.** Le pattern
> « seed-then-share » (tofu day-1 + Flux day-2 sur **le même fichier**) est
> légitime et documenté — `cosign_externalsecrets` (`main.tf:189-205`) l'applique
> correctement en pointant sur `flux-kyverno-policies/external-secret-cosign.yaml`.
> Il n'est sûr *que* parce que c'est le même fichier. `verify-images.yaml` est une
> **copie**, et les deux copies ont divergé. C'est exactement le mode de panne que
> la convention prévient.

---

## Responsabilités déplacées (Loi 4)

| Capacité manquante | Couche naturelle | Compensations trouvées | Fix à la source |
|---|---|---|---|
| « Secret CNPG matérialisé » exposé au graphe TF | — **la capacité n'est plus requise** | `Makefile:205`, `Makefile:225` (2 `kubectl wait`) | **rien à déplacer : supprimer.** Le besoin a disparu avec la migration DSN → ESO (`identity/main.tf:195-198`). La compensation a survécu à sa cause |
| Ordre de déploiement des stacks | le graphe tofu (`depends_on`, remote_state) | **2 orchestrateurs** : `Makefile:427-440` et `.woodpecker.yml:222-314`, déjà divergents (3 écarts : `-target` storage, 3-phases, liste STACKS) | après #2/#3/#5 les deux se réduisent à la même liste linéaire d'applies nus. Un ordre, encodé une fois |
| Miroir de registry disponible | stack d'infra appliqué avant les nœuds | patch Talos (`envs/scaleway/main.tf:133`) qui **suppose** le miroir ; stack `registry-mirror/` hors pipeline ; `scripts/mirror-images-to-scr.sh` hors pipeline ; `scripts/mirror-images.txt` (83 l.) doublonnant `hauler-manifest.yaml` (168 l., généré) | ADR-034 : hauler devient le magasin unique. Supprimer la branche SCR (#6) plutôt que de la câbler — la mesure (`roadmap.md:533-539`) dit que le gain n'est pas là |
| Registration client OIDC | Hydra (CRD `OAuth2Client` / Maester) | `scripts/register-hydra-oidc-client.sh` + `make oidc-register` + un geste humain | Hydra Maester (Phase F-bis-3, déjà identifié) |
| « OpenBao prêt » comme gate réutilisable | 1 helper partagé | 7 sites, 4 couches (inchangé depuis la passe 1) | `scripts/wait-openbao.sh` — recommandation passe 1, toujours valable, non re-argumentée ici |

Ce qui n'est **pas** du déplacement (vérifié, à ne pas « corriger ») : le split
deux-phases Flux (c'est la *déclaration* d'un ordre, pas un retry) ; le retry ESO
sur `refreshInterval` (c'est le contrôleur qui fait son travail — c'est justement
pourquoi le `kubectl wait` au-dessus est redondant) ; les boucles d'attente pki
(arbitrées au roadmap) ; le gate vault-backend de `k8s-up:426`.

---

## Travail refait économisé

**Coups comptés exactement** sur un déploiement fresh (`make scaleway-up`, portion `k8s-up`) :

| Coup | Aujourd'hui | Après | Δ |
|---|---|---|---|
| `tofu apply` | 10 | 7 | **−3** |
| `tofu init` | 8 | 7 | −1 |
| `garage-chart` (curl + untar) | 2 | 1 | −1 |
| `kubectl wait` bloquants (Makefile) | 2 | 0 | **−2** |
| Gestes manuels après retour de la cible | 1 | 0 | **−1** |
| ClusterPolicy cosign présente day-1 | ❌ (count=0) | ✅ (Flux) | +1 coup **manquant** joué |
| 2ᵉ `make k8s-security-apply` sur cluster chaud | ❌ échoue (`key:` invalide) | ✅ | piège désarmé |
| `tofu apply` nu dans `stacks/identity` | ❌ variable requise absente | ✅ | boucle de dev débloquée |
| Étapes CI `deploy-identity` / `deploy-storage` | ❌ échouent | ✅ | pipeline deploy réparé |

**Wall-clock : estimé −3 à −5 min** par déploiement fresh. Base de l'estimation
(à valider par une mesure) : 2 applies ciblés (~20-40 s chacun, init déjà chaud)
+ 2 waits CNPG (~60 s chacun à froid) + 1 init/apply storage (~30-60 s) + 1 fetch
de chart (~5-15 s). **Aucune mesure runtime n'a été prise** — c'est une estimation,
pas un résultat.

**Boucle de dev** (`make k8s-identity-apply` sur cluster chaud) : 2 applies → 1.
Le `kubectl wait` y coûte ~0 s (le secret existe déjà) mais le plan ciblé
supplémentaire, lui, se paie à chaque itération : ~−30 s par itération.

**Ce qui n'est PAS économisé, et qu'il ne faut pas aller chercher là :** les
~10 min du stack pki. La mesure du 2026-04-30 (`roadmap.md:533-543`) est sans
ambiguïté — les pulls d'images font 30-60 s, le reste est du `sleep 5 × 90` dans
les boucles de scale 1→3 (`pki/main.tf:235-366`, `409-520`). Ni le miroir de
registry (Phase E) ni les corrections ci-dessus n'y toucheront. Le gain est dans
F-bis-2 (`replicas: 3` + `retry_join` natif Helm), et le sous-gain le moins cher,
indépendant de la migration HA, est `sleep 5` → `sleep 1` + early exit (~70 % du
temps de boucle, d'après le roadmap lui-même). **Arbitré, non re-litigé ici.**

---

## Optimization cards

### Card HANOI-P2-001 — Supprimer la ClusterPolicy cosign tofu (doublon divergent)

**Location** : `stacks/security/main.tf:228-257`, `stacks/security/verify-images.yaml`
**Observed structure** : la même ClusterPolicy `verify-image-signatures` est
déclarée par Flux (`flux-kyverno-policies/cosign-policy.yaml`, schéma valide) et par
tofu (count-gatée sur le CRD Kyverno, schéma **invalide** — champ `key:` que le CRD
v1.17 rejette, comme documenté dans la copie Flux elle-même).
**Operational issue** : sur cluster fresh la copie tofu n'est jamais créée
(count=0) ; sur cluster chaud, le rattrapage prescrit par le commentaire
(`main.tf:234-236`) applique le YAML invalide → apply en échec, ou écrasement de
la policy valide de Flux. Double propriétaire = le bug de classe ADR-028.
**Candidate rewrite** : supprimer la ressource tofu, le data source et le fichier.
**Required invariants** : la Kustomization `security-kyverno-policies` porte bien
`cosign-policy.yaml` (vérifié : `flux-kyverno-policies/kustomization.yaml:13`) ; si
la ressource tofu figure dans un state existant, `tofu state rm` avant suppression
du code, sinon l'apply suivant *détruit* la policy que Flux vient de poser.
**Validation** : `kubectl get clusterpolicy verify-image-signatures -o yaml` →
un seul objet, sans champ `key:`, `managedFields` = Flux. Puis rejouer
`make k8s-security-apply` : doit passer au vert (il échoue aujourd'hui).
**Expected impact** : correctness high. **Risk** : low (mais le `state rm` est
obligatoire). **Confidence** : 0.9. **Next owner** : patch direct.

### Card HANOI-P2-002 — Retirer la branche SCR mirror

**Location** : `envs/scaleway/main.tf:88,133`, `patches/registry-mirror-scr.yaml`,
`stacks/registry-mirror/`, `scripts/mirror-images-to-scr.sh`
**Observed structure** : le patch machine config (disque le plus bas : scellé à la
création des nœuds) redirige 6 registries vers un namespace SCR qu'aucune étape du
pipeline ne crée, avec la région codée en dur.
**Operational issue** : prérequis jamais joué ; dépendance invisible sur une
ressource hors-pipeline ; se déclenchera silencieusement au premier contexte
non-`fr-par`. Bénéfice déjà mesuré marginal (`roadmap.md:533-539`).
**Candidate rewrite** : retirer `registry_mirror_scr_patch` de
`common_config_patches`, supprimer le stack, le patch et le script de mirroring.
Garder `patches/registry-mirror.yaml` (fallback mirror.gcr.io — aucune dépendance
d'infra) et `scripts/mirror-images.txt` (**entrée vivante** du générateur hauler,
`hauler-manifest-gen.py:32`). ADR-034 phase 2 (hauler `serve registry` sur la VM CI)
reprendra le sujet avec un endpoint qui, lui, sera dans le pipeline.
**Required invariants** : le changement de `common_config_patches` **modifie la
machine config** → nœuds existants à repatcher ou à recréer ; à faire sur un
déploiement fresh, pas en place sur un cluster vivant.
**Validation** : `talosctl get mc -o yaml | grep -A3 mirrors` sur un nœud fraîchement
créé → plus d'endpoint `rg.*.scw.cloud`. Pulls toujours verts.
**Expected impact** : simplification (−1 stack, −1 patch, −1 script) ; latence de
pull marginalement meilleure (plus d'aller-retour perdu). **Risk** : medium (touche
la machine config). **Status** : needs_invariant. **Confidence** : 0.7.
**Next owner** : décision — supprimer (recommandé, cohérent avec ADR-034) ou câbler
(STACKS + cible make + host dérivé de la région).

---

## Points à vérifier

- **PushSecret OpenClarity sans son secret source** (inversion #2, moitié security) :
  le commentaire `security/main.tf:220-223` affirme que l'ExternalSecret retente sur
  son `refreshInterval` (30 s pendant la fenêtre de bootstrap). C'est l'hypothèse qui
  rend le `kubectl wait` superflu. Côté identity la preuve est complète (aucun
  consommateur tofu du secret) ; côté security elle repose sur ce comportement ESO.
  **À observer sur un déploiement fresh** : `kubectl get pushsecret -n security` doit
  converger seul après suppression du wait. Si ESO passait en erreur permanente au
  lieu de retenter, le wait devrait redescendre **dans le stack** (`terraform_data`),
  pas remonter dans le Makefile.
- **`oidc-register` chaîné** (#7) : le `kubectl wait` interne borne à 300 s mais
  démarre après `flux-bootstrap-apply`, qui rend la main dès la Kustomization posée —
  pas quand Flux a fini de réconcilier la chaîne `kratos → hydra`. Le budget de 300 s
  n'a jamais été mesuré contre ce délai. **Mesurer avant de chaîner** ; si c'est
  juste, attendre d'abord la Kustomization (`kubectl wait --for=condition=Ready
  kustomization/management -n flux-system`) plutôt que d'allonger le timeout du pod.
- **`tofu state rm` avant suppression de `cosign_verify_policy`** : sur tout cluster
  où la ressource a été créée (count=1), supprimer le code sans `state rm` fait
  **détruire** la ClusterPolicy par le prochain apply — y compris celle de Flux, même
  nom d'objet.
- **Le namespace SCR `st4ck-mirror` existe-t-il réellement ?** (#6) Appliqué hors
  pipeline via le README ? Invérifiable depuis le repo. La recommandation ne change
  pas (la mesure dit que le gain n'est pas là), mais le calcul coût/bénéfice, si.
- **Fréquences toujours estimées** : historique git plat, aucune mesure runtime. Les
  coups sont comptés, les secondes sont estimées.

---

## Priorités (gain ÷ effort)

1. **Doublon cosign (#1)** — suppression pure, désamorce un piège *armé* (le
   rattrapage documenté casse l'apply). Le seul Tier 3 correctness. `state rm` d'abord.
2. **Waits CNPG fossiles (#2)** — supprimer 2 phases × 2 stacks. −2 applies, −2 waits,
   `tofu apply` nu redevient légal.
3. **Pré-apply storage (#3)** + **remote_state mort identity (#5)** — suppressions
   pures, ~20 lignes. Débloquent mécaniquement (#4) : les recettes Makefile deviennent
   des applies nus, donc identiques à ce que fait la CI.
4. **CI (#4)** — ajouter `-var="pki_state_password=$$TF_HTTP_PASSWORD"` à l'ancre
   `deploy_stack` (storage en a un vrai besoin). Le pipeline de deploy repasse au vert.
5. **STACKS (#8)** — aligner sur la liste CI. Une ligne.
6. **registry-mirror (#6, Card P2-002)** — décision à prendre : supprimer (recommandé)
   ou câbler. Touche la machine config → à faire sur un fresh, pas en place.
7. **oidc-register (#7)** — mesurer d'abord, chaîner ensuite. Fix à la source
   (Hydra Maester) déjà au plan.
8. **pki (~10 min)** — **ne rien décider ici.** Arbitré au roadmap F-bis-2, et la
   mesure exclut explicitement les pulls d'images comme cause.
