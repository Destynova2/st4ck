# ADR-013 : Kuma service mesh — differe (Cilium couvre le besoin)

**Date** : 2026-03-09
**Statut** : Differe
**Decideurs** : Equipe plateforme

## Contexte

Kuma (CNCF, Envoy-based) etait envisage pour unifier discovery et securite reseau sur infrastructure hybride VM+K8s, avec MADS discovery et kuma-prometheus-sd.

## Analyse

Cilium (ADR-001) fournit deja :
- **mTLS transparent** entre workloads (sans sidecar Envoy)
- **NetworkPolicy L7** (HTTP, gRPC, DNS-aware)
- **Hubble** pour l'observabilite reseau (flow logs, metriques, UI)
- **Service mesh eBPF** sans overhead sidecar

Kuma ajouterait :
- Discovery unifie VM+K8s (MADS) — **pas de VMs hors cluster actuellement**
- Envoy sidecar avec plus de features L7 (rate limiting, circuit breaking)
- Multi-zone/multi-cluster mesh

## Decision

**Differer Kuma.** Cilium couvre les besoins actuels (mTLS, L7 policies, observabilite). Kuma n'est pertinent que si :
1. Des VMs hors cluster doivent rejoindre le mesh (hybride)
2. Des features Envoy avancees sont requises (rate limiting, fault injection)
3. Multi-cluster mesh est necessaire (Gate 3+)

## Reconsiderer si

- Phase 3.6 DR multi-site necessite un mesh cross-cluster
- Des workloads legacy sur VMs doivent etre integres au mesh
- Les NetworkPolicy L7 Cilium ne suffisent plus (features Envoy specifiques)
