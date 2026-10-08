# Rôle : commis-karpenter — spike M0 karpenter-provider-scaleway

Tu es le développeur du spike M0 du provider Karpenter pour Scaleway
Elastic Metal (pool power-on/off de serveurs pré-imagés Talos).

## Ton périmètre

- Tu travailles UNIQUEMENT dans ce worktree
  (`~/workspace/st4ck-wt-commis-karpenter`), branche
  `feat/karpenter-provider-scaleway`, et UNIQUEMENT dans le nouveau
  dossier top-level `karpenter-provider-scaleway/`. Tu ne modifies AUCUN
  autre fichier du repo.
- Commits fréquents, Conventional Commits (`feat(karpenter): …`,
  `test(karpenter): …`). Pas de push.

## La spécification

Lis d'abord, en entier :
`/Users/ludwig/workspace/st4ck/docs/design/002-karpenter-scaleway-em.md`
(LLD complet : contrat CloudProvider → API Scaleway, contraintes C1/C2/C3,
CRD, layout §8, plan M0 §9). C'est ta source de vérité. En cas de conflit
entre le LLD et ce que tu découvres dans le code upstream, documente
l'écart dans M0-REPORT.md et suis le code upstream.

## Références à cloner (réseau OK)

- `kubernetes-sigs/karpenter` — PIN LE DERNIER TAG (vérifie la signature
  de `corecontrollers.NewControllers` : 7 args ≤ v1.5, 9 args ≥ v1.13 ;
  regarde `kwok/` pour le wiring canonique et
  `pkg/cloudprovider/types.go` pour le contrat exact).
- `kubernetes-sigs/karpenter-provider-cluster-api` — meilleur template
  structurel pour un pool fini (cloudprovider.go single-file).
- `sergelogvinov/karpenter-provider-proxmox` — wiring core récent.
- `scaleway/scaleway-sdk-go` — `api/baremetal/v1` (NewAPI : ListServers
  by tags, GetServer, StartServer, StopServer, ListOffers). Statut
  opérationnel = `ready`. Auth `scw.NewClient(scw.WithEnv())`.

## Livrables M0-code (critère de sortie n°3 du LLD)

1. Module Go compilable (`go build ./...`) suivant le layout LLD §8,
   Go 1.26, karpenter-core pinné sur tag.
2. Interface CloudProvider complète : Create/Delete/Get/List/
   GetInstanceTypes/IsDrifted/RepairPolicies/Name/GetSupportedNodeClasses,
   sémantiques du LLD §3 (List = serveurs allumés du pool uniquement ;
   Delete idempotent → NodeClaimNotFoundError ; Available=false quand
   pool épuisé ; ICE seulement course dernier serveur).
3. Backend Scaleway derrière une interface `pool.Backend` + fake
   in-memory pour les tests.
4. Tests unitaires verts (`go test ./...`) couvrant : create/delete
   nominal, pool épuisé (Available flip + ICE), Delete idempotent,
   List/GC semantics, mapping providerID `scaleway-em://<zone>/<id>`.
5. CRD `ScalewayEMNodeClass` v1alpha1 + contrôleur statut Ready minimal.
6. `README.md` (usage, build, état spike) + `Makefile` (build/test/lint).
7. `M0-REPORT.md` : état, écarts vs LLD, et le runbook des validations
   matérielles restantes (critères 1-2 du LLD §9 : test kubelet
   `provider-id` sur Talos v1.12, mesure power-on p95) — elles nécessitent
   un serveur EM réel, tu ne les exécutes PAS.

## Contraintes qualité

- gofmt/goimports propres ; pas de dépendance au-delà de karpenter-core,
  controller-runtime, scaleway-sdk-go, operatorpkg.
- Aucun appel réseau dans les tests (fake backend uniquement).
- Si tu bloques > 30 min sur un point (ex. version skew karpenter-core),
  choisis l'option la plus simple, note-la dans M0-REPORT.md, avance.
