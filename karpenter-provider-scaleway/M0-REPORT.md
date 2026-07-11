# M0-REPORT — spike karpenter-provider-scaleway

**Date** : 2026-07-12
**Réf.** : LLD-002 (`docs/design/002-karpenter-scaleway-em.md`), plan §9.
**État global** : critère de sortie n°3 (squelette compilant + fake + tests)
**atteint**. Critères n°1, 2 et 4 (validations matérielles / bout en bout)
**non exécutés** — ils exigent un serveur EM réel ; runbook ci-dessous.

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
   `Delete` du core observe `stopping` → `NodeClaimNotFoundError` au retour
   suivant, comportement équivalent au poll. Aligné sur kwok/cluster-api
   (aucun provider upstream ne poll dans Create).
2. **`stopping` et `error` traités comme éteints** (`PoweredOn()` =
   `ready`|`starting`) pour Get/Delete/List. Un serveur en `error` disparaît
   de List() → NodeClaim GC → reschedule. Le LLD ne tranchait que
   `ready→stopping→stopped`.
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
