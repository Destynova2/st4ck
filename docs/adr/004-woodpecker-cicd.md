# ADR-004 : Woodpecker + OpenTofu au lieu de FluxCD

**Date** : 2026-03-09
**Statut** : Accepte
**Decideurs** : Equipe plateforme

## Contexte

FluxCD etait prevu comme controleur GitOps pour synchroniser les manifests depuis Gitea vers le cluster. Le deploiement se fait en 7 stacks Terraform sequentielles avec des dependances strictes (Cilium avant tout, PKI avant identity, etc.).

## Probleme

1. **Chicken-and-egg** : Flux a besoin du reseau (Cilium) pour tourner, mais Cilium est le premier composant a deployer. Flux ne peut pas bootstrapper Cilium.
2. **Deux systemes de deploiement** : Woodpecker CI + OpenTofu gere deja le CD avec ordering strict (7 stages). Ajouter Flux = doublonner le mecanisme de deploiement.
3. **Ordering complexe** : Les stacks ont des dependances non-triviales (sequentiel strict cni-pki-monitoring-identity-security-storage-flux) que Flux Kustomization dependencies ne modelise pas facilement.

## Decision

Utiliser **Woodpecker CI + OpenTofu** comme pipeline CD unique. Flux est conserve pour la reconciliation post-deploy (drift detection, self-healing) mais ne gere pas le bootstrap initial.

## Pipeline Woodpecker

```
validate -> image -> cluster -> wait-api -> addons -> secrets -> security -> storage
                                          |
                                          +-- k8s-cni-apply
                                          +-- k8s-pki-apply
                                          +-- k8s-monitoring-apply
                                          +-- k8s-identity-apply
                                          +-- k8s-security-apply
                                          +-- k8s-storage-apply
                                          +-- flux-bootstrap-apply
```

## Consequences

- Pipeline CD unique, ordering explicite, parallelisme controle
- Flux reste deploye pour le drift detection post-bootstrap
- Pas de GitOps "pur" pour le bootstrap, mais pragmatique pour l'air-gap
