# karpenter-provider-scaleway

Provider Karpenter pour un **pool fini de serveurs Scaleway Elastic Metal
pré-imagés Talos** : provisionner = power-on (`StartServer`), déprovisionner
= power-off (`StopServer`). Aucun serveur n'est commandé ni détruit.

Spike M0 du design [LLD-002](../docs/design/002-karpenter-scaleway-em.md)
(ADR-024/035/036). **État : squelette compilant + tests unitaires verts —
pas encore validé sur matériel réel** (voir [M0-REPORT.md](M0-REPORT.md)).

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

Sémantiques CloudProvider (LLD §3) :

| Méthode | Comportement |
|---|---|
| `Create` | claim d'un serveur `stopped` (guard anti-course TTL 2 min) → `StartServer` → NodeClaim hydraté (providerID, capacity, labels). Pool vide → `InsufficientCapacityError` |
| `Delete` | power-off idempotent ; serveur absent/`stopped`/`stopping` → `NodeClaimNotFoundError` (le core retire le finalizer) |
| `Get`/`List` | uniquement les serveurs **allumés** (`ready`/`starting`) ; un power-off hors bande fait disparaître le NodeClaim (GC ~2 min) = voulu |
| `GetInstanceTypes` | type statique dérivé de l'offre, toujours retourné ; seul `Available` bouge |
| `IsDrifted` / `RepairPolicies` | opt-out (`""`) / vide en M0 |

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

## Déploiement (dev, hors chart — M1)

1. Créer les CRD karpenter-core (NodePool, NodeClaim…) puis
   `config/crd/karpenter.scaleway.st4ck.io_scalewayemnodeclasses.yaml`.
2. Lancer `cmd/controller` avec les variables d'env standard
   `SCW_ACCESS_KEY` / `SCW_SECRET_KEY` / `SCW_DEFAULT_PROJECT_ID`
   (IAM : `ElasticMetalFullAccess`) + les flags/env operator karpenter
   (`KARPENTER_SERVICE`, etc. — voir doc karpenter-core).
3. Appliquer une `ScalewayEMNodeClass` + un NodePool **statique**
   (`spec.replicas`, `expireAfter: Never`) — exemple dans le LLD §6-§7.

Le scale up/down des replicas du NodePool statique déclenche
Create()/power-on et Delete()/power-off. Rappel coût (ADR-035) : un EM
arrêté reste facturé — le pool donne l'élasticité de capacité, pas
d'économie à l'état éteint.
