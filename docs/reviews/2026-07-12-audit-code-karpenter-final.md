# Audit Code — karpenter-provider-scaleway (re-audit final)

**Cible** : `karpenter-provider-scaleway/` — code final de la branche `feat/karpenter-provider-scaleway` (14 commits touchant le sous-projet, de `d1a9a37` à `f58f944` ; approuvé Codex 9.3)
**Langage** : Go 1.26.5 | **Type** : contrôleur Kubernetes (provider Karpenter, M0 durci) | **Date** : 2026-07-12
**Audit précédent** : CQI 8.0 (`2026-07-12-audit-code-karpenter.md`, avant les 2 passes de fix)
**CQI Score** : **8.6/10 — Excellent** (**+0.6** vs audit précédent)
**Dette technique** : ~5 h (1 finding Tier 2 + 9 Tier 1 × 0,5 h) — **SQALE A** (ratio 0,3 %)

## Périmètre et méthode

- 18 fichiers Go, 3 103 lignes (2 997 hors `zz_generated.deepcopy.go`), dont 1 403 lignes de tests (~47 %). Code de production : ~1 594 lignes. Croissance depuis l'audit précédent : +1 458 / −157 lignes sur 15 fichiers.
- **Lecture intégrale de tous les fichiers de production** (justifiée : vérification obligatoire de la résolution de F1-F13 + invariants de concurrence du claim guard, sémantique fichier-entier requise) ; `cloudprovider_test.go` (981 lignes) lu en 2 tranches complètes (C8 pèse 12 % et les deux trous de tests de l'audit précédent devaient être vérifiés).
- Vérifications outillées : `gofmt -l` propre, `go vet ./...` propre, `go build ./...` propre, `go test ./...` → **62 tests verts, 5 packages, zéro réseau** (49 fonctions `Test` + 13 sous-tests de `TestStatusMatrix` — la revendication « 62 tests » est exacte).
- Zéro TODO/FIXME/HACK, zéro code commenté, zéro directive `//nolint`.

## Statut des findings F1-F13 de l'audit précédent

**10/13 résolus. Les 3 non résolus sont tous des Tier 1 mineurs.** Les deux trous de tests signalés (chemin List dégradé, invalidation sur Delete) sont **tous deux fermés**.

| # | Finding (audit CQI 8.0) | Statut | Preuve |
|---|--------------------------|--------|--------|
| F1 | Sentinelle nil de `buildInstanceType`, divergence fake/réel sur pool vide | ✅ **Résolu** | Paramètre explicite `computeAvailability bool` (`pkg/cloudprovider/instancetype.go:30`) ; contrat « jamais nil » documenté sur l'interface (`pkg/pool/backend.go:115-119`) ; fake aligné (`pkg/pool/fake.go:101-104`) ; test de régression `TestGetInstanceTypesEmptyPoolIsUnavailable` (`cloudprovider_test.go:839`) |
| F2 | `invalidateInventoryFor` : paramètre inutilisé, commentaire mensonger, erreur avalée | ✅ **Résolu** | Filtre réel `slices.Contains(server.Tags, nc.Spec.PoolTag)` (`cloudprovider.go:516`), échec de List loggé en V(1) (`:509-512`), doc alignée ; asserté par `TestDeleteInvalidatesOnlyPoolsOfTheServer` (`cloudprovider_test.go:881`) |
| F3 | `reconcile.Result{Requeue: true}` déprécié | ✅ **Résolu** | `RequeueAfter: time.Second` avec commentaire de traçabilité (`pkg/controllers/nodeclass/controller.go:53-55`) |
| F4 | Map `claimed` jamais purgée des serveurs disparus | ✅ **Résolu (dépassé)** | Purge des claims des serveurs sortis du listing (`cloudprovider.go:438-448`) ; la map a été repensée en modèle d'ownership complet (`serverClaim{owner, started}`) — au-delà du fix demandé |
| F5 | Duplication Delete/Get (parse → GetServer → mapping) | ✅ **Résolu** | Extraction de `serverFromProviderID` (`cloudprovider.go:265`), appelé par Delete et Get |
| F6 | Résolveurs jumeaux, wrapping incohérent | ✅ **Résolu** | Les deux résolveurs wrappent uniformément ; commentaire documentant l'unwrapping d'`apierrors.IsNotFound` (`cloudprovider.go:527-528`) |
| F7 | Architecture `amd64` codée en dur, hypothèse non écrite | ✅ **Résolu (portée M0)** | Hypothèse documentée avec contre-exemple EM-RV1 RISC-V + plan M1 (`instancetype.go:52-56`) ; la résolution dynamique depuis `Offer.CPUs` reste planifiée M1, comme recommandé |
| F8 | `Inventory.Snapshot` retourne la slice interne du cache | ✅ **Résolu (dépassé)** | `slices.Clone` à la lecture ET à l'écriture (`pkg/pool/inventory.go:51,65`) + invalidation generation-aware pour les fetchs en vol ; tests `TestInventorySnapshotReturnsPrivateCopy` et `TestInventoryInvalidateDuringInFlightFetchIsNotOverwritten` |
| F9 | `main.go` : log + panic en double | ✅ **Résolu** | `os.Exit(1)` après le log (`cmd/controller/main.go:29-30`) |
| F10 | Conversion `int32(len(servers))` non bornée (gosec G115) | ❌ **Non résolu** | Toujours présent (`controller.go:73-74`) — Tier 1/Info, risque nul en pratique (pool fini) |
| F11 | Validation CRD minimale (`zone` sans Pattern) | ❌ **Non résolu** | `MinLength=1` seul (`pkg/apis/v1alpha1/scalewayemnodeclass.go:12`, `config/crd/…yaml:64`) — une zone malformée ne se voit qu'en runtime via la condition `APIError` |
| F12 | `List()` contourne le cache inventaire sans commentaire | ✅ **Résolu** | Commentaire d'intention référençant F12/XRAY-003 avec budget chiffré (`cloudprovider.go:325-329`) |
| F13 | `FakeBackend.GetOfferByName` ignore la zone | ❌ **Non résolu** | Zone toujours ignorée (`pkg/pool/fake.go:193`), offres indexées par nom seul — un futur test multi-zones ne détecterait pas un bug de zone |

## Scores par catégorie

| # | Catégorie | Poids | Score | Pondéré | Évolution | Findings |
|---|-----------|-------|-------|---------|-----------|----------|
| C1 | Naming & lisibilité | 8 % | 0.92 | 0.074 | +0.02 | Taxonomie `Status→Class` exemplaire (`ClassStartable`, `ClassBlocked`…), noms métier (`claimStoppedServer`, `unclaimOwner`, `isPoolMember`) ; abréviation `it` persiste |
| C2 | Fonctions & complexité cognitive | 12 % | 0.85 | 0.102 | = | Max ~56 lignes commentaires inclus (`claimStoppedServer`), complexité cognitive max ~12 (< 15 partout) ; `toNodeClaim` toujours à 5 paramètres |
| C3 | Design de modules (deep vs shallow) | 10 % | 0.85 | 0.085 | −0.05 | `pool.Backend` toujours profond, enrichi de la taxonomie de classes ; **`cloudprovider.go` à 591 lignes entre en zone de pression de mitose (500-600)** — N2 |
| C4 | DRY & amplification de changement | 8 % | 0.80 | 0.064 | +0.10 | F5/F6 corrigés ; duplication résiduelle `isPoolMember`/`invalidateInventoryFor` (N7) |
| C5 | Gestion d'erreurs & robustesse | 10 % | 0.85 | 0.085 | +0.10 | Taxonomie `ErrNotStartable` + désambiguïsation des échecs StartServer (relecture) + fail-closed systématique ; plus aucune erreur avalée |
| C6 | Type safety & idiomes | 8 % | 0.85 | 0.068 | +0.15 | Sentinelle nil éliminée, enums typés, `errors.As` sur les types SDK ; `int32()` non borné (F10), `sort.Slice` vs `slices.SortFunc` incohérents (N4) |
| C7 | Commentaires & doc API publique | 5 % | 0.90 | 0.045 | +0.10 | Traçabilité remarquable : chaque fix référence son finding (audit Fn, Codex #n, XRAY-nnn, re-review) ; quelques exports non documentés (N5) |
| C8 | Qualité des tests | 12 % | 0.90 | 0.108 | +0.10 | 62 tests, matrice de statuts 13×4 surfaces, rendez-vous par channels (zéro sleep), fake clock, les 2 trous précédents fermés ; F13 persiste, un test manipule les internals du cache (N6) |
| C9 | Sécurité & validation des entrées | 10 % | 0.85 | 0.085 | +0.05 | **Garde d'appartenance au pool testée sur Get+Delete** (pre-mortem S1), parse strict des providerID (segments surnuméraires rejetés) ; validation CRD toujours minimale (F11) |
| C10 | Immutabilité & gestion d'état | 7 % | 0.80 | 0.056 | +0.10 | Snapshots privés clonés, invalidation générationnelle, claims sous mutex ; **Delete n'interroge pas l'ownership des claims avant StopServer** (N1) |
| C11 | Charge cognitive & flux de contrôle | 5 % | 0.90 | 0.045 | +0.10 | Switch sur `Class` remplaçant les comparaisons de statuts, early returns, boucle de quarantaine bornée et documentée |
| C12 | Dépendances & architecture | 5 % | 0.95 | 0.048 | +0.05 | DAG inchangé et propre ; **extraction de `baremetalAPI`** (sous-interface du SDK) qui rend le backend réel testable sans réseau |
| | **CQI** | **100 %** | | **8.6/10** | **+0.6** | |

## Anti-patterns détectés

| Pattern | Sévérité | Fichier:ligne | Recommandation |
|---------|----------|---------------|----------------|
| TOCTOU inter-NodeClaim (race Delete/Create) | Major | `pkg/cloudprovider/cloudprovider.go:222-229` | Vérifier l'ownership des claims avant StopServer (voir N1) |
| Mitosis pressure (Ousterhout, bande 500-600) | Minor | `pkg/cloudprovider/cloudprovider.go` (591 lignes) | Extraire le claim guard dans `claimguard.go` (voir N2) |
| Long Parameter List (léger, hérité) | Minor | `pkg/cloudprovider/cloudprovider.go:558` | `toNodeClaim` toujours à 5 paramètres — inchangé, toujours tolérable |

Les anti-patterns de l'audit précédent (Duplicated Code, Lying Comment, Nil-as-Sentinel) sont **tous éliminés**. Toujours aucun God Class, aucun module fourre-tout, aucun weasel-word, aucun code mort.

## Violations critiques (à corriger)

**Aucune.** Zéro finding Tier 3 : pas de secret en dur, pas d'erreur avalée, pas de data race sur l'état interne (tout est sous mutex, les snapshots sont clonés).

## Flags (à corriger — Tier 2)

### C10 : Delete peut éteindre un serveur qu'un autre NodeClaim vient de réclamer et démarrer — N1
- **Fichier** : `karpenter-provider-scaleway/pkg/cloudprovider/cloudprovider.go:222-229` (branche `ClassLive` de `Delete`)
- **Tier** : 2 | **Confiance** : MEDIUM (lecture de code, ordonnancement plausible non prouvé par un test)
- **Quoi** : la branche `ClassLive` de `Delete` appelle `StopServer` puis `unclaim(server.ID)` **sans consulter l'ownership de la map `claims`**. Ordonnancement : le serveur X du NodeClaim A (en terminaison) atteint `stopped` ; entre deux retries du Delete de A, le Create de B liste X `stopped`, le claim et le démarre (X → `starting`) ; le retry suivant du Delete de A voit `ClassLive` → `StopServer` sur le serveur en cours de boot de B, puis `unclaim` libère le claim démarré de B.
- **Pourquoi** : trois effets. (1) power-off parasite d'un serveur EM en cours de boot (cycle baremetal ≈ 5-10 min perdu, le NodeClaim de B finit GC après le TTL d'enregistrement) ; (2) pendant la fenêtre, **A et B portent le même providerID** — précisément l'invariant que le commentaire de `pendingClaimTTL` (`:44-46`) affirme impossible ; (3) le claim de B est libéré par le Delete d'un autre owner. Auto-cicatrisant (le core recrée un NodeClaim, le serveur revient au pool) mais c'est exactement l'interférence inter-NodeClaim que le claim guard existe pour empêcher.
- **Fix** : dans la branche `ClassLive`, si `c.claims[server.ID]` existe avec `owner != nodeClaim.UID` et `started`, le serveur a été légitimement reconsommé : répondre `NodeClaimNotFoundError` (l'instance de CE NodeClaim est bien terminée — le serveur a été observé `stopped` puis réattribué) au lieu d'émettre `StopServer`. Durcissement complémentaire M1 : `claimStoppedServer` pourrait exclure les serveurs dont le providerID est encore référencé par un NodeClaim vivant (un `kubeClient.List` cache-backed par Create).
- **Disproof** : non atteignable SI karpenter-core garantissait qu'aucun Create ne peut viser le pool pendant qu'un Delete est en vol sur le même serveur — aucune telle garantie n'existe (contrôleurs de provisioning et de terminaison indépendants). La fenêtre exige que le Create complet de B (list + claim + start) tienne entre deux polls de terminaison (quelques secondes) : étroite, mais les stops EM durent des minutes et le churn scale-down/scale-up simultané est le régime nominal d'un autoscaler.

## Mineurs (Tier 1, triés par effort croissant)

1. **N3 — `List()` calcule une disponibilité qu'il n'utilise pas** (`cloudprovider.go:334`, confiance HIGH). `buildInstanceType(…, servers, true)` : le type ne sert qu'à hydrater Capacity/labels, l'`Offering.Available` calculé est ignoré par `toNodeClaim`. Passer `false` dirait l'intention et économiserait un `CountByStatus`.
2. **F10 (reporté) — conversion `int32(len(servers))` non bornée** (`controller.go:73-74`, confiance HIGH, Info). À traiter si golangci-lint/gosec entre dans la CI.
3. **N4 — idiomes incohérents** (confiance HIGH). `sort.Slice` (`cloudprovider.go:423`) vs `slices.SortFunc` (`fake.go:110`) ; copies de maps manuelles dans `toNodeClaim` (`:560-568`) où `maps.Copy` est disponible.
4. **N5 — exports non documentés** (confiance HIGH). `New`, type `CloudProvider`, `Name`, `GetSupportedNodeClasses` (`cloudprovider.go`), `NewController` (`controller.go:35`) sans doc comment — le reste de l'API publique est documenté au-dessus du standard.
5. **F13 (reporté) — `FakeBackend.GetOfferByName` ignore la zone** (`fake.go:193`, confiance MEDIUM). Indexer par `zone+"/"+name` comme le backend réel (`scaleway.go:135`) pour que la suite reste fidèle en multi-zones.
6. **N6 — test couplé aux internals du cache d'offres** (`pkg/pool/scaleway_test.go:85-90`, confiance MEDIUM). `TestGetOfferByNameNegativeCachedWithTTL` réécrit `offerCache`/`fetchedAt` sous `offerMu` pour expirer l'entrée négative. Injecter une horloge (`clock.Clock`, déjà en dépendance) rendrait le test robuste aux refactors du cache.
7. **N7 — duplication `isPoolMember`/`invalidateInventoryFor`** (`cloudprovider.go:293-305` vs `:506-520`, confiance MEDIUM). Deux fois « lister les nodeclasses + matcher zone/tag » (~7 lignes). Règle de cristallisation atteinte (2 appels) : extraire un itérateur `poolsMatching(ctx, zone, tags)`.
8. **F11 (reporté) — validation CRD minimale** (`scalewayemnodeclass.go:11-25`, confiance MEDIUM). `+kubebuilder:validation:Pattern=^[a-z]+-[a-z]+-\d+$` sur `zone` rejetterait la faute à l'admission plutôt qu'en runtime. À faire avec le durcissement M1.
9. **N2 — `cloudprovider.go` en zone de pression de mitose** (591 lignes, bande 500-600, confiance HIGH). ~40 % de commentaires d'intention, mais le fichier héberge deux responsabilités séparables : le contrat CloudProvider et le claim guard (`serverClaim`, `claimedServer`, `claimStoppedServer`, `markClaimStarted`, `unclaim`, `unclaimOwner` ≈ 130 lignes). Extraire `claimguard.go` (même package) avant d'ajouter M1.

## Bonnes pratiques relevées

- **Traçabilité finding→fix exemplaire** : chaque correction porte un commentaire référençant sa source (`audit F1`, `Codex Critical #1`, `re-review Major`, `XRAY-003`, `pre-mortem S1`). Un futur mainteneur peut reconstituer *pourquoi* chaque garde existe. C'est rare et précieux.
- **Taxonomie `Status→Class`** (`backend.go:33-76`) : les 13 statuts SDK sont réduits à 6 classes de comportement avec fail-closed par défaut (`ClassFailed` pour tout statut inconnu, y compris ceux ajoutés par de futurs SDK). `TestStatusMatrix` épingle les 13 statuts × 4 surfaces (List/Get/Create/Delete) — le contrat complet est un test.
- **Machine à états `startClaimedServer`** : désambiguïsation des échecs StartServer par relecture (l'erreur ne signifie pas que le start n'a pas eu lieu), claim conservé en cas d'ambiguïté (fail closed contre le double power-on), classification `ErrNotStartable` vs retryable — chaque branche est testée (`TestCreateRetryAfterAmbiguousErrorDoesNotRestart`, `TestCreateAmbiguousStartErrorSucceedsWhenStartTookEffect`, `TestCreateUnknownStartErrorIsNeverICE`).
- **Concurrence testée déterministiquement** : `blockingBackend` avec rendez-vous par channels (`inventory_test.go:59-116`) prouve l'invalidation générationnelle sans un seul sleep — zéro test flaky par construction.
- **Garde de sécurité pool-membership** (pre-mortem S1) : un providerID forgé ou périmé ne peut jamais atteindre `StopServer` (projet Scaleway partagé, IAM `ElasticMetalFullAccess`) ; testé côté Get ET Delete avec assertion que le serveur hors-pool reste intact.
- **Cache négatif d'offres avec TTL** (XRAY-001) : les erreurs transitoires ne sont jamais cachées, seul `ErrOfferNotFound` l'est, borné à 1 min ; le stub `baremetalAPI` prouve les 3 régimes (positif éternel, négatif TTL, transitoire non caché).
- **Hygiène inchangée au sommet** : gofmt/vet/build propres, zéro TODO, zéro secret, credentials env-only, Makefile avec `fmt-check` bloquant.

## Prochaines étapes recommandées

1. **N1** (~1 h avec test) : garde d'ownership dans la branche `ClassLive` de `Delete` + test reproduisant l'ordonnancement (le harnais existant — `StartKeepsStopped`, fake clock, claims inspectables — suffit). C'est le seul finding au-dessus de Tier 1 et il ferme le dernier trou du modèle d'ownership.
2. **Quick wins Tier 1 groupés** (~1 h) : N3 (`false` dans List), N4 (idiomes), N5 (doc comments), F13 (zone dans le fake). Purge tout ce qui est mécanique avant M1.
3. **Avec le chantier M1** : F11 (Pattern CRD), F7-M1 (arch depuis `Offer.CPUs`), N2 (extraction `claimguard.go`), N7 (helper `poolsMatching`) — à faire dans le même mouvement que le durcissement prévu.

Aucune condition de handoff forte (pas de god module, pas de secret, pas de hot path avéré). Rappel de l'audit précédent toujours valable : le sous-projet n'a **aucune CI dédiée** (le Makefile existe, rien ne l'exécute automatiquement) — `/cli-forge-pipeline` reste pertinent maintenant que le module sort du statut spike.

---
## Verdict comparatif

| | Audit initial | Re-audit final | Δ |
|---|---|---|---|
| CQI | 8.0/10 | **8.6/10** | +0.6 |
| Findings Tier 3 | 0 | 0 | = |
| Findings Tier 2 | 4 (F1, F2, F3, F7) | 1 (N1, nouveau) | −3 |
| Findings Tier 1 | 9 | 9 (3 reportés + 6 nouveaux) | = |
| Tests | 26 | 62 | +36 |
| Ratio tests | ~35 % | ~47 % | +12 pts |
| Dette (SQALE) | 6,5 h (A) | 5 h (A) | −1,5 h |

Les 2 passes de fix ont résolu **10 findings sur 13** (les 3 restants sont des mineurs explicitement différables), fermé les 2 trous de tests, et les corrections Codex ont ajouté un modèle d'ownership des claims nettement plus robuste que le design initial. Le seul finding nouveau (N1) est une race résiduelle *dans* ce nouveau modèle — la surface d'attaque s'est déplacée vers le haut, signe d'un durcissement réel. Code au niveau « open-source library target 8.0+ » : atteint.

*Audit `cli-audit-code` — lecture intégrale du code de production (justifiée : vérification F1-F13 + invariants du claim guard), tests lus en tranches complètes, findings vérifiés par build/vet/tests. Tiers et confiances selon `shared/triage.md`. Envelope machine : `.claude/cli-audit-code.json`.*
