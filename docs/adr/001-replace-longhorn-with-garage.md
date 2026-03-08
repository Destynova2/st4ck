# ADR-001 : Remplacement de Longhorn par Garage (stockage objet direct)

**Date** : 2026-03-08
**Statut** : Accepte
**Decideurs** : Equipe plateforme

## Contexte

La stack stockage Phase 1.6 utilisait Longhorn (stockage bloc distribue) comme couche intermediaire pour les PVCs de Garage (stockage objet S3). L'architecture etait :

```
Applications → Velero → Garage S3 → PVCs Longhorn → disques
                        Longhorn BackupTarget → Garage S3
```

Longhorn ajoutait :
- ~20 pods supplementaires (manager, driver, CSI, engine, replica par volume)
- ~1-2 GB RAM d'overhead
- Extensions Talos obligatoires : `iscsi-tools` + `util-linux-tools`
- Patch machine config `/var/lib/longhorn` kubelet mount
- Complexite operationnelle (engine upgrades, replica rebuilds, DRBD)

## Decision

Supprimer Longhorn. Garage utilise directement `local-path` StorageClass pour ses PVCs.

```
Applications → Velero → Garage S3 → PVCs local-path → disques locaux
```

## Consequences

### Positives

- **~20 pods en moins**, ~1-2 GB RAM economise
- **Plus d'extensions Talos iSCSI** necessaires (image plus legere)
- **Plus de patch longhorn-mount** dans les machine configs
- **Moins de surface d'attaque** (pas de iSCSI, pas de engine replicas)
- **Deploiement plus rapide** (Longhorn init ~2-3 min)
- **Complexite operationnelle reduite** significativement

### Negatives

- **Pas de replication bloc** : les PVCs Garage sont sur un seul noeud (local-path)
- **Risque si un noeud tombe** : les donnees Garage sur ce noeud sont perdues localement

### Mitigation

- Garage a un **replication_factor = 3** au niveau applicatif : chaque objet S3 est replique sur 3 pods/noeuds differents
- La perte d'un noeud ne cause **aucune perte de donnees** car les 2 autres replicas sont intacts
- Garage re-replique automatiquement quand le noeud revient ou est remplace

## Composants supprimes

- `configs/longhorn/values.yaml` (peut etre supprime)
- `configs/patches/longhorn-mount.yaml` (peut etre supprime)
- `terraform/stacks/k8s-storage` : namespace longhorn, helm_release longhorn, longhorn_backup_target
- `scripts/garage-setup.sh` : bucket `longhorn-backup`, cle `longhorn-key`, secret `garage-longhorn-secret`
- Patch longhorn dans `terraform/envs/scaleway/main.tf`

## Composants modifies

- `configs/garage/garage.yaml` : storageClassName `longhorn` → `local-path`
- `configs/garage/values.yaml` : storageClass `longhorn` → `local-path`
- `terraform/stacks/k8s-storage/main.tf` : Garage depend de `local_path_provisioner` au lieu de `longhorn`
- `scripts/garage-setup.sh` : seul le bucket `velero-backups` est cree
