# M0-REPORT — spike karpenter-provider-scaleway

**Date** : 2026-07-12 (mis à jour post-revue M0-FIX, même jour)
**Réf.** : LLD-002 (`docs/design/002-karpenter-scaleway-em.md`), plan §9 ;
revues : `CODEX-REVIEW.md`, `docs/reviews/2026-07-12-audit-code-karpenter.md`,
`…-audit-xray-karpenter.md`, `…-premortem-metal.md`.
**État global** : critère de sortie n°3 (squelette compilant + fake + tests)
**atteint** — 57 tests, CI Woodpecker en gate. Les bloquants de revue
code/architecture sont levés (statut détaillé §5). Critères n°1, 2 et 4
(validations matérielles / bout en bout) **non exécutés** — ils exigent un
serveur EM réel ; runbook ci-dessous.

## 1. État des livrables code

| Livrable | État |
|---|---|
| Module Go compilable (`go build ./...`), layout LLD §8 | ✅ Go 1.26, karpenter-core pinné **v1.14.0** (dernier tag ; signature `NewControllers` 9 args + variadic vérifiée sur le tag), scaleway-sdk-go v1.0.0-beta.36, controller-runtime v0.23.1, operatorpkg (version du go.mod karpenter) |
| Interface CloudProvider complète | ✅ 9 méthodes, sémantiques LLD §3 (voir tests) |
| Backend derrière `pool.Backend` + fake in-memory | ✅ `ScalewayBackend` (baremetal v1, auth `scw.WithEnv`, cache d'offres, `scw.WithAllPages`) ; `FakeBackend` thread-safe avec injection d'erreurs et transitions contrôlables |
| Tests unitaires verts, zéro réseau | ✅ 26 tests : create/delete nominal, pool épuisé → ICE, course dernier serveur (claim guard), Delete idempotent (absent/`stopped`/`stopping`), List = allumés seulement + power-off hors bande (GC), mapping providerID, flip `Offering.Available`, conditions Ready du NodeClass |
| CRD `ScalewayEMNodeClass` v1alpha1 + contrôleur Ready | ✅ types + deepcopy + CRD YAML (`config/crd/`), contrôleur statut (`poolSize`, `available`, `PoolReady` → `Ready` dérivée operatorpkg), requeue 1 min |
| README + Makefile | ✅ build/test/lint (gofmt + vet + golangci-lint opportuniste) |
| Chart Helm | ⬜ hors périmètre M0 (M1, conforme LLD §8) |

## 2. Écarts vs LLD (assumés, code upstream ou pragmatisme spike)

1. **Pas de polling bloquant dans Create/Delete.** Le tableau §3 du LLD
   mentionne « poll `GetServer` → `ready`/`stopped` ». Implémenté
   asynchrone : `Create` retourne dès que `StartServer` est accepté (le
   providerID est dérivable sans attendre), `Delete` dès `StopServer`.
   Raisons : (a) bloquer la boucle launch du core pendant des minutes
   sérialiserait les provisionnements ; (b) la fenêtre
   `registrationTimeout = 15 min` couvre déjà POST+boot (C1) ; (c) `List()`
   inclut `starting`, donc pas de GC intempestif pendant le boot ; le retry
   `Delete` du core observe la progression `stopping` → `stopped` (nil tant
   que la terminaison est en cours, NotFound une fois `stopped` — contrat
   core, corrigé par M0-FIX). Aligné sur kwok/cluster-api (aucun provider
   upstream ne poll dans Create).
2. **Machine à états complète, fail-closed** *(remplace l'écart initial
   « stopping/error traités comme éteints », infirmé par la revue Codex)* :
   les 13 statuts SDK sont classés startable/live/terminating/transient/
   blocked/failed. Seul `stopped` (ou l'absence du serveur) signifie
   « instance disparue » pour Get/List/Delete ; `locked`/`out_of_stock`/
   `error`/statut inconnu restent visibles et Delete y répond par une
   erreur explicite (le finalizer reste, l'opérateur voit). Conséquence
   assumée : un serveur en `error` ne disparaît plus silencieusement de
   List() — le nœud passe NotReady et reste visible (bruyant plutôt que
   l'érosion silencieuse P1 du pré-mortem).
3. **Overhead vide** (`InstanceTypeOverhead{}`) et **maxPods = 110** figé.
   Comme kwok/cluster-api. L'Allocatable annoncé est donc optimiste vs le
   kubelet Talos réel (kubeReserved) — à recaler avec la mesure matérielle
   (critère 2) ; risque : pods nominés qui ne tiennent pas, faible sur des
   shapes 32 threads/128 Gi.
4. **Requirements réduits à 5 labels** (instance-type, arch, os, zone,
   capacity-type) et **arch figée `amd64`** (les gammes EM ARM ne sont pas
   dans le périmètre du pool M0). À dériver de l'offre en M1 si besoin.
5. **Create ne re-filtre pas les requirements du NodeClaim** contre
   l'instance type : le scheduler core vient de le nominer, et le pool est
   mono-offre. cluster-api refait ce filtre (multi-MachineDeployment), sans
   objet ici.
6. **Anti-course locale, pas distribuée** : le guard de claim (TTL 2 min,
   mutex process) protège un contrôleur single-replica — le déploiement
   karpenter standard (leader election). Pas de lock côté API Scaleway.
7. **deepcopy + CRD YAML maintenus à la main** (pas de controller-gen dans
   le module : budget dépendances LLD « karpenter-core, controller-runtime,
   scaleway-sdk-go, operatorpkg » respecté — `samber/lo`, `k8s.io/*` etc.
   restent transitifs). À regénérer par outillage en M1.
8. **Module path placeholder** `github.com/st4ck/karpenter-provider-scaleway`
   — à renommer si le provider est publié dans une org réelle.
9. **Cache inventaire TTL 10 s** devant `GetInstanceTypes` (appelé à chaque
   boucle de scheduling) pour tenir le budget « ≤ 1 req/10 s » du LLD §8 ;
   `Create` court-circuite le cache (choix du serveur sur données fraîches)
   et invalide après chaque transition de puissance. Pas de backoff 429
   dédié en M0 (le SDK ne retry pas) — à traiter en M1 si la télémétrie le
   montre nécessaire.

## 3. Runbook — validations matérielles restantes (critères 1-2, LLD §9)

Nécessitent ≥ 1 serveur EM réel (EM-A116X-SSD, fr-par-2) pré-imagé par
`modules/em-talos-bootstrap`. **Non exécutées dans ce spike.**

### 3.1 Critère 1 — `provider-id` accepté par Talos v1.12 (Option A)

Le premier test M0 du LLD §4 : la denylist kubelet de Talos v1.12
autorise-t-elle `provider-id` dans `machine.kubelet.extraArgs` ?

1. Patch machineconfig sur un worker de test :
   ```yaml
   machine:
     kubelet:
       extraArgs:
         provider-id: scaleway-em://fr-par-2/<server-uuid>
   ```
   `talosctl patch mc --mode=reboot -p @patch.yaml` (ou intégré au
   pré-imaging).
2. **Rejet immédiat** = erreur de validation à l'apply (arg denylisté) →
   consigner et passer Option B.
3. Sinon vérifier au boot : `talosctl logs kubelet | grep provider-id`,
   puis `kubectl get node <n> -o jsonpath='{.spec.providerID}'` ==
   `scaleway-em://fr-par-2/<server-uuid>` **octet pour octet** (C3 : le
   matching NodeClaim↔Node est strictement l'égalité de chaîne).
4. **Repli Option B** (talos-ccm, Platform: metal) : providerID devient
   `scaleway-metal:///{{ .UUID }}` (SMBIOS, pas l'ID API) ⇒ maintenir la
   map `{server-id → UUID}` au pré-imaging, adapter
   `pkg/pool/providerid.go` + hydratation Create(), et déclarer
   `node.cloudprovider.kubernetes.io/uninitialized` en `startupTaints` du
   NodePool.

### 3.2 Critère 2 — latence power-on → Node Ready, p95 < 12 min (×5 runs)

1. Par run (server `stopped`, node absent du cluster) :
   - `t0` : `scw baremetal server start <id> boot-type=normal`
   - `t1` : poll `GetServer` (1 req/10 s max) jusqu'à `status==ready`
   - `t2` : poll `kubectl get node` jusqu'à condition `Ready=True`
   - power-off (`server stop`), attendre `stopped`, run suivant.
2. Rapporter t1−t0 (POST+boot côté API) et t2−t0 (jusqu'au join kubelet)
   par run + p95 ; **seuil : p95(t2−t0) < 12 min** (marge 3 min sur la
   const `registrationTimeout` 15 min, C1).
3. Échec → repli LLD « pool tiède » : serveurs maintenus `ready` + cordon,
   le provider ne fait que uncordon/cordon (coût identique : un EM arrêté
   reste facturé). Décision aux résultats.
4. À vérifier au passage (risque LLD §10) : après un arrêt long (> 7 j,
   simulable à l'horloge), le kubelet re-join sans cert périmé (Talos
   re-bootstrappe le kubelet au boot).

### 3.3 Critère 4 — bout en bout cluster dev

NodePool statique (LLD §7) `replicas: 0→1` → un serveur passe `starting` →
`ready` → Node join avec providerID matché (NodeClaim `Registered` puis
`Initialized`) ; `1→0` → drain → `StopServer` → `stopped` + NodeClaim
finalisé. Vérifier aussi : power-off console (hors bande) → NodeClaim GC
en ~2 min.

## 4. Prochaines étapes (M1 rappel LLD)

Chart Helm + intégration stack `autoscaling/` (contexte multi-env), scale
des replicas piloté (KEDA sur pods Pending metal), métriques pool,
backoff 429, regénération controller-gen.

## 5. Revue M0-FIX (2026-07-12) — statut des findings, un par un

### 5.1 Codex (`CODEX-REVIEW.md`)

| Finding | Statut | Commit / argument |
|---|---|---|
| Critical #1 — claim TTL 2 min peut ré-assigner le dernier serveur | **fixed** `65854df` | Claim lié au UID du NodeClaim ; un claim démarré ne se libère jamais tant que l'API dit `stopped` ; retry Create = resume du même claim ; preuve horloge fake (stale `stopped` 3×TTL → ICE, pas de double providerID, pas de second StartServer) |
| Critical #2 — Delete NotFound pendant `stopping` | **fixed** `a0dd67a` | nil sur `stopping`/transitoire (le core retry), NotFound uniquement `stopped`/absent ; test rejoué conformément au « Proof expected » |
| Major #3 — statuts incomplets, fail-open `out_of_stock`/inconnu | **fixed** `a0dd67a` | 13 statuts / 6 classes, inconnu = failed (jamais NotFound) ; matrice de statuts × {Create,Delete,Get,List,GetInstanceTypes} |
| Major #4 — invalidation d'inventaire écrasée par un fetch en vol | **fixed** `42859df` | Générations par clé ; test d'interleaving déterministe fetch→Invalidate→store avec backend bloquant |
| Major #5 — échecs StartServer post-claim non classifiés | **fixed** `65854df` | Relecture de désambiguïsation ; rejet définitif + dernier candidat → ICE ; ambigu → claim conservé (fail-closed) |
| Major #6 — NodeClass absente = ICE | **fixed** `3ed6458` | `NodeClassNotReadyError` ; jamais ICE pour une erreur de config |
| Major #7 — égalité d'octets providerID non prouvée côté bootstrap | **fixed (part codable)** `fd02d1e` | Le module injecte `provider-id` dérivé des MÊMES (zone, server-id) que `pool.FormatProviderID` + output `provider_id`. La preuve d'égalité octet à octet sur nœud réel reste le critère matériel n°1 (runbook §3.1) — inexécutable sans serveur |
| Minor — parsing providerID accepte des segments en trop | **fixed** `ee996b1` | Rejet strict + cas golden `scaleway-em://fr-par-2/abc/def` |

Conditions d'approbation Codex : 1-3 prouvées par tests unitaires (57, CI en
gate) ; la n°4 (byte equality sur machineconfig rendu / smoke réel) est
transférée au runbook matériel §3.1 avec le contrat partagé committé des
deux côtés.

### 5.2 Audit-code (F1-F13, CQI 8.0)

| # | Statut | Commit / argument |
|---|---|---|
| F1 sentinelle nil `buildInstanceType` + fake divergent | **fixed** `ee996b1` | Paramètre explicite `computeAvailability` ; fake aligné (slice vide non-nil) ; contrat « jamais nil » documenté sur `Backend.ListServers` ; preuve pool vide → `Available=false` |
| F2 `invalidateInventoryFor` (param mort, doc mensongère, erreur avalée) | **fixed** `ee996b1` | Filtre réel par tag du serveur, doc alignée, échec loggé V(1) ; preuve : Delete pool A n'invalide pas pool B |
| F3 `Requeue: true` déprécié | **fixed** `ee996b1` | `RequeueAfter: time.Second` sur conflit optimiste |
| F4 map `claimed` jamais purgée | **fixed** `65854df` | Purge des IDs absents du listing dans la passe verrouillée du claim |
| F5 duplication Delete/Get | **fixed** `a0dd67a` | `serverFromProviderID` partagé (parse + Get + garde d'appartenance) |
| F6 résolveurs jumeaux, wrapping incohérent | **fixed** `3ed6458` | Les deux wrappent ; `apierrors.IsNotFound` unwrappe via `errors.As` (vérifié) |
| F7 arch amd64 codée en dur | **documenté** `ee996b1` | Hypothèse écrite au point d'usage + README ; résolution depuis `Offer.CPUs` = M1 (comme recommandé « fix M0 : documenter ») |
| F8 slice de cache partagée | **fixed** `42859df` | `slices.Clone` au hit et au fill ; test anti-aliasing |
| F9 log + panic dans main | **fixed** `ee996b1` | `os.Exit(1)` |
| F10 conversion `int32` non bornée | **argué, non corrigé** | Overflow théorique (gosec G115) sur un pool fini de quelques serveurs ; l'audit le classe Info/« à noter si gosec est activé un jour ». À traiter avec l'arrivée de golangci-lint, pas en spike |
| F11 validation CRD minimale (pattern zone) | **argué, différé M1** | Durcissement d'admission = lot validation M1 (avec regénération controller-gen) ; en M0 la faute se voit via la condition `APIError` du nodeclass — acceptable pour un spike jamais déployé |
| F12 bypass cache de `List()` non commenté | **fixed** `8bc7fac` | Commentaire d'intention ; le routage par l'inventaire lui-même est volontairement NON fait (invariant de staleness GC non écrit — XRAY-003) |
| F13 fake offres sans clé de zone | **argué, différé M1** | Corriger impose `AddOffer(zone, offer)` (le type `Offer` ne porte pas de zone) — churn de signature sans test multi-zone existant à protéger. À faire avec le support multi-zones M2 |

### 5.3 X-ray (`…-audit-xray-karpenter.md`)

| Carte | Statut | Argument |
|---|---|---|
| XRAY-001 cache négatif d'offres | **fixed** `8bc7fac` | TTL 1 min sur `ErrOfferNotFound` uniquement (erreurs transitoires jamais cachées) ; preuves compteur : 5 miss = 1 appel, récupération post-TTL, 503 non caché |
| XRAY-002 single-flight Snapshot | **non fait (assumé)** | Gain ∝ nombre de NodePools par pool (1 en M0) ; le piège single-flight×Invalidate est le vrai risque et les générations de `42859df` posent la base. À mesurer en M1 (télémétrie) avant d'ajouter la complexité |
| XRAY-003 router List()/nodeclass par l'inventaire | **non fait (needs_invariant)** | La tolérance du GC core à une staleness ≤ 10 s n'est écrite ni testée nulle part ; la carte elle-même dit « sans lui, ne pas appliquer ». Documenté au point d'usage (F12). Budget statique ~1,25 req/10 s assumé en M0 |
| XRAY-004 sur-invalidation par zone | **fixed** `ee996b1` | = F2 (filtre par tag) |
| XRAY-005 aliasing snapshot | **fixed** `42859df` | Copie défensive (option la plus sûre de la carte) |
| XRAY-006 `Available` ignore les claims en vol | **non fait (décision LLD)** | Le LLD C2 assume explicitement la course résiduelle du dernier serveur (ICE testé) ; la carte le note « décision d'architecture », confiance 0.60. Confort opérationnel, pas un bug — M1 si le churn ICE se mesure |

### 5.4 Pré-mortem (`…-premortem-metal.md`)

| Item | Statut | Argument |
|---|---|---|
| ERRATUM cohabitation (G4 infirmé) | **acté — aucun mécanisme de partition implémenté** | core v1.14 partitionne par GroupKind de NodeClass (`IsManaged`). Le prérequis réel (CRDs `karpenter.sh` ≥ v1.14 vs chart autoscaling pinné 1.3.3) est documenté au README « Prérequis de déploiement » |
| Tier 3 #2 garde d'appartenance (S1, mutation #4) | **fixed** `a0dd67a` | Delete/Get refusent tout serveur sans tag de pool déclaré ; le NotFound (plutôt qu'une erreur) garde convergent le flux maintenance « détagger → GC → finalizer retiré sans toucher au matériel » ; refus loggé ; StopServer jamais atteint (testé) |
| Tier 3 #3 CI | **fixed** `ec1f38c` | Step Woodpecker `karpenter-test` (fmt-check + vet + test), path-filtré |
| Tier 3 #1 décision de cohabitation (ADR) | **hors périmètre code** | Requalifié par l'ERRATUM en prérequis d'intégration ; documenté README. La décision d'alignement du chart de la stack `autoscaling` appartient à cette stack |
| Tier 3 #4 gate d'achat (critères matériels 1-2) | **inchangé — runbook §3** | Toujours inexécutable sans serveur EM |
| G2 dérive version Talos du module | **fixed** `fd02d1e` | Défaut `talos_image_url` v1.10.4 → **v1.12.9** (aligné plateforme) |
| P7 `spec.replicas` / feature gate | **documenté** | Champ **alpha** dans core v1.14.0, derrière `StaticCapacity` (défaut `false` — vérifié dans `options.go` du tag) ; prérequis README + à re-vérifier au T2 (§3.3) |

### 5.5 Hors périmètre M0-FIX (rappel)

Wipe multi-disques + checksum SHA512 (B2/B3), métriques/alertes érosion
(P1/O6), apply-config via PN (S2), IAM dédiée (S3), cadence upgrade pool
éteint (O2), chemin DR (O5) : Tier 2 pré-mortem « avant mise en service du
pool », non exigés par la mission — inchangés.
