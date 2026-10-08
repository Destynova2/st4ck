# Audit Code — karpenter-provider-scaleway

**Cible** : `karpenter-provider-scaleway/` (3 commits branche `feat/karpenter-provider-scaleway` : d1a9a37, aac4121, 0c234e4)
**Langage** : Go 1.26.5 | **Type** : contrôleur Kubernetes (provider Karpenter, spike M0) | **Date** : 2026-07-12
**Langue du rapport** : français (README du sous-projet en français + demande en français ; les passes cli-cycle précédentes étaient en anglais — signaler si vous préférez uniformiser)
**CQI Score** : **8.0/10 — Excellent** (borne haute du "Good", niveau production-ready pour la portée M0)
**Dette technique** : ~6,5 h (13 findings × 0,5 h, 0 critique) — **SQALE A** (ratio 0,7 %)

## Périmètre et méthode

- 17 fichiers Go, 1 930 lignes au total ; 1 824 hors `zz_generated.deepcopy.go` (généré, exclu), dont 642 lignes de tests (~35 %). Code de production : ~1 182 lignes.
- **Lecture intégrale de tous les fichiers** : justifiée car le plus gros fichier fait 421 lignes et l'audit exige la sémantique complète (contrat CloudProvider, invariants de concurrence).
- Vérifications outillées : `gofmt -l` propre, `go vet ./...` propre, `go build ./...` propre, `go test ./...` → **26 tests verts, 5 packages, zéro réseau** (la revendication "26 tests" du README/M0-REPORT est exacte).
- Deux findings dépendant de bibliothèques ont été **vérifiés dans le cache de modules** (pas de supposition de mémoire) : dépréciation de `reconcile.Result.Requeue` dans controller-runtime v0.23.1, et unwrapping des erreurs wrappées par `apierrors.IsNotFound` (via `errors.As`) dans apimachinery v0.35.1.

## Scores par catégorie

| # | Catégorie | Poids | Score | Pondéré | Findings |
|---|-----------|-------|-------|---------|----------|
| C1 | Naming & lisibilité | 8 % | 0.90 | 0.072 | Noms métier (`pool`, `Inventory`, `claimStoppedServer`), constantes nommées avec rationale ; abréviation `it` mineure |
| C2 | Fonctions & complexité cognitive | 12 % | 0.85 | 0.102 | Max 34 lignes (`toNodeClaim`), complexité cognitive max ~9 (< 15 partout) ; `toNodeClaim` à 5 paramètres |
| C3 | Design de modules (deep vs shallow) | 10 % | 0.90 | 0.090 | `pool.Backend` = module profond exemplaire ; aucun fichier fourre-tout ; tailles 24-351 lignes |
| C4 | DRY & amplification de changement | 8 % | 0.70 | 0.056 | Duplication Delete/Get (F5), résolveurs jumeaux (F6) |
| C5 | Gestion d'erreurs & robustesse | 10 % | 0.75 | 0.075 | Sentinelles + erreurs typées karpenter exemplaires ; erreur avalée (F2), panic dans main (F9), arch codée en dur (F7) |
| C6 | Type safety & idiomes du langage | 8 % | 0.70 | 0.056 | Go idiomatique (`strings.Cut`, `slices`, checks `var _ Interface`) ; `Requeue` déprécié (F3), sentinelle nil (F1), paramètre inutilisé (F2) |
| C7 | Commentaires & doc API publique | 5 % | 0.80 | 0.040 | Commentaires d'intention remarquables (références LLD) ; un commentaire mensonger (F2), quelques exports non documentés |
| C8 | Qualité des tests | 12 % | 0.80 | 0.096 | 26 tests, chemins d'erreur couverts, fake avec injection d'erreurs et compteurs ; divergence fake/réel (F1), chemin dégradé de List non testé |
| C9 | Sécurité & validation des entrées | 10 % | 0.80 | 0.080 | Credentials env-only, zéro secret en dur, messages d'erreur propres ; validation CRD minimale (F11), conversion int32 (F10) |
| C10 | Immutabilité & gestion d'état | 7 % | 0.70 | 0.049 | Mutex corrects, caches TTL bornés ; map `claimed` non purgée (F4), slice de cache partagée (F8) |
| C11 | Charge cognitive & flux de contrôle | 5 % | 0.80 | 0.040 | Early returns, nesting ≤ 3 ; sémantique nil-vs-vide implicite (F1), bypass de cache non commenté (F12) |
| C12 | Dépendances & architecture | 5 % | 0.90 | 0.045 | DAG propre (cloudprovider→pool/apis, controllers→pool/apis), DIP respecté via `Backend`, zéro cycle |
| | **CQI** | **100 %** | | **8.0/10** | |

## Anti-patterns détectés

| Pattern | Sévérité | Fichier:ligne | Recommandation |
|---------|----------|---------------|----------------|
| Duplicated Code (Fowler) | Minor | `pkg/cloudprovider/cloudprovider.go:104-130` vs `134-154` | Extraire `liveServerFromProviderID()` (voir F5) |
| Lying Comment (Martin) | Major | `pkg/cloudprovider/cloudprovider.go:269-270` | Aligner doc et code (voir F2) |
| Nil-as-Sentinel (idiome Go fragile) | Major | `pkg/cloudprovider/instancetype.go:31-34` | Paramètre explicite au lieu de `servers != nil` (voir F1) |
| Long Parameter List (léger) | Minor | `pkg/cloudprovider/cloudprovider.go:318` | `toNodeClaim` à 5 paramètres — regrouper labels/annotations si ça grossit |

Aucun God Class, aucun module fourre-tout (`utils`/`helpers`), aucun weasel-word naming, aucun code mort, aucun code commenté.

## Violations critiques (à corriger)

**Aucune.** Zéro finding de niveau Blocker/Critical (Tier 3) : pas de secret en dur, pas d'erreur avalée sur un chemin critique, pas de bug de logique majeur détecté, pas de data race active.

## Flags (à corriger — Tier 2, triés par effort croissant)

### C6 : `reconcile.Result{Requeue: true}` utilise un champ déprécié — F3
- **Fichier** : `karpenter-provider-scaleway/pkg/controllers/nodeclass/controller.go:53`
- **Tier** : 2 | **Confiance** : HIGH (vérifié dans le source de controller-runtime v0.23.1 : « Deprecated: Use `RequeueAfter` instead. »)
- **Quoi** : sur conflit de patch optimiste, le contrôleur retourne `reconcile.Result{Requeue: true}, nil`.
- **Pourquoi** : champ officiellement déprécié depuis controller-runtime v0.22 ; disparaîtra à une montée de version et sème la confusion (requeue ratelimité conçu pour les erreurs, pas pour du polling).
- **Fix** : retourner l'erreur de conflit telle quelle (le workqueue fait le retry ratelimité) ou `reconcile.Result{RequeueAfter: time.Second}`.
- **Disproof** : ce n'est pas un problème SI le projet reste figé sur controller-runtime ≤ v0.23 — mais le champ est déjà marqué déprécié dans la version utilisée.

### C5/C7 : `invalidateInventoryFor` — paramètre inutilisé, commentaire mensonger, erreur avalée — F2
- **Fichier** : `karpenter-provider-scaleway/pkg/cloudprovider/cloudprovider.go:269-282`
- **Tier** : 2 | **Confiance** : HIGH (lecture directe ; `go vet` ne détecte pas les paramètres de fonction inutilisés)
- **Quoi** : trois défauts dans la même fonction :
  1. le paramètre `server pool.Server` n'est **jamais utilisé** dans le corps ;
  2. le doc comment promet « drops the cached snapshot of every pool the server **belongs to** » alors que le code invalide **tous les pools de la zone** (`nc.Spec.Zone == zone`, sans confronter `server.Tags` à `nc.Spec.PoolTag`) ;
  3. l'échec de `kubeClient.List` est avalé (`return` nu, ligne 273-275) sans même un log debug.
- **Pourquoi** : Lying Comment (Martin) — le prochain lecteur croira l'invalidation ciblée par pool ; l'erreur avalée laisse `Offering.Available` périmé jusqu'à expiration du TTL (10 s) sans trace observable. Impact fonctionnel borné (sur-invalidation = appels API en plus ; staleness ≤ TTL) mais la doc contredit le code.
- **Fix** : soit filtrer réellement par `slices.Contains(server.Tags, nc.Spec.PoolTag)` (et le paramètre devient utile), soit supprimer le paramètre et corriger le commentaire (« every pool in the zone ») ; logger l'échec de List en niveau debug.
- **Disproof** : le comportement actuel n'est pas un bug runtime SI la sur-invalidation est un choix délibéré — mais alors le commentaire et la signature doivent le dire.

### C5/C9 : architecture `amd64` codée en dur pour toutes les offres — F7
- **Fichier** : `karpenter-provider-scaleway/pkg/cloudprovider/instancetype.go:48`
- **Tier** : 2 | **Confiance** : MEDIUM (dépend du catalogue Scaleway ; des offres EM non-x86 existent, ex. EM-RV1 RISC-V)
- **Quoi** : `scheduling.NewRequirement(corev1.LabelArchStable, ..., karpv1.ArchitectureAmd64)` — chaque instance type annonce amd64 quel que soit `offerName`.
- **Pourquoi** : un pool déclaré sur une offre non-x86 publierait une arch fausse au scheduler → placements erronés silencieux. L'hypothèse « pool pré-imagé Talos amd64 » n'est écrite nulle part (ni CRD, ni README, ni commentaire).
- **Fix M0** : documenter l'hypothèse (commentaire + README) ; **fix M1** : résoudre l'arch depuis l'offre (`baremetal.Offer.CPUs`) ou la valider dans le contrôleur nodeclass (condition `False`/`UnsupportedArch`).
- **Disproof** : non-problème SI le catalogue d'offres utilisables par st4ck est garanti 100 % amd64 ET que cette garantie est documentée — la seconde moitié manque aujourd'hui.

### C6/C8 : divergence fake/réel sur pool vide — sentinelle `nil` de `buildInstanceType` — F1
- **Fichiers** : `karpenter-provider-scaleway/pkg/pool/fake.go:85` (`var out []Server` → `nil` si vide), `pkg/pool/scaleway.go:55` (`make([]Server, 0, ...)` → slice vide non-nil), `pkg/cloudprovider/instancetype.go:31-34` (sentinelle `if servers != nil`)
- **Tier** : 2 | **Confiance** : HIGH (confirmé par lecture croisée des deux implémentations + analyse du chemin `GetInstanceTypes`)
- **Quoi** : `buildInstanceType` utilise `servers == nil` comme sentinelle « ne pas calculer la disponibilité » (chemin Create). Or sur un **pool vide**, le backend réel retourne une slice vide non-nil (→ `Available=false`, correct) tandis que le `FakeBackend` retourne `nil` (→ `Available=true`, faux). Les deux implémentations de `Backend` ne respectent pas le même contrat sur le cas vide.
- **Pourquoi** : c'est exactement le genre de divergence qui fait mentir la suite de tests « sans réseau » : un test M1 sur `GetInstanceTypes` avec pool vide validerait un comportement que la prod n'a pas. La sentinelle nil-vs-vide est un footgun Go classique (invisible, non typée).
- **Fix** : remplacer la sentinelle par un paramètre explicite (`computeAvailability bool`) ou deux fonctions ; aligner `FakeBackend.ListServers` sur le réel (`out := make([]Server, 0)`), et documenter le contrat « jamais nil » dans `Backend.ListServers`.
- **Disproof** : sans impact observable SI aucun appelant ne passe jamais un snapshot de pool vide — faux : `GetInstanceTypes` → `Snapshot` → `buildInstanceType` le fait dès qu'un pool se vide (tag retiré, serveurs supprimés).

## Mineurs (Tier 1, triés par effort croissant)

1. **F9 — `main.go` : log + panic en double** (`cmd/controller/main.go:27-30`, confiance HIGH). `log.Error(...)` puis `panic(err)` produit le message deux fois plus une stack trace inutile au démarrage. Fix : `os.Exit(1)` après le log, ou panic seul.
2. **F10 — conversion `int32(len(servers))` non bornée** (`pkg/controllers/nodeclass/controller.go:71-72`, confiance HIGH, sévérité Info). Overflow théorique (gosec G115) ; pool fini de quelques serveurs → risque nul en pratique. À noter si golangci-lint (gosec) est activé un jour.
3. **F6 — résolveurs jumeaux, wrapping d'erreur incohérent** (`pkg/cloudprovider/cloudprovider.go:289-291` vs `300-302`, confiance MEDIUM). `resolveNodeClassFromNodeClaim` retourne l'erreur nue quand son jumeau wrappe avec contexte. Vérifié : `apierrors.IsNotFound` (apimachinery v0.35) unwrappe via `errors.As`, donc wrapper est sans danger pour le check de `Create()` (ligne 72). Uniformiser (wrapper les deux) et fusionner ce qui peut l'être.
4. **F5 — duplication Delete/Get** (`pkg/cloudprovider/cloudprovider.go:104-130` vs `134-154`, confiance HIGH). Parse providerID → `GetServer` → mapping `ErrServerNotFound`→`NodeClaimNotFoundError` → check `PoweredOn()` : ~15 lignes quasi identiques ×2. Règle de cristallisation (≥ 2 appels) : extraire `liveServerFromProviderID(ctx, providerID) (pool.Server, string, error)`.
5. **F12 — `List()` contourne le cache inventaire sans commentaire** (`pkg/cloudprovider/cloudprovider.go:167-172`, confiance MEDIUM). `claimStoppedServer` documente son « fresh list on purpose » (:237-238) ; `List()` fait pareil sans le dire. Avec N nodeclasses, chaque passe GC du core = N appels `ListServers` hors budget cache. Ajouter le commentaire d'intention (ou router via l'inventaire si le budget ≤ 1 req/10 s devient contraignant).
6. **F8 — `Inventory.Snapshot` retourne la slice interne du cache** (`pkg/pool/inventory.go:39-43`, confiance MEDIUM, risque latent). Tous les appelants dans le TTL partagent la même slice ; le jour où l'un la trie (comme `claimStoppedServer` trie sa liste fraîche, :243) c'est une data race. Actuellement lecture seule partout — retourner `slices.Clone(e.servers)` ou documenter le contrat lecture-seule.
7. **F4 — map `claimed` jamais purgée des serveurs disparus** (`pkg/cloudprovider/cloudprovider.go:248-257`, confiance MEDIUM). Les entrées ne sont supprimées que si le serveur réapparaît non-stopped dans une liste ultérieure ou via `unclaim`. Un serveur claimé puis retiré du pool (tag enlevé, serveur détruit) laisse une entrée à vie. Fuite bornée par la taille du pool (négligeable) mais gratuite à corriger : purger dans la même passe verrouillée les IDs absents de la liste.
8. **F11 — validation CRD minimale** (`pkg/apis/v1alpha1/scalewayemnodeclass.go:11-25`, confiance MEDIUM). `zone`/`poolTag`/`offerName` seulement `MinLength=1` : une zone malformée ne se voit qu'en runtime via la condition `APIError`. Parse-don't-validate à la frontière : `+kubebuilder:validation:Pattern=^[a-z]+-[a-z]+-\d+$` sur `zone` rejetterait la faute à l'admission.
9. **F13 — `FakeBackend.GetOfferByName` ignore la zone** (`pkg/pool/fake.go:160`, confiance MEDIUM). Offres indexées par nom seul : un test multi-zones avec le même nom d'offre ne détecterait pas un bug de zone. Indexer par `zone+"/"+name` comme le backend réel (`scaleway.go:101`).

Trous de tests notables (rattachés à C8, pas de finding séparé) : le chemin dégradé de `List()` (`itErr != nil` → NodeClaim minimal, `cloudprovider.go:183-188`) n'est exercé par aucun test (aucun test ne combine `OfferErr` + serveurs allumés) ; l'invalidation d'inventaire déclenchée par `Delete` n'est pas assertée.

## Bonnes pratiques relevées

- **`pool.Backend` est un module profond exemplaire** (Ousterhout) : 5 méthodes cachent tout le SDK Scaleway ; deux implémentations (réelle + fake) avec vérifications d'interface à la compilation (`var _ Backend = ...`, `backend.go:33`, `fake.go:34`, `cloudprovider.go:53`).
- **Commentaires d'intention de très haut niveau** : chaque décision non évidente est justifiée avec référence au design — garde anti-course `claimTTL` (`cloudprovider.go:37-41`), « fresh list on purpose » (:237-238), chemin List dégradé « must not hide live capacity from the GC » (:184-186), prix flat neutralisant la consolidation (`instancetype.go:59-60`), budget TTL (`main.go:18-20`). C'est le contre-exemple parfait du commentaire redondant.
- **Contrat d'erreurs karpenter-core respecté à la lettre** : sentinelles (`ErrServerNotFound`, `ErrOfferNotFound`) mappées vers les erreurs typées attendues (`NewNodeClaimNotFoundError`, `NewInsufficientCapacityError`, `NewNodeClassNotReadyError`) ; wrapping systématique avec contexte (`%w` + zone/serverID).
- **Delete idempotent et testé comme tel** (`TestDeleteNominalThenIdempotent`, `TestDeleteStoppingServerIsNotFound`) — le retrait de finalizer par le core est couvert.
- **Suite de tests solide pour un spike** : 26 tests, zéro réseau, zéro sleep (aucun test flaky par construction), fake avec injection d'erreurs + compteurs d'appels + mode `Transitional` pour geler les états intermédiaires, helpers avec `t.Helper()`, noms descriptifs, chemins d'erreur majoritaires (ICE, not-ready, power-off hors bande, flip `Available`).
- **Concurrence maîtrisée** : claim guard sous mutex avec TTL, cache d'offres thread-safe, patch de statut avec verrou optimiste et gestion du conflit.
- **Hygiène** : gofmt/vet/build propres, constantes nommées avec rationale, aucun magic number, aucun secret (credentials `scw.WithEnv` uniquement), Makefile avec `fmt-check` bloquant et golangci-lint opportuniste.

## Prochaines étapes recommandées

1. **Corriger F2 + F3** (~20 min cumulées) : aligner doc/code/signature de `invalidateInventoryFor`, remplacer `Requeue: true`. Deux quick wins qui purgent les seuls mensonges du code.
2. **Éliminer la sentinelle nil (F1)** avant M1 : paramètre explicite dans `buildInstanceType` + `FakeBackend.ListServers` aligné sur le réel + contrat « jamais nil » documenté dans l'interface. C'est le seul finding qui menace la fidélité de la suite de tests.
3. **Documenter ou résoudre l'hypothèse amd64 (F7)** et ajouter le test manquant du chemin List dégradé — à faire dans le même mouvement que le durcissement M1 (validation CRD F11, extraction F5/F6).

Aucune condition de handoff forte n'est remplie (pas de god module → pas de `/cli-audit-tangle` ; pas de secret → pas d'audit git ; pas de hot path avéré → pas de `/cli-forge-perf`). Suggestion hors skill : le sous-projet n'a aucune CI dédiée (le Makefile existe mais rien ne l'exécute automatiquement) — envisager `/cli-forge-pipeline` quand le module sortira du statut spike.

---
*Audit `cli-audit-code` — lecture intégrale des 17 fichiers Go (justifiée : ≤ 421 lignes/fichier), findings vérifiés par build/vet/tests + inspection du cache de modules pour les comportements de dépendances. Tiers et confiances selon `shared/triage.md` (Tier = urgence, GRADE = force de preuve).*
