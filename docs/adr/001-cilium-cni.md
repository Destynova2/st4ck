# ADR-001 : Cilium CNI au lieu de Flannel

**Date** : 2026-03-08
**Statut** : Accepte
**Decideurs** : Equipe plateforme

## Contexte

Choix du CNI pour les clusters Talos en environnement defense air-gapped. Flannel etait le choix par defaut (simple, leger).

## Probleme

Flannel est limite :
- Pas de NetworkPolicy native (necessite Calico en complement)
- iptables lent a grande echelle
- Pas d'observabilite reseau
- Pas de service mesh integre

## Decision

**Cilium** avec :
- `kubeProxyReplacement: true` (eBPF remplace kube-proxy)
- Hubble pour l'observabilite reseau
- mTLS inter-workloads
- NetworkPolicy L3/L4/L7
- Support officiel Talos (`cni: none` + `proxy: disabled` dans machine config)

## Configuration Talos

```yaml
cluster:
  network:
    cni:
      name: none       # Cilium deploye par Helm
  proxy:
    disabled: true     # kube-proxy remplace par Cilium eBPF
```

## Consequences

### Positives

- Performances 2-3x meilleures (eBPF datapath vs iptables)
- NetworkPolicy L7 (HTTP, gRPC, DNS-aware)
- Observabilite reseau native (Hubble UI, metriques, flow logs)
- Service mesh integre (mTLS transparent, sans sidecar)
- Support officiel Talos + Cilium

### Negatives

- Configuration plus complexe que Flannel
- Surface d'attaque legerement plus grande (eBPF programs dans le kernel)
- Necessite le patch `cilium-cni.yaml` dans les machine configs
