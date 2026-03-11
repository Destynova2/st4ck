# ADR-018 : Tetragon au lieu de Falco (runtime security eBPF)

**Date** : 2026-03-11
**Statut** : Accepte
**Decideurs** : Equipe plateforme

## Contexte

Choix du composant runtime security pour la detection de menaces sur le cluster Talos. Deux candidats eBPF evalues : Falco (Sysdig, CNCF Incubating) et Tetragon (Isovalent, projet Cilium).

## Comparaison

| Critere | Falco | Tetragon |
|---|---|---|
| Origine | Sysdig -> CNCF Incubating | Isovalent -> Cilium project |
| Moteur | syscall hooks (eBPF ou module kernel) | eBPF natif, kernel-level |
| Integration Cilium | aucune native | native — meme stack eBPF |
| Integration Talos | fonctionne (extension system) | fonctionne (eBPF natif) |
| Visibilite reseau | limitee | L3/L4/L7 + process + fichiers |
| Enforcement | detection uniquement | detection + blocage temps reel |
| RBAC/identity aware | non | oui — K8s workload identity |
| Perf overhead | moyen (double eBPF si Cilium aussi) | minimal (un seul plan eBPF) |
| Maturite | tres haute, 8 ans | haute, 3 ans en prod |
| Regles | Falco rules YAML (large communaute) | TracingPolicy YAML (plus verbeux) |
| Output | JSON vers SIEM/Loki | JSON + Hubble integration |
| Airgap | oui | oui |

## Decision

**Tetragon.** L'integration native avec Cilium (ADR-001) est le point decisif.

## Justification

### Un seul plan eBPF

Falco + Cilium = deux agents eBPF separes dans le kernel -> overhead double, pas de correlation native entre reseau et runtime.

Tetragon + Cilium = un seul plan eBPF -> correlation process/reseau/fichiers dans un seul evenement, Hubble UI integre les deux.

**Exemple concret** : un process fait un `connect()` vers une IP suspecte. Avec Tetragon + Cilium, un seul evenement contient : quel pod, quel process, quel user, quelle syscall, quelle IP, quelle NetworkPolicy a laisse passer. Avec Falco, il faut correler manuellement deux flux de logs.

### Enforcement temps reel

Falco detecte et alerte. Tetragon detecte **et bloque** (kill process, deny syscall) via TracingPolicy. En contexte defense, l'enforcement est un avantage significatif.

### Coherence architecturale

La stack est full Cilium (CNI, kube-proxy replacement, mTLS, NetworkPolicy L7, Hubble). Tetragon est le composant runtime security natif de cet ecosysteme.

## Configuration Talos

```yaml
# Talos v1.12+ necessite le mount tracefs pour Tetragon
extraHostPathMounts:
  - name: sys-kernel-tracing
    mountPath: /sys/kernel/tracing
    hostPath: /sys/kernel/tracing
    readOnly: true
```

## Consequences

### Positives

- Un seul plan eBPF (Cilium + Tetragon), overhead minimal
- Correlation native process/reseau/fichiers
- Enforcement temps reel (pas juste detection)
- Hubble UI integre runtime + network observability
- Pas de module kernel supplementaire

### Negatives

- Base de regles plus petite que Falco (communaute plus jeune)
- TracingPolicy plus verbeux que Falco rules
- Maturite moindre (3 ans vs 8 ans)

## Reconsiderer Falco si

- Contrainte reglementaire specifique exigeant Falco (certification, audit)
- Besoin de regles pre-faites CIS/NIST/PCI-DSS sans effort de portage
- Integration SIEM existante basee sur Falco
