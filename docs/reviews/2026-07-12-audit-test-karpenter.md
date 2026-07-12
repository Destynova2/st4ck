# Audit Test — karpenter-provider-scaleway

**Date** : 2026-07-12
**Cible** : `karpenter-provider-scaleway/` — 62 tests Go (49 fonctions + 13 sous-tests) + 2 runs `tofu test` golden (`modules/em-talos-bootstrap/tests/provider_id.tftest.hcl`)
**Langue du rapport** : français (README du sous-projet + demande en français, cohérent avec les audits frères du 2026-07-12)
**Cadrage** : les validations matérielles (critères LLD-002 n°1, 2, 4) sont **hors scope par design**, documentées au runbook M0-REPORT §3 — elles sont notées comme exclusions assumées, pas comme gaps.
**Score final** : **80/100 — Bon** (borne haute du « Good », 71-85)
**Équivalent TMMi** : **Niveau 3 — Defined** (niveau 4 bloqué par l'absence de mesure de couverture en CI)

---

## Inventaire des tests

| Type | Nombre | Exemples |
|------|--------|----------|
| Unitaires / composant (fake backend, fake kube client) | 62 cas (49 `func Test` + 13 sous-tests) | `pkg/cloudprovider/cloudprovider_test.go` (33 fn / 45 cas), `pkg/pool/{inventory,providerid,scaleway}_test.go` (12 fn), `pkg/controllers/nodeclass/controller_test.go` (4 fn) |
| Contrat statique (T0, offline) | 2 runs | `modules/em-talos-bootstrap/tests/provider_id.tftest.hcl` (golden byte-à-byte vs `TestFormatProviderID`) |
| Intégration (API Scaleway réelle) | 0 | — |
| E2E / matériel | 0 (protocole écrit, non exécuté) | runbook M0-REPORT §3.1-3.3 (critères 1, 2, 4) |
| **Total exécuté en CI** | **64** | ~1 403 lignes de test Go (vs ~1 182 lignes de prod : ratio 1,19:1) |

Vérifié en local : `go test ./...` → 62 verts, 5 packages, < 10 s, zéro réseau.

### Visualisation de la pyramide

```
   E2E / matériel        ░░░░  0   critères 1-2-4 → runbook §3 (exclusion assumée, serveur EM requis)
   Intégration réelle    ░░░░  0   adapter ScalewayBackend non exercé (gap réel, voir AT-002)
   Contrat statique T0   ▓░░░  2   tofu test golden provider_id (offline, CI)
   Unit / composant      ████ 62   fake in-memory, horloge fake, rendezvous déterministes (CI)
```

**Forme : pyramide tronquée assumée** — base dense et saine, sommet différé au
matériel avec runbook exécutable. Ce n'est PAS un ice cream cone (l'inverse) ;
la seule marche réellement manquante *dans le périmètre logiciel* est
l'adapter réel (voir findings).

### Position sur l'échelle T0-T4/M0

| Barreau | État | Preuve |
|---|---|---|
| T0 contrat/statique | ✅ | `tofu test` golden (2 runs, CI `test-tftest`), `fmt-check` + `vet` en gate |
| T1 composant | ✅ | 62 tests sur fake, step Woodpecker `karpenter-test` path-filtré (push + PR) |
| T2 fresh deploy | ⬜ assumé | runbook §3.1/§3.3 — inexécutable sans serveur EM |
| T3 day-2 | ⬜ assumé | power-off hors bande simulé au T1 seulement (`TestListReflectsOutOfBandPowerOff`) |
| T4 stress | ⬜ | rien (pas de hammer concurrent, pas de `-race` en gate — voir AT-001/AT-004) |
| **M0 mémoire** | ✅✅ **exemplaire** | chaque finding de revue (Codex #1-7, re-revue, audit F1-F13, XRAY, pré-mortem) → commit + test nommé cité en commentaire du test |

---

## Scores par dimension

| # | Dimension | Poids | Score /4 | Pondéré | Verdict |
|---|-----------|-------|----------|---------|---------|
| D1 | Scope & objectifs | 7 % | 4.0 | 7.00 | Critères de sortie numérotés (LLD §9), exclusions matérielles documentées avec runbook — exemplaire |
| D2 | Techniques de conception | 12 % | 4.0 | 12.00 | 6-7 techniques identifiables, chacune sur sa cible (détail ci-dessous) |
| D3 | Équilibre de la pyramide | 7 % | 2.0 | 3.50 | Deux niveaux exécutés (unit + contrat T0) ; intégration/E2E absents — assumé mais absent |
| D4 | Couverture & traçabilité | 11 % | 3.5 | 9.63 | RTM de fait : finding → commit → test nommé (M0-REPORT §5) ; mais zéro mesure de couverture en CI |
| D5 | Tests négatifs & sécurité | 8 % | 3.5 | 7.00 | ~60 % de cas négatifs, invariants nommés (garde d'appartenance S1, fail-closed statut inconnu) ; pas de fuzz sur le parsing |
| D6 | Tests non fonctionnels | 9 % | 2.5 | 5.63 | Budget API prouvé par compteurs d'appels ; fiabilité (chemins dégradés 503/401) ; SLO latence p95 défini mais non exécuté (matériel) |
| D7 | Analyse de risque & priorisation | 7 % | 4.0 | 7.00 | Pré-mortem 36 Ko + table de risques LLD §10 ; l'effort de test suit exactement les risques Tier 3 |
| D8 | Stratégie d'automatisation | 9 % | 3.5 | 7.88 | 100 % automatisé, déterministe (zéro sleep, horloge fake, rendezvous canaux), split manuel/auto explicite ; `-race` seulement manuel |
| D9 | Intégration CI/CD | 7 % | 3.0 | 5.25 | Gate de merge path-filtré (Go + tftest) ; pas de `-race`, pas de couverture, golangci-lint jamais exécuté en CI |
| D10 | Critères d'entrée/sortie | 5 % | 3.5 | 4.38 | 4 critères M0 mesurables, statut suivi par critère, conditions d'approbation de revue consignées |
| D11 | Tests exploratoires | 5 % | 2.0 | 2.50 | Pas de SBTM ; mais 2 passes de revue adversariale (Codex) + pré-mortem = exploration structurée réinjectée dans la suite |
| D12 | Environnement & données | 5 % | 3.5 | 4.38 | Fake injectable (6 canaux d'erreur + transitions contrôlables + compteurs), tofu offline sans credentials ; parité prod = la moitié matérielle manquante |
| D13 | Détection de dérive sémantique | 8 % | 2.0 | 4.00 | 1 couche solide (contrat : golden inter-langages + matrice 13×5 + statut futur) ; zéro mutation, zéro property-based |
| | **Total** | **100 %** | | **80.1** | **Bon** |

### Techniques détectées

| Technique | Preuve | Appliquée à |
|-----------|--------|-------------|
| Table de décision | `TestStatusMatrix` : matrice explicite 13 statuts × 5 méthodes (`cloudprovider_test.go:690`), `TestDeleteBlockedOrFailedServerErrors`, `TestDeleteTransientServerReturnsNil` | contrat CloudProvider complet par classe de statut |
| Transition d'états | `TestDeleteWhileStoppingRetriesUntilStopped` (stopping→stopped), fake `Transitional`, `TestGetInstanceTypesAvailableFlip`, `TestListReflectsOutOfBandPowerOff` | cycle de vie serveur EM |
| Partitionnement d'équivalence | 13 statuts SDK → 6 classes (`Status.Class`) testées par classe ; 7 classes d'IDs invalides (`TestParseProviderIDErrors`) ; ICE vs retryable vs NodeClassNotReady | statuts, providerID, taxonomie d'erreurs |
| Analyse des valeurs limites | pool vide (`TestGetInstanceTypesEmptyPoolIsUnavailable`), dernier serveur (course), TTL 0 (`TestInventoryZeroTTLDisablesCache`), saut d'horloge 3×TTL (`TestStartedClaimSurvivesStaleStoppedBeyondTTL`), expiration du cache négatif | caches, capacité, claims |
| Error guessing / injection | `FakeBackend` : 5 canaux d'erreur + `StartErrFor` par serveur + `StartErrButStarts` (échec ambigu dont l'effet a pris) + `StartKeepsStopped` (cohérence éventuelle) | tous les chemins d'échec, y compris ambigus |
| Scénario / cas d'usage | `TestDeleteReleasesStartedClaimOfFinalizedOwner` (Create A → Delete A → Create B réutilise), `TestCreateResumesOwnClaim` (idempotence du retry) | cycle de vie NodeClaim complet |
| Contrat / golden (D13) | `provider_id.tftest.hcl` ≡ littéral de `TestFormatProviderID` (byte-à-byte, les deux en CI) ; `pool.Status("future-sdk-status")` fige le comportement fail-closed face à un SDK futur | contrat providerID inter-langages Go/OpenTofu, forward-compat |
| Concurrence déterministe | `blockingBackend` à rendezvous par canaux (`inventory_test.go:62`), horloge fake `clocktesting` — zéro sleep dans toute la suite | interleaving fetch/Invalidate, TTL de claim |

Absentes : property-based (aucun `rapid`/`gopter`), fuzz natif Go, mutation
testing, pairwise (sans objet à cette échelle).

---

## Anti-patterns détectés

| Anti-pattern | Sévérité | Preuve | Recommandation |
|--------------|----------|--------|----------------|
| Silent Drift Blindness (partiel) | Warning | Une seule couche anti-dérive (contrat/golden). Aucun `go test -fuzz`, aucun property-based, aucune mutation. `mask`-équivalents ici : `Status.Class()`, `claimStoppedServer` — une mutation `>`→`>=` sur le TTL ou l'inversion d'une classe serait probablement attrapée par la matrice, mais personne ne l'a mesuré | Fuzz natif sur `ParseProviderID` (30 min, zéro dépendance) ; passe `go-mutesting`/`gremlins` ciblée sur `pkg/cloudprovider` en M1 |
| Testing Implementation (léger) | Info | `TestCreateLastServerRaceReturnsICE` appelle `claimStoppedServer` (non exporté) directement ; `TestGetOfferByNameNegativeCachedWithTTL` manipule `offerCache`/`offerMu` pour expirer une entrée | Acceptable (évite un sleep réel) ; à surveiller au refactor. Alternative : injecter une horloge dans `ScalewayBackend` comme dans `CloudProvider` |
| Ice Cream Cone | — | Non détecté (base unitaire dominante) | — |
| Cassandre | — | Non détecté — l'inverse : chaque résultat de revue a été traité, tracé, gaté en CI | — |
| Flaky Acceptance / State Bleed | — | Non détecté : zéro `sleep`, zéro retry, backend + provider reconstruits à chaque test (principe chaperon respecté), sous-tests de la matrice indépendants (itération de map = shuffle implicite) | — |
| Test Data Leakage | — | Non détecté : zéro secret en dur, fake in-memory, tofu test sans credentials | — |

---

## Findings (triage 3-2-1, tri par effort croissant dans chaque tier)

### Tier 2 — Majeur (4)

| ID | Finding | Preuve | Confiance | Effort |
|----|---------|--------|-----------|--------|
| AT-001 | **`-race` revendiqué mais absent du gate.** M0-REPORT annonce « 62 tests Go (`-race`) » ; or `make test` = `go test ./...` et la CI exécute `make … test` — le détecteur de course ne tourne que quand quelqu'un y pense. C'est précisément le module dont le risque n°1 est concurrentiel (claim guard mutex, interleaving inventaire) | `karpenter-provider-scaleway/Makefile:13`, `.woodpecker.yml:83` (grep `-race` : zéro occurrence) | HIGH (2 fichiers vérifiés) | Low — `$(GO) test -race ./...` |
| AT-004 | **Aucun test de concurrence réelle sur le claim guard.** La course du dernier serveur est testée séquentiellement (2 appels successifs) ; aucun test ne lance N goroutines `Create` sur un pool à 1 serveur. Combiné à AT-001, le code le plus sensible aux courses n'est jamais exécuté en concurrence réelle | `cloudprovider_test.go:156` (`TestCreateLastServerRaceReturnsICE`, séquentiel) | HIGH | Low — hammer 10 goroutines, assert 1 succès + `StartCalls==1`, sous `-race` |
| AT-003 | **Zéro fuzz/property sur la seule surface de parsing.** `ParseProviderID` est testé sur 7 littéraux fixes ; le fuzzing natif Go (sans dépendance) vérifierait la propriété round-trip `Parse(Format(z,id))==(z,id)` et l'absence de panic sur entrées arbitraires | `providerid_test.go:23` | HIGH (absence vérifiée) | Low — `FuzzParseProviderID` + seed corpus = les 7 cas existants |
| AT-002 | **L'adapter réel `ScalewayBackend` est quasi non testé** : seuls les 3 tests de cache d'offres l'exercent. `isNotStartable` (scaleway.go:112 — la classification qui décide ICE vs retryable, cœur des fixes Codex) et le mapping `ResourceNotFoundError`→`ErrServerNotFound` (scaleway.go:85) ne sont couverts par aucun test, alors que toute la suite prouve ces sémantiques **via le fake**. Le stub nécessaire existe déjà (`stubBaremetalAPI`) | `pkg/pool/scaleway.go:112,85` ; grep `isNotStartable|ErrServerNotFound` dans `*_test.go` : zéro | HIGH (grep + lecture) | Medium — table d'erreurs `scw.PreconditionFailedError`/`ResourceLockedError`/`OutOfStockError`/`TransientStateError`/403 via le stub existant (~1 h) |

### Tier 1 — Mineur (3)

| ID | Finding | Preuve | Confiance | Effort |
|----|---------|--------|-----------|--------|
| AT-005 | README affiche « 57 tests unitaires » — la re-revue a corrigé M0-REPORT (62) mais pas le README. Troisième dérive du compte en une journée (26 → 57 → 62) : le nombre en dur vieillit mal | `karpenter-provider-scaleway/README.md:9` vs M0-REPORT §5.5 | HIGH | Low — corriger ou remplacer par « suite CI » sans nombre |
| AT-006 | golangci-lint « opportuniste » = jamais exécuté en CI : l'image `golang:1.26` ne l'embarque pas, le Makefile skippe silencieusement. Le gate lint réel = gofmt + vet seulement | `Makefile:15-20`, `.woodpecker.yml:81-83` | HIGH | Low — l'installer dans le step ou assumer explicitement dans le README |
| AT-007 | Aucune mesure de couverture (locale ou CI). Une simple ligne `-coverprofile` aurait rendu le trou AT-002 visible dès la première passe (scaleway.go ~30 % couvert vs cloudprovider ~90 % estimés) | `.woodpecker.yml:83` (pas de `-cover`) | HIGH | Low — `go test -race -coverprofile` + affichage du % par package |

### Tier 3 — Critique

Aucun. Les trois passes de revue préalables (Codex ×2, audit-code) ont déjà
purgé les critiques ; cette suite est la preuve vivante du mécanisme M0.

---

## Forces

1. **Traçabilité finding→test de niveau rare** : chaque test de régression cite
   son origine en commentaire (« Codex Critical #1 proof », « Audit F1
   regression proof », « XRAY-001 proof », « re-review Major proof ») et
   M0-REPORT §5 maintient la table finding → commit → preuve. C'est un RTM
   bidirectionnel de fait, et le barreau M0 (mémoire anti-régression) le mieux
   exécuté du dépôt.
2. **Déterminisme exemplaire** : zéro `sleep`, zéro retry, concurrence pilotée
   par rendezvous de canaux, temps piloté par `clocktesting.FakeClock`,
   TTL expirés par manipulation d'horodatage — la suite entière tient sous
   10 s et ne peut pas flaker par timing.
3. **Philosophie fail-closed testée, pas seulement déclarée** : statut SDK
   inconnu (`future-sdk-status`) figé en `failed`-visible, garde
   d'appartenance prouvée destructive-safe (`StopCalls==0` sur serveur prod),
   erreurs inconnues jamais converties en signal de capacité.
4. **Golden inter-langages** : le contrat providerID est épinglé par le même
   littéral en Go et en OpenTofu, les deux en gate CI — dérive impossible
   sans casser un des deux tests.
5. **Ratio négatif/positif ≈ 60/40** : la suite teste d'abord ce qui ne doit
   PAS arriver (double power-on, capacité gelée, GC d'un serveur en erreur).

## Gaps & recommandations (dimensionnées)

| # | Action | Dimension | Effort | Gain |
|---|--------|-----------|--------|------|
| 1 | `-race` (+ `-shuffle=on`) dans `make test` et le step CI | D9, D8 | 15 min | Rend la revendication M0-REPORT continûment vraie ; active réellement les tests d'interleaving |
| 2 | Hammer concurrent : 10 goroutines × `Create` sur pool à 1 serveur, 1 succès attendu, sous `-race` | D6, D5 | 30 min | Exécute enfin le claim guard en concurrence réelle |
| 3 | `FuzzParseProviderID` (fuzz natif Go, seed = 7 cas existants) + propriété round-trip | D13, D5 | 30 min | 2e couche anti-dérive sur la surface de parsing, zéro dépendance |
| 4 | Table d'erreurs scw sur `isNotStartable` + `GetServer` via `stubBaremetalAPI` | D4, D2 | 1 h | Ferme la divergence fake/réel sur LA sémantique pivot (ICE vs retryable) |
| 5 | `-coverprofile` en CI + % par package dans le log | D4, D9 | 30 min | Objectivise les trous (scaleway.go) au lieu de les découvrir en revue |
| 6 | README : supprimer le compte de tests en dur (ou le corriger à 62) | D4 | 5 min | Stoppe la 4e dérive du chiffre |
| 7 | (M1) golangci-lint installé dans le step CI ; passe mutation ciblée `pkg/cloudprovider` (`gremlins`) | D9, D13 | 2-4 h | Monterait D13 à 3 (deux couches CI) — condition TMMi 5 |

Appliquer 1-6 (≈ 3 h) porterait le score à ~86-88 (« Excellent ») sans
toucher au périmètre matériel.

## Évaluation de maturité

- **TMMi 2 (Managed)** : ✅ D1=4, D4=3.5, D7=4, D10=3.5, D12=3.5 — toutes les exigences dépassées.
- **TMMi 3 (Defined)** : ✅ D2=4, D6=2.5, D8=3.5, D11=2 — atteint à l'échelle du projet (D11 au plancher ; l'exploration adversariale Codex/pré-mortem en tient lieu).
- **TMMi 4 (Measured)** : ❌ bloqué par D4 < 4 (pas de couverture mesurée en CI) et l'absence d'artefacts de résultats publiés. La reco n°5 est le premier pas.
- **Benchmark** : pour un spike M0 d'une semaine, 80/100 est très au-dessus de la référence « open-source library mature » (40-65 typique, cible 70+). La discipline revue→test est le facteur différenciant ; les gaps restants sont tous des gaps d'outillage (race/fuzz/coverage), pas de conception.

## Handoffs

| Condition | Skill | Pourquoi |
|-----------|-------|----------|
| D13 à une seule couche, mutation absente | `/cli-audit-drift` | Bootstrapper un CONTRACTS.md à partir de la matrice de statuts (le contrat existe déjà en prose README §Sémantiques — le figer) |
| SLO latence p95 < 12 min défini mais protocole manuel | `/cli-forge-perf` | Transformer le runbook §3.2 en harnais mesurable (5 runs, p95, décision pool tiède) le jour où le serveur EM arrive |
