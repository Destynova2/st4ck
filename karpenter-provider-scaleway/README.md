# karpenter-provider-scaleway

Provider Karpenter pour un **pool fini de serveurs Scaleway Elastic Metal
pré-imagés Talos** : provisionner = power-on (`StartServer`), déprovisionner
= power-off (`StopServer`). Aucun serveur n'est commandé ni détruit.

Spike M0 du design [LLD-002](../docs/design/002-karpenter-scaleway-em.md)
(ADR-024/035/036), durci par la passe de revue M0-FIX (Codex + audit-code
+ x-ray + pré-mortem). **État : squelette compilant + 57 tests unitaires
verts (CI Woodpecker) — pas encore validé sur matériel réel** (voir
[M0-REPORT.md](M0-REPORT.md)).

## Modèle

- Le **pool** est l'ensemble des serveurs EM d'une zone portant un tag dédié
  (ex. `st4ck.io/karpenter-pool=metal`), pré-imagés par
  `modules/em-talos-bootstrap` (machineconfig worker appliqué, PN + IP
  persistants aux power cycles).
- `ScalewayEMNodeClass` (CRD cluster-scoped) décrit un pool :
  `zone` + `poolTag` + `offerName`. Son contrôleur publie `poolSize`,
  `available` (serveurs `stopped` démarrables) et la condition `Ready`.
- Le scheduler ne voit qu'**un instance type par pool** (l'offre, ex.
  `EM-A116X-SSD`) avec une offering à prix flat dont `Available` passe à
  `false` dès que le pool n'a plus de serveur `stopped` (contrainte C2 du
  LLD : pas de cache ICE dans le core).
- `providerID` : `scaleway-em://<zone>/<server-id>` — posé côté nœud par le
  kubelet Talos (`kubelet.extraArgs.provider-id`, Option A du LLD, à valider
  sur matériel).

Sémantiques CloudProvider (LLD §3, durcies par la revue M0-FIX) :

| Méthode | Comportement |
|---|---|
| `Create` | claim d'un serveur `stopped` lié au **UID du NodeClaim** (un retry reprend son propre claim ; un claim démarré ne se libère jamais tant que l'API dit `stopped`) → `StartServer` (échec désambiguïsé par relecture) → NodeClaim hydraté. Pool épuisé → `InsufficientCapacityError` ; NodeClass absente/`Ready=False` → `NodeClassNotReadyError` |
| `Delete` | contrat core respecté : `nil` tant que `stopping`/transitoire (le core retry), `NodeClaimNotFoundError` **uniquement** sur `stopped` ou serveur absent, erreur explicite sur `locked`/`out_of_stock`/`error` (fail-closed). Garde d'appartenance : jamais de `StopServer` sur un serveur sans tag de pool déclaré |
| `Get`/`List` | tout sauf `stopped` est visible (fail-closed : un statut bizarre ne fait jamais croire au GC que l'instance a disparu) ; un power-off hors bande (→ `stopped`) fait disparaître le NodeClaim (GC ~2 min) = voulu |
| `GetInstanceTypes` | type statique dérivé de l'offre, toujours retourné ; seul `Available` bouge (`stopped` > 0) |
| `IsDrifted` / `RepairPolicies` | opt-out (`""`) / vide en M0 |

Les 13 statuts du SDK sont classés en 6 familles (`startable`/`live`/
`terminating`/`transient`/`blocked`/`failed`) dans `pkg/pool` — tout statut
inconnu du provider est `failed`, jamais « disparu ».

## Build & test

```bash
make build   # go build ./...
make test    # go test ./... — fake backend in-memory, zéro réseau
make lint    # gofmt + go vet (+ golangci-lint si présent)
```

Versions : Go 1.26, karpenter-core **v1.14.0** (signature `NewControllers`
9 args vérifiée), scaleway-sdk-go v1.0.0-beta.36, controller-runtime v0.23.

## Layout

```
cmd/controller/main.go        # wiring operator karpenter-core (kwok-style)
pkg/apis/v1alpha1/            # ScalewayEMNodeClass + deepcopy
pkg/cloudprovider/            # implémentation CloudProvider
pkg/pool/                     # Backend (Scaleway réel + fake), inventaire TTL, providerID
pkg/controllers/nodeclass/    # statut Ready + poolSize/available
config/crd/                   # CRD ScalewayEMNodeClass
```

## Prérequis de déploiement

1. **CRDs `karpenter.sh` ≥ core v1.14** sur le cluster. Le champ
   `NodePool.spec.replicas` (NodePool statique) n'existe que dans le schéma
   CRD récent — la stack `autoscaling/` pinne aujourd'hui le chart karpenter
   **1.3.3** (core v1.3), dont les CRDs sont trop vieilles : monter le chart
   (ou installer les CRDs v1.14) AVANT de déployer ce provider sur le même
   cluster.
2. **Feature gate `StaticCapacity=true`** sur le contrôleur : dans core
   v1.14.0, `spec.replicas` est un champ **alpha** derrière le feature gate
   `StaticCapacity`, désactivé par défaut. Sans lui, les replicas sont
   ignorés (mode de défaillance P7 du pré-mortem). Le passer via l'env
   `FEATURE_GATES=StaticCapacity=true` ou `--feature-gates`.
3. **Une seule réplique active** du contrôleur (leader election, comme le
   déploiement karpenter standard) : le claim guard anti-double-power-on est
   process-local.
4. **Cohabitation avec d'autres karpenter-core** (stack `autoscaling` :
   core + provider cluster-api) : core v1.14 partitionne NodeClaims et
   NodePools par GroupKind de NodeClass (`IsManaged`) — pas de destruction
   croisée par design. Le vrai prérequis est le point 1 (CRDs partagées,
   version alignée) ; garder des pools de pods disjoints (taint metal) pour
   éviter la double réaction aux Pending.

## Déploiement (dev, hors chart — M1)

1. Créer les CRD karpenter-core (NodePool, NodeClaim…) puis
   `config/crd/karpenter.scaleway.st4ck.io_scalewayemnodeclasses.yaml`.
2. Lancer `cmd/controller` avec les variables d'env standard
   `SCW_ACCESS_KEY` / `SCW_SECRET_KEY` / `SCW_DEFAULT_PROJECT_ID`
   (IAM : `ElasticMetalFullAccess`) + les flags/env operator karpenter
   (`KARPENTER_SERVICE`, `FEATURE_GATES=StaticCapacity=true`, etc.).
3. Appliquer une `ScalewayEMNodeClass` + un NodePool **statique**
   (`spec.replicas`, `expireAfter: Never`) — exemple dans le LLD §6-§7.
4. Pré-imager les serveurs du pool avec `modules/em-talos-bootstrap`
   (`kubelet_provider_id_enabled=true` par défaut) : le module injecte
   `machine.kubelet.extraArgs.provider-id` avec exactement la chaîne que ce
   provider dérive (`scaleway-em://<zone>/<server-id>`).

Le scale up/down des replicas du NodePool statique déclenche
Create()/power-on et Delete()/power-off. Rappel coût (ADR-035) : un EM
arrêté reste facturé — le pool donne l'élasticité de capacité, pas
d'économie à l'état éteint.
