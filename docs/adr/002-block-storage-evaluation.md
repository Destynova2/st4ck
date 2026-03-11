# ADR-002 : Evaluation stockage bloc distribue — aucun retenu

**Date** : 2026-03-08
**Statut** : Accepte
**Decideurs** : Equipe plateforme

## Contexte

La Phase 1.6 (Stockage) necessitait un choix de stockage pour les PVCs du cluster. Quatre solutions de stockage bloc distribue ont ete evaluees sur le cluster Talos (3 CP + 3 workers, DEV1-M Scaleway).

## Candidats evalues

### Rook-Ceph (minimal)

| Critere | Valeur |
|---|---|
| Pods | ~30 (mon, mgr, osd x3, mds, CSI) |
| RAM | ~3-4 GB minimum |
| Complexite | Elevee (BlueStore, PG, CRUSH maps) |
| Talos compat | Bug `parse_env` Squid 19.2.3, necessite workaround |
| Features | Block (RBD), File (CephFS RWX), Object (RGW) |

**Verdict** : trop lourd pour 6 noeuds. Le bug Squid + la complexite operationnelle (PG rebalancing, OSD recovery) ne justifient pas le deploy sur un cluster de cette taille. Pertinent si besoin CephFS (ReadWriteMany) en Gate 3.

### Piraeus / LINSTOR (DRBD)

| Critere | Valeur |
|---|---|
| Pods | ~17 (controller, CSI, satellite x6) |
| RAM | ~1-1.5 GB |
| Complexite | Moyenne (module kernel DRBD) |
| Talos compat | Extension DRBD dispo (Talos Factory schematic) |
| Features | Block uniquement, replication synchrone |

**Verdict** : performant (replication kernel DRBD, latence ~0.1ms), mais module kernel DRBD = risque de compatibilite aux upgrades Talos. L'extension est disponible mais ajoute un couplage fort avec la version kernel.

### Longhorn

| Critere | Valeur |
|---|---|
| Pods | ~20 (manager, driver, engine, replica par volume) |
| RAM | ~1-2 GB |
| Complexite | Moyenne (engine replicas, iSCSI) |
| Talos compat | Extensions `iscsi-tools` + `util-linux-tools` + patch kubelet mount |
| Features | Block, backup S3, snapshots |

**Verdict** : fonctionne sur Talos mais necessite 2 extensions + patch machine config. Overhead inutile si Garage replique deja au niveau applicatif (voir ADR-003).

### Aucun (local-path + replication applicative)

| Critere | Valeur |
|---|---|
| Pods | 1 (local-path-provisioner) |
| RAM | ~10 MB |
| Complexite | Nulle |
| Talos compat | Natif, zero extension |
| Features | Block local uniquement, pas de replication |

## Decision

**Aucun stockage bloc distribue.** `local-path-provisioner` comme StorageClass par defaut.

La replication est assuree au niveau applicatif :
- **Garage** : `replication_factor = 3` (chaque objet S3 sur 3 noeuds)
- **etcd** : replication Raft integree (3 CP)
- **PostgreSQL** (Gate 2) : replication CloudNativePG (3 replicas)

## Matrice de decision

```
                    Rook-Ceph   Piraeus   Longhorn   local-path
Pods                ~30         ~17       ~20        1
RAM overhead        ~3-4 GB     ~1-1.5 GB ~1-2 GB    ~10 MB
Extensions Talos    non*        DRBD      iSCSI x2   aucune
Complexite ops      *****       ***       ***        *
Replication bloc    oui         oui       oui        non
RWX (CephFS)        oui         non       non        non
Compat Talos        bug Squid   ok+ext    ok+ext     natif
```

\* Rook-Ceph n'a pas d'extension Talos specifique mais necessite un workaround pour le bug parse_env.

## Consequences

- ~20-30 pods et ~1-4 GB RAM economises
- Zero extension kernel supplementaire (image Talos plus legere, upgrades plus surs)
- Zero complexite stockage distribue a operer
- **Tradeoff** : pas de ReadWriteMany (CephFS). Si besoin RWX en Gate 3, reconsiderer Rook-Ceph minimal.

## Reconsiderer si

- Besoin ReadWriteMany (CephFS) pour workloads Gate 3
- Workload stateful qui ne replique pas au niveau applicatif
- Cluster >20 noeuds ou le stockage distribue se justifie
