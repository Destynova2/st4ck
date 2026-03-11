# ADR-017 : Cozystack PaaS optionnel Gate 3

**Date** : 2026-03-09
**Statut** : Accepte (planifie Gate 3, Phase 3.5)
**Decideurs** : Equipe plateforme

## Contexte

Abstraction multi-tenant pour equipes developpement. Besoin d'une couche PaaS self-service au-dessus du management cluster Kubernetes.

## Probleme

- Exposition directe de l'API K8s = complexe et risque pour les equipes dev
- Gestion multi-tenant native K8s limitee (namespaces, RBAC, quotas)
- Provisionner PostgreSQL, Valkey, Kafka = repetitif et error-prone

## Decision

**Cozystack** (CNCF Sandbox) en surcouche optionnelle Phase 3.5 :
- API K8s multi-tenant native
- Kubernetes-in-Kubernetes (clusters virtuels par tenant)
- Stack integree : PostgreSQL (CloudNativePG), Valkey, Kafka (Strimzi), S3 (Garage)
- Self-service via UI ou API

## Consequences

### Positives

- Equipes dev creent leurs propres services sans toucher au management cluster
- Isolation forte (vcluster par tenant)
- Catalogue de services standardise (DBaaS, cache, messaging, storage)

### Negatives

- CNCF Sandbox (maturite a evaluer avant Gate 3)
- Complexite operationnelle (layer supplementaire)
- Kubernetes-in-Kubernetes = overhead ressources

## Dependances

- Gate 2 complete (PostgreSQL, stockage production)
- Garage renforce (Phase 3.1)
- Au moins 2-3 equipes consommatrices pour justifier le PaaS
