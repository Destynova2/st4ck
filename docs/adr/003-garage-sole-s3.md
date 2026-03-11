# ADR-003 : Garage comme unique stockage S3 (sans Longhorn, sans SeaweedFS)

**Date** : 2026-03-08
**Statut** : Accepte
**Decideurs** : Equipe plateforme

## Contexte

L'architecture stockage Phase 1.6 envisageait initialement :
- **Longhorn** comme stockage bloc distribue pour les PVCs de Garage
- **SeaweedFS** comme second object store S3 pour des cas d'usage specifiques

L'architecture etait :
```
Applications -> Velero -> Garage S3 -> PVCs Longhorn -> disques
                         Longhorn BackupTarget -> Garage S3
```

## Decision

**Garage seul**, sans Longhorn ni SeaweedFS. Garage utilise directement `local-path` StorageClass pour ses PVCs.

```
Applications -> Velero -> Garage S3 -> PVCs local-path -> disques locaux
```

## Raisons

### Suppression de Longhorn (ADR-002)

Longhorn ajoutait :
- ~20 pods supplementaires (manager, driver, CSI, engine, replica par volume)
- ~1-2 GB RAM d'overhead
- Extensions Talos obligatoires : `iscsi-tools` + `util-linux-tools`
- Patch machine config `/var/lib/longhorn` kubelet mount
- Complexite operationnelle (engine upgrades, replica rebuilds)

Inutile car Garage a un `replication_factor = 3` au niveau applicatif : chaque objet S3 est replique sur 3 pods/noeuds differents. La perte d'un noeud ne cause aucune perte de donnees.

### Suppression de SeaweedFS

- Garage couvre tous les cas d'usage S3 (Velero, Harbor, futurs workloads)
- Pas besoin de 2 object stores : complexite operationnelle inutile
- Garage est leger (~3 pods, ~300 MB RAM), ecrit en Rust, replication factor 3
- Projet francais (Deuxfleurs) — alignement souverainete

## Consequences

### Positives

- **~20 pods en moins**, ~1-2 GB RAM economise (suppression Longhorn)
- **Plus d'extensions Talos iSCSI** necessaires (image plus legere)
- **Un seul point de configuration S3** pour tous les consumers
- **Deploiement plus rapide** (Longhorn init ~2-3 min)
- Garage gere les buckets `velero-backups` et `harbor-registry` via K8s Job (ADR-012)

### Negatives

- **Pas de replication bloc** : les PVCs Garage sont sur un seul noeud (local-path)
- Risque si un noeud tombe : les donnees Garage sur ce noeud sont perdues localement (mais repliquees sur 2 autres noeuds via Garage)
