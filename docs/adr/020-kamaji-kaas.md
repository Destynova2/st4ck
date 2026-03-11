# ADR-020 : Kamaji comme alternative KaaS a Cozystack

**Date** : 2026-03-11
**Statut** : Evalue (alternative a ADR-017 Cozystack)
**Decideurs** : Equipe plateforme

## Contexte

Cozystack (ADR-017) est prevu pour le PaaS self-service Gate 3.5 avec Kubernetes-in-Kubernetes (vcluster). Kamaji (CNCF Sandbox) propose une approche differente : **control planes mutualises** (Kubernetes-as-a-Service) sans overhead de clusters virtuels complets.

## Comparaison Kamaji vs Cozystack

| Critere | Kamaji | Cozystack |
|---|---|---|
| Approche | Control planes mutualises (etcd partage) | vcluster (K8s-in-K8s complet) |
| Overhead par tenant | ~0 (control plane = pods dans le mgmt cluster) | Moyen (vcluster = etcd + apiserver par tenant) |
| Isolation | Namespace + RBAC | Fort (vcluster complet) |
| Networking | Cilium du mgmt cluster | Isole par vcluster |
| Stack integree | Non (K8s pur) | Oui (PostgreSQL, Valkey, Kafka, S3) |
| Maturite | CNCF Sandbox, Clastix | CNCF Sandbox, Ænix |
| Complexite | Faible (CRD TenantControlPlane) | Moyenne (FluxCD + Helm, stack complete) |
| Bare metal | Natif (avec CAPI) | Natif |
| Use case | KaaS pur (multi-tenant K8s) | PaaS complet (DBaaS + KaaS) |

## Interet de Kamaji

### Architecture

```
Management Cluster (Talos)
├── Kamaji controller
├── TenantControlPlane "team-a"
│   ├── kube-apiserver (pod)
│   ├── kube-controller-manager (pod)
│   └── etcd shard (dans le datastore partage)
├── TenantControlPlane "team-b"
│   └── ... (memes pods, etcd partage)
└── Worker nodes (joinables par chaque tenant)
```

- Les tenants obtiennent un kubeconfig standard
- Les workers sont assignes aux tenants via labels/taints
- Le control plane est un set de pods dans le management cluster
- etcd est partage (datastore PostgreSQL ou etcd multi-tenant)

### Avantages specifiques

- **Overhead minimal** : pas de vcluster complet, juste des pods control plane
- **Compatible CAPI** : Kamaji peut etre un bootstrap provider pour Cluster API
- **Scaling** : ajouter un tenant = creer une CRD TenantControlPlane (~30s)
- **Bare metal natif** : les workers sont des machines reelles, pas des VMs dans des VMs

## Decision

**Evaluer Kamaji en parallele de Cozystack pour Gate 3.**

- Si le besoin est **KaaS pur** (multi-tenant K8s, equipes avec leur propre cluster) → Kamaji
- Si le besoin est **PaaS complet** (DBaaS, cache, messaging, self-service catalogue) → Cozystack
- Les deux sont complementaires : Kamaji pour le KaaS, Cozystack pour le PaaS au-dessus

## Integration avec la stack existante

- **CAPI** : Kamaji comme bootstrap provider (remplace CAPT pour les tenants)
- **Cilium** : les tenant workers partagent le meme CNI que le management cluster
- **OpenBao** : un namespace par tenant dans OpenBao app
- **Garage** : un bucket S3 par tenant pour les backups

## Consequences

### Positives

- KaaS leger sans overhead vcluster
- Compatible bare metal + CAPI
- Overhead ~0 par tenant supplementaire
- CRD simple (TenantControlPlane)

### Negatives

- Isolation moindre que vcluster (namespace-level, pas cluster-level)
- Pas de stack integree (PostgreSQL, Kafka, etc. a deployer separement)
- CNCF Sandbox (maturite a evaluer)
- etcd multi-tenant = complexite operationnelle (compaction, quotas)

## Reconsiderer si

- Besoin d'isolation forte par tenant (compliance, securite) → Cozystack/vcluster
- Besoin de PaaS catalogue (DBaaS) → Cozystack
- Moins de 3 tenants → CAPI + namespaces suffisent
