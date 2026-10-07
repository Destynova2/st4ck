# ADR-044 : Autoscaling natif Scaleway VM et Elastic Metal

**Date** : 2026-09-23
**Statut** : Implémentation expérimentale intégrée ; activation matérielle suspendue
**Précise** : ADR-024, ADR-035, ADR-036, LLD-002

## Décision

Reprendre `feat/karpenter-provider-scaleway@ca2e411`, conserver son backend EM
et lui ajouter un backend Instances dans **un seul contrôleur Karpenter**.
Les charts VPA, KEDA et Prometheus Adapter de `feat/kamaji-karpenter` sont repris
sélectivement sous Flux. Aucun chart AWS ni contrôleur CAPI n'est installé par
ce parcours. Les anciennes releases sont conservées, pas désinstallées, par
les blocs Tofu `removed { lifecycle { destroy = false } }`.

La chaîne retenue est : métriques CPU/mémoire → VPA → requests des pods →
scheduling Karpenter → capacité VM ou métal. KEDA reste disponible pour les
signaux applicatifs ; il ne doit pas concurrencer VPA sur les mêmes ressources.
Il s'agit de remplacement/replanification, pas de migration mémoire à chaud.

Flux possède les services et leur configuration. OpenTofu possède les images,
réseaux, IAM, machines fixes et le stock EM préparé. Le provider possède les
VM qu'il crée et l'état électrique des EM réservés, jamais leur achat ou leur
réinstallation. Les serveurs créés par Tofu/CAPI ne sont pas adoptés implicitement.

## Ce qui est intégré

- `ScalewayEMNodeClass` : pool fini, préinstallé Talos, amd64 ; allumer/éteindre.
- `ScalewayVMNodeClass` : UUID d'image privée, projet, zone, réseau privé,
  security group, allowlist de tailles, architecture et disque local EPHEMERAL.
- Catalogue VM CPU/RAM/prix/disponibilité depuis le SDK Scaleway ; choix du
  moins cher parmi les types compatibles avec les requests et requirements.
- Bootstrap worker uniquement, nom du cluster Talos vérifié (pas les CA ni
  l'endpoint), providerID et taint initial de quarantaine injectés,
  documents Talos additionnels conservés ; Secret lu dans le namespace du
  contrôleur. Les identifiants et le bootstrap peuvent être synchronisés par ESO.
- Réservations Kubernetes Lease persistantes, sans expiration ni garbage
  collection automatique : association UID NodeClaim/serveur, reprise après
  redémarrage, refus de suppression par un ancien propriétaire.
- Intentions VM enregistrées avant POST. En cas de timeout, récupération par
  tags projet/cluster/UID ; aucune seconde création tant que l'issue est inconnue.
- Finalizer fournisseur posé avant la création externe ; un contrôleur dédié
  reprend la terminaison des NodeClaims supprimés sans providerID. L'issue
  inconnue conserve le NodeClaim et sa réservation pour diagnostic. Les refus
  définitifs d'allumage EM libèrent le candidat après confirmation de son état
  arrêté et permettent d'essayer le suivant.
- Chart local, CRD core 1.14.0, RBAC, image multiarchitecture à construire,
  affinité du contrôleur hors des nœuds qu'il peut retirer.

Prometheus Adapter possède `metrics.k8s.io` et `custom.metrics.k8s.io` ; KEDA
possède `external.metrics.k8s.io`. L'adapter utilise `vmsingle-vm:8428`, sans
préfixe `/prometheus`. Ne pas ajouter un second metrics-server sur cette API.
La version VPA historique `9.10.0` n'existe pas dans le dépôt du chart ; le
registre utilise le chart publié `11.1.1`.

## Règles d'activation

| Règle | Contrat |
|---|---|
| Admission | Workloads opt-in, label et taint communs aux pools VM/EM ; aucun pool publié par défaut |
| Éligibilité | Stateless, au moins deux répliques, probes, PDB, requests et limites VPA bornées |
| Stockage | Aucun PVC local-path, local PV ou hostPath ; pas de migration implicite des données |
| Capacité | Allowlist de types VM, limites CPU/mémoire par pool, stock EM disjoint par cluster |
| Drainage | Boucle native Karpenter, budgets de disruption, pas de force-delete ni durée forçant la terminaison |
| Stabilisation | `consolidateAfter` et budgets bornent la consolidation ; ils ne mesurent pas deux heures de charge CPU |
| Secret | Worker du même cluster, IAM dédié limité au projet, pas de kubeconfig admin inter-tenant |
| VM | Image et disques locaux uniquement ; refus de destruction automatique en présence de SBS |
| Métal | Une réservation vit jusqu'à arrêt confirmé ; jamais de suppression physique ou réinstallation automatique |
| Ambiguïté API | Arrêt de la progression et alerte opérateur, pas de libération par simple timeout |

VM par défaut via un poids supérieur dans les exemples ; métal disponible
pour une demande qui ne tient pas dans les tailles VM autorisées. Les poids
ne constituent ni un plafond de dépenses ni un moteur d'arbitrage économique.
La consolidation native peut remplacer une capacité par une autre compatible
et moins chère, mais la convergence VM ↔ EM doit être prouvée en recette.

Un EM éteint reste réservé/facturé. Le catalogue donne un prix nominal, pas
le coût marginal du stock déjà payé. La politique historique « charge soutenue
2 h, retour après 30 min » n'est **pas implémentée** par ce lot ; un pilote
de politique supplémentaire ne se justifie qu'après mesure du comportement
natif. Il ne faut pas le simuler par `weight` ou `consolidateAfter`.

## Limites bloquant la production

1. Aucun cycle Scaleway réel n'a été exécuté : réseau privé, image, Talos
   providerID VM, durée de boot et réutilisation EM restent à valider.
2. Deux cycles EM join/drain/arrêt/reprise doivent prouver les identités,
   certificats kubelet, état CNI et l'absence de données locales résiduelles.
3. Une intention enregistrée juste avant un crash mais jamais envoyée peut
   rester bloquée. Une récupération manuelle contrôlée est nécessaire ;
   cette version privilégie l'absence de doubles allocations à la disponibilité.
4. Le catalogue EM reste amd64 ; les CPU non identifiés Intel/AMD sont refusés.
   Réserve kubelet : 500m CPU / 1Gi mémoire, plus 100Mi d'éviction mémoire.
   Le mode `karpenter_pool_enabled=true` du module EM impose le même contrat
   que VM ; migrer les installations existantes sans rejouer l'imaging destructif.
5. Les comptes/API et le dimensionnement disque VM doivent être éprouvés
   sur chaque type autorisé. Pas de GPU, spot, SBS, adoption ni redimensionnement
   en place. Les limites NodePool sont éventuellement cohérentes, pas un quota financier dur.
6. Le contrôleur observe son cluster Kubernetes local. KaaS multi-tenant,
   Cilium Gateway et gestionnaire LB ne sont pas complétés par cette intégration.
7. Aucun test fonctionnel VPA n'est établi par cette revue : ni une release
   Ready, ni le rendu des requêtes de l'adapter, ni les tests Go ne prouvent
   la chaîne métriques → recommandation → admission/éviction → requests modifiées.
   La transition VM ↔ EM avec maintien du service et PDB reste à démontrer.
8. Le bootstrap VM et le module EM opt-in injectent le taint initial
   `karpenter.sh/unregistered:NoExecute` attendu par le core 1.14.0 et refusent
   les conflits. Le provider ne lit pas la configuration déjà installée des EM.
   Vérifier cette protection avant toute activation : sans elle, des pods
   sans sélection de pool peuvent être planifiés avant la synchronisation des
   taints/finalizers Karpenter. Aucun test réel ne prouve cette isolation.
9. Le bootstrap VM refuse les overrides de réserves et de capacité pods non
   modélisés (`systemReserved`, `reservedSystemCPUs`, `podsPerCore` et leurs
   flags), impose `maxPods=110` et des seuils d'éviction explicites. Les 100Mi
   d'éviction mémoire sont déduits de l'allocatable VM et EM ; les overrides
   non modélisés sont refusés. La RAM réellement utilisable reste à comparer
   au `Node.status.allocatable` Talos : le catalogue n'est pas une mesure matérielle.

## Recette

Voir [le guide d'activation](../how-to/scaleway-autoscaling.md). Les tests locaux
couvrent concurrence, redémarrages, ancien Delete, réponses API ambiguës,
choix de taille, bootstrap, finalisation avec le core épinglé et requêtes SDK
sur serveur HTTP simulé. Les tests historiques ciblent le constructeur durable ;
l'ancien cycle de réservations en mémoire a été retiré. Ils ne
remplacent pas la recette avec pods et machines réels. Le core attend les
NodeClaims de remplacement `Initialized` avant de supprimer les candidats,
puis draine via l'API d'éviction ; il n'attend pas que tous les pods de
remplacement soient Ready avant la première éviction. Le PDB doit sélectionner
les vrais pods, et leur readiness doit être observée pendant toute la transition.

## Sources

- [NodePools et limites](https://karpenter.sh/docs/concepts/nodepools/)
- [Drainage et consolidation](https://karpenter.sh/docs/concepts/disruption/)
- [API Instances v1](https://www.scaleway.com/en/developers/api/instance/v1)
- [Chart VPA publié](https://github.com/cowboysysop/charts/tree/master/charts/vertical-pod-autoscaler)
