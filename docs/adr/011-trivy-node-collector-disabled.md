# ADR-011 : Trivy node-collector desactive sur Talos

**Date** : 2026-03-09
**Statut** : Accepte
**Decideurs** : Equipe plateforme

## Contexte

Trivy Operator inclut un node-collector qui execute des benchmarks CIS sur les noeuds (filesystem, services systemd, configurations). Il deploie un pod DaemonSet qui exec dans le contexte du noeud.

## Probleme

Talos Linux est un OS immutable :
- **Pas de shell** (pas de /bin/sh, pas de bash)
- **Pas de systemd** (init custom Talos)
- **Filesystem read-only** (squashfs)
- Le node-collector crash systematiquement : `exec: "/bin/sh": stat /bin/sh: no such file or directory`

Les options `node.collector.enabled: false` et `compliance.cron.enabled: false` du chart v0.32 ne suffisent pas — le DaemonSet est quand meme cree.

## Decision

Desactiver le node-collector via :
```yaml
operator:
  scanNodeCollectorLimit: 0
compliance:
  specs: []
```

Seule combinaison effective dans le chart v0.32.0 pour empecher la creation du DaemonSet.

## Justification

Talos est **durci par design**, plus strict que CIS :
- Pas de SSH, pas de shell, pas de packages installables
- Filesystem immutable, boot securise
- Controlplanes et workers identiques (meme image squashfs)

Les benchmarks CIS sont redondants et inapplicables. Trivy continue de scanner : images, configs K8s, RBAC, SBOM.
