# ADR-015 : WireGuard IPv6 tunnels — differe (Gate 2+)

**Date** : 2026-03-09
**Statut** : Differe
**Decideurs** : Equipe plateforme

## Contexte

Separation plan data/communication en environnement air-gapped. WireGuard over IPv6 (ULA fd00::/8) avec interface slave dediee pour les tunnels chiffres.

## Interet

- **Support natif Talos** : WireGuard est integre au kernel Talos (pas de module externe)
- **Pas de NAT** : IPv6 ULA permet l'adressage direct pod-to-pod cross-site
- **Micro-segmentation** : interface dediee = separation physique data/tunnel
- **Kernel-space** : performances superieures aux VPN userspace

## Decision

**Differer.** Pertinent pour le multi-site (Gate 3, DR) mais pas necessaire pour un seul cluster Scaleway.

## Pre-requis pour implementation

1. Dual-stack IPv4+IPv6 configure sur les noeuds Talos
2. Plan d'adressage IPv6 ULA (fd00::/8) defini
3. Au moins 2 sites/clusters pour justifier les tunnels
4. Expertise IPv6 dans l'equipe

## Reconsiderer si

- Phase 3.6 DR multi-site (Garage replication cross-cluster)
- Besoin de tunnels chiffres dedies entre sites air-gapped
- Cilium WireGuard encryption ne suffit plus (besoin de separation physique des plans)

## Note

Cilium supporte deja le chiffrement WireGuard transparent entre noeuds (`encryption.type: wireguard`). Ce mode est plus simple que des tunnels IPv6 dedies et peut suffire pour Gate 2.
