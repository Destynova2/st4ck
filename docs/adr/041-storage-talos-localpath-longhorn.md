# ADR-041 : Stockage persistant sur Talos — local-path maintenant, Longhorn conditionné aux EM

**Date** : 2026-07-15
**Statut** : Accepté (décision étagée — le 2e étage attend les Elastic Metal)
**Décideurs** : Équipe plateforme
**Reliés à** : ADR-003 (Garage S3), ADR-035/036 (Elastic Metal + Karpenter), ADR-034 (Hauler / air-gap), postmortem local-path 2026-04-29 (chart owner cni)

## Contexte

Le stockage bloc de la plateforme est aujourd'hui `local-path-provisioner`
(stack cni, tofu-owned) : node-local, **sans réplication**. Les statefuls
qui répliquent applicativement (OpenBao raft, Garage rf=3) s'en moquent ;
ceux qui ne répliquent pas (vmsingle, bases identity) perdent leurs
données avec le nœud. Garage couvre l'objet (S3), pas le bloc.

Siderolabs recommande officiellement trois solutions selon l'usage :
Mayastor (ultra-low latency), Longhorn (simple + réplication +
snapshots), Rook/Ceph (échelle enterprise multi-usage). Friction réelle
sur Talos :

| | local-path | Longhorn | Mayastor | Rook/Ceph |
|---|---|---|---|---|
| Extensions système | aucune | `iscsi-tools` + `util-linux-tools` | aucune | aucune |
| machineconfig | mount only | modules + mount + **reboot** | hugepages 2 Gi + CPU dédié + reboot | mount only |
| Réplication | ❌ | ✅ | ✅ | ✅ |
| Poids opérationnel | nul | modéré | élevé | le plus lourd |
| Cible backup | — | **S3 → Garage** | S3 | S3 |

Points spécifiques à notre contexte, établis en session 2026-07-15 :

- Changer d'extensions = **nouveau schematic Factory** → nouvelle image
  immutable (semver + sha7) : mécanique déjà maîtrisée, mais cela impose
  un cycle upgrade des nœuds — testable seulement sur VMs (envs/local ou
  spike virtu Apple Silicon), pas en mode local-docker.
- Le vrai déclencheur est **l'arrivée des workers Elastic Metal NVMe**
  (ADR-035/036) : disques locaux rapides sans CSI provider → Longhorn
  (voire son v2 engine SPDK, qui recoupe les prérequis Mayastor) devient
  la façon d'en faire du stockage répliqué. Sur les VMs cloud actuelles,
  le CSI Scaleway Block Storage serait plus simple mais non portable et
  inutile sur EM — écarté pour ne pas bifurquer l'architecture.

## Décision

1. **Maintenant (dev/POC/VMs cloud)** : local-path reste le défaut.
   Zéro friction, SPOF accepté et documenté ; les données critiques
   passent par la réplication applicative (raft, rf=3) ou par Velero.
2. **À l'arrivée des EM (prod)** : **Longhorn** entre comme StorageClass
   répliquée — extensions `iscsi-tools` + `util-linux-tools` au
   schematic, v1 engine d'abord, backups → bucket Garage (boucle avec
   Velero). Un ADR d'exécution fixera les valeurs (replicas, storage
   over-provisioning, PSA du namespace).
3. **Rejetés à ce stade** : Mayastor (coût hugepages/CPU par nœud
   injustifié avant d'avoir des workloads low-latency identifiés — et le
   v2 engine Longhorn couvrira ce terrain le moment venu) ; Rook/Ceph
   (poids opérationnel d'une équipe stockage, pertinent seulement à une
   échelle multi-tenant que le KaaS n'a pas encore).

## Conséquences

- Personne ne « corrige » local-path en prod par un choix improvisé : le
  chemin est écrit, son déclencheur aussi (EM).
- Le spike virtu VM local (quorum 3 CP, upgrades OS) gagne une
  justification de plus : c'est le banc de test des extensions Longhorn.
- Les images + chart Longhorn entreront au registre de versions et au
  manifest hauler comme le reste (air-gap sans cas particulier).
- vmsingle/identity restent sur local-path d'ici là : la perte acceptée
  est bornée par Velero (schedules) et par le caractère reconstructible
  de ces données en dev.
