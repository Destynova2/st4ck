# Activer le provider Scaleway hybride en laboratoire

Le code est intégré, mais aucune machine réelle n'a été démarrée pour sa
validation. Ne pas activer directement sur un cluster de production.
Les tests locaux et le rendu Flux ne prouvent pas le fonctionnement de VPA :
la chaîne métriques, recommandation, admission/éviction et modification des
requests reste à démontrer, tout comme les transitions VM ↔ métal avec PDB.

## Propriété et prérequis

1. Terminer le [handoff Flux](../adr/043-flux-platform-ownership.md), y compris
   `make k8s-autoscaling-apply`, avant que Flux adopte les anciennes releases.
   Vérifier qu'aucun autre service ne possède `metrics.k8s.io`.
2. Conserver les nœuds de management fixes. Le contrôleur refuse de se placer
   sur les nœuds portant `karpenter.sh/nodepool`.
3. Drainer les anciennes NodeClaims et désinstaller explicitement tout ancien
   contrôleur AWS/CAPI avant l'installation native. Ne pas faire cohabiter leurs
   CRD/core différents. Les blocs `removed` ne désinstallent rien.
4. Choisir un projet IAM dédié, une zone, un Private Network joignable par les
   control planes, un security group autorisant API/CNI/DNS et une sortie réseau
   vers les registres et métadonnées Scaleway. Les VM n'ont pas d'IP publique.
5. Importer une image Talos **Scaleway** privée, avec disque racine local SSD,
   de la bonne architecture. Le provider exige un UUID, pas un alias marketplace.
   Vérifier les contraintes de disques sur chaque type VM autorisé.
6. Préparer séparément le stock EM Talos x86, son accès réseau et le providerID
   `scaleway-em://ZONE/UUID` à l'aide du module existant, avec
   `karpenter_pool_enabled=true` et `kubelet_provider_id_enabled=true` pour
   les nouvelles installations. Le mode EM refuse les configurations non-worker,
   les documents YAML multiples et les overrides incompatibles. Ne pas réappliquer
   aveuglément `em-talos-bootstrap` à une machine déjà installée : un changement
   de trigger peut rejouer son provisionnement destructif en rescue.
7. Le bootstrap VM et le mode Karpenter du module EM injectent le taint initial
   `karpenter.sh/unregistered:NoExecute`, sans écraser les autres taints ; les
   conflits sont refusés. Vérifier sa présence dès l'enregistrement.
   Le core le retire après synchronisation des
   labels, taints et finalizers ; sans lui, les pods non sélectionnés peuvent
   entrer sur le nœud avant sa prise en charge. Ce point bloque l'activation
   tant que sa présence et son retrait sur Talos n'ont pas été éprouvés.

## Secrets

Alimenter OpenBao Infra via le parcours sécurisé de bootstrap existant :

| Chemin KV | Propriétés attendues |
|---|---|
| `autoscaling/scaleway` | `access_key`, `secret_key`, `project_id` de l'application IAM dédiée |
| `autoscaling/talos-worker` | `machineconfig` worker complet du cluster cible |

Ne pas exporter ces valeurs dans Git, les logs ou une ligne de commande.
Les ExternalSecrets optionnels produisent `karpenter-scaleway-credentials`
et `karpenter-talos-worker` dans `autoscaling`.

Le bootstrap doit être un modèle générique : pas de hostname/IP propres à
un worker existant. Conserver les patches Cilium/Talos, la sélection d'IP VPC,
et le VolumeConfig EPHEMERAL pour le second disque. Les documents YAML
additionnels sont préservés côté VM. Le provider compare seulement le nom du
cluster : vérifier séparément l'endpoint et les CA du Secret avec le cluster
cible de confiance. Ce contrôle de nom n'est pas une preuve d'identité.
Le provider injecte son providerID et une réserve
kubelet de 500m CPU/1Gi mémoire, `maxPods=110` et les seuils d'éviction explicites
(`memory.available=100Mi`, nodefs 10 %, imagefs 15 %, inodes libres 5 %).
Il déduit 1Gi + 100Mi de la mémoire catalogue pour VM et EM. Les réserves différentes,
`systemReserved`, `reservedSystemCPUs`, `podsPerCore` non nul et les flags
kubelet qui contournent ces réglages sont refusés, comme les seuils d'éviction
différents et les évictions soft non modélisées. Le mode EM impose le même
contrat, vérifié par un fixture commun aux tests Go/OpenTofu. Migrer les machines
déjà installées via un changement de configuration non destructif après drainage,
jamais par le module d'imaging. Comparer les capacités annoncées avec
`Node.status.allocatable` : la mémoire catalogue n'est pas une mesure de la RAM
réellement utilisable par Talos. Le stockage éphémère n'est pas annoncé au scheduler.

## Construire et raccorder Flux

Depuis `karpenter-provider-scaleway`, exécuter `make test lint` et construire
le Dockerfile pour `linux/amd64,linux/arm64` avec le moteur OCI habituel.
Publier un manifest multiarchitecture identifié par un tag immuable dans le
registre interne. La CI compile les deux architectures mais ne publie pas
d'image automatiquement. Signer/stager l'image pour la politique du cluster.

Le dossier `stacks/autoscaling/flux-provider` est volontairement absent de
`clusters/management`. Ajouter une Kustomization Flux dédiée dépendant de
`autoscaling`, avec `wait: true`, après avoir configuré le HelmRelease :

```yaml
spec:
  suspend: false
  values:
    controller:
      enabled: true
    image:
      repository: zot.example.internal/platform/karpenter-scaleway
      tag: build-validated-in-lab
    clusterID: unique-stable-lab-id
    talosClusterName: actual-talos-cluster-name
    credentialsSecret: karpenter-scaleway-credentials
    bootstrapSecrets: [karpenter-talos-worker]
```

Garder les NodeClasses et NodePools dans une **seconde** Kustomization,
dépendante du contrôleur Ready : leurs CRD doivent exister avant le dry-run
Flux. Les secrets restent fournis par ESO, pas par les values Helm.

## Déclarer la capacité

Exemple de NodeClass VM, à renseigner avec les UUID réellement validés :

```yaml
apiVersion: karpenter.scaleway.st4ck.io/v1alpha1
kind: ScalewayVMNodeClass
metadata:
  name: workers-vm
spec:
  zone: fr-par-2
  projectID: YOUR-PROJECT-UUID
  imageID: YOUR-LOCAL-SSD-IMAGE-UUID
  privateNetworkID: YOUR-NETWORK-UUID
  securityGroupID: YOUR-SECURITY-GROUP-UUID
  bootstrapSecret: karpenter-talos-worker
  instanceTypes: [DEV1-M, DEV1-L]
  architecture: amd64
  ephemeralDiskGiB: 20
```

La NodeClass métal porte `zone`, `poolTag`, `offerName`. Utiliser un tag exclusif
à ce cluster, ne jamais inclure les control planes ou les workers fixes.
Les paramètres des NodeClasses sont immuables : créer une nouvelle classe
pour les changer, puis drainer l'ancienne avant de la supprimer.
Le champ EM `status.stopped` remplace l'ancien `status.available` expérimental :
il compte les serveurs arrêtés de l'offre demandée, réservations comprises.
Ce n'est pas un quota libre ; le scheduler filtre séparément les Leases.
Mettre à jour les consommateurs de statut avec les CRD du chart.

Adapter les limites de [hybrid-nodepools.yaml](../../karpenter-provider-scaleway/examples/hybrid-nodepools.yaml)
à l'inventaire réel. Les deux pools sont dynamiques, avec budgets de disruption
et sans expiration forcée. Le poids VM favorise son usage lorsque la demande
tient ; il ne garantit pas un arbitrage économique global.

Pour un Deployment de test à au moins deux répliques, ajouter au pod template :

```yaml
spec:
  nodeSelector:
    st4ck.io/capacity: elastic
  tolerations:
    - key: st4ck.io/elastic
      operator: Equal
      value: "true"
      effect: NoSchedule
```

Le sélecteur du PDB d'exemple est `app: elastic-app` : poser ce label sur
les pods réels, vérifier `currentHealthy`/`disruptionsAllowed`, configurer leurs
probes et leur répartition entre nœuds. Deux répliques seules ne prouvent ni
que le PDB les sélectionne ni qu'elles survivent à la perte d'un nœud.

Adapter [workload.yaml](../../karpenter-provider-scaleway/examples/workload.yaml)
pour VPA/PDB. `Recreate` permet à une nouvelle recommandation de provoquer une
replanification ; ce mode peut évincer des pods. Ajuster aussi leurs limits,
car `RequestsOnly` ne les augmente pas. Ne pas coupler à un HPA CPU/mémoire
sur les mêmes ressources. KEDA peut piloter des répliques sur une file/message.

## Critères de recette

- `kubectl top pods -A` et `kubectl top nodes` retournent des données cohérentes ;
  vérifier les labels node/namespace/pod/container dans VictoriaMetrics.
- Sur une charge contrôlée, observer une recommandation VPA, les nouvelles
  requests admises sur les pods et une éviction acceptée/refusée selon le PDB.
  Conserver les observations horodatées ; un rendu Helm ou une APIService Ready
  ne valide pas ce parcours fonctionnel.
- Un pod opt-in Pending crée une VM, joint Talos puis devient Ready sans CCM
  externe nécessaire au providerID. Vérifier CNI, DNS, stockage et accès API.
- Une demande trop grande pour l'allowlist VM allume le bon EM. Mesurer cinq
  démarrages et rester sous le registration timeout Karpenter.
- Une baisse de requests permet une consolidation compatible. Karpenter attend
  les NodeClaims de remplacement `Initialized`, puis déclenche le drainage ;
  il ne précrée pas tous les pods applicatifs avant la première éviction.
  Observer le minimum de répliques Ready et l'absence d'interruption pendant
  les deux sens VM → EM et EM → VM, PDB et contraintes zonales compris.
- Redémarrer le contrôleur pendant une création/transition ; vérifier une seule
  réservation, une seule machine, puis deux réutilisations du même EM.
- Un échec de boot, une indisponibilité API et un PDB bloquant ne détruisent pas
  la capacité servant encore les répliques. Aucun stockage local à déplacer.

Ces points sont des critères à exécuter, pas des résultats acquis. La suite
Go utilise des clients simulés, et son test de finalisation nominale n'exerce
pas un vrai drainage de pods protégé par PDB.

## Reprise et arrêt

Les Leases `scw-*` du namespace `autoscaling` sont des **données d'exploitation**,
à sauvegarder. Ne pas les effacer, ne pas partager un pool EM entre clusters.
Une création dont le résultat est inconnu reste bloquée volontairement :
inspecter la Lease, le NodeClaim, les tags Scaleway et les opérations en cours.
Le finalizer `karpenter.scaleway.st4ck.io/termination` conserve les demandes
partielles, même sans `status.providerID`. Ne pas l'arracher pour débloquer une
suppression : le contrôleur le retire après confirmation du nettoyage cloud.
Les réservations orphelines créées avant ce correctif ne sont pas adoptées ni
effacées automatiquement. Les inventorier et les réconcilier manuellement,
avec preuve d'identité et d'état de chaque machine avant toute libération.
Une intervention manuelle n'est possible qu'après preuve d'absence de VM ou
d'arrêt final du serveur, sans requête de création/power-on encore en vol.

Pour démonter : suspendre la réconciliation des manifestes de capacité,
arrêter les producteurs de charge, empêcher de nouvelles allocations,
drainer les NodePools,
attendre la fin des NodeClaims et des opérations Scaleway, puis désactiver
le provider. Ne pas supprimer son namespace/CRD/contrôleur en premier.
`flux-down.sh` refuse désormais de poursuivre tant qu'une Lease étiquetée
`karpenter.scaleway.st4ck.io/reservation=true` existe, même sans NodeClaim.
Ne pas activer `make k8s-down` sur cette extension tant que ces vérifications
ne sont pas faites. Le script ordonne seulement les 16 enfants maintenus du
graphe de base ; les Kustomizations ajoutées pour le provider et ses pools
doivent être retirées explicitement, feuilles avant contrôleur, avant ce script.
Son contrôle d'absence de Leases/NodeClaims est un instantané, pas un verrou
contre une création concurrente. Le préflight refuse donc tout Deployment natif
encore armé ou pod natif actif dans `autoscaling`, ainsi que toute Kustomization
hors du graphe de base dans `flux-system`, avant mutation. Désarmer l'allocation,
supprimer ou suspendre la release Helm native pour éviter son réarmement,
arrêter ses pods et retirer les graphes optionnels relève de l'opérateur :
le script ne réduit aucun contrôleur automatiquement. Il relit les réservations
et NodeClaims après suspension du root, avant la première suppression. Ne pas
réactiver de producteur concurrent pendant l'arrêt. L'arrêt d'un EM ne met pas
fin à sa facturation.

La politique métier « 2 h de charge soutenue puis métal » reste hors de ce lot ;
les délais de consolidation ne réalisent pas cette mesure. Voir [ADR-044](../adr/044-scaleway-vm-metal-rules.md).
