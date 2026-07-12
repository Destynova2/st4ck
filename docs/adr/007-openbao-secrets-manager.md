# ADR-007 : OpenBao comme secrets manager

**Date** : 2026-03-09
**Statut** : Accepte, amende 2026-06-14 par ADR-033
**Decideurs** : Equipe plateforme

## Contexte

Gestion des secrets en mode air-gapped apres le changement de licence Vault (BSL). L'approche initiale prevoyait OpenBao + External Secrets Operator (ESO) + step-ca pour la PKI legere.

## Decision initiale

OpenBao (Linux Foundation, MPL-2.0) est retenu comme coffre souverain et backend compatible Vault.

## Amendements

### 2026-03-09 — step-ca retire

cert-manager + Terraform TLS provider suffisent pour le bootstrap initial :
- Root CA generee par `tls_private_key` + `tls_self_signed_cert` dans le bootstrap hors cluster
- Intermediate CAs signees par Root, exportees dans `kms-output/`
- `ClusterIssuer "internal-ca"` pour les certificats workloads
- step-ca = service supplementaire a operer, sans valeur ajoutee a ce stade

### 2026-06-14 — ESO reintegre comme chemin canonique de synchronisation

ESO n'est plus retire. Le modele courant est :

```
OpenBao Infra KV v2 -> ESO ClusterSecretStore -> ExternalSecret -> K8s Secret
```

Raison : les secrets sont toujours generes par Terraform au bootstrap, mais ils sont seedes dans OpenBao Infra puis synchronises par ESO pour le day-2 Flux. Cela evite que les charts applicatifs consomment durablement des secrets par sorties Terraform directes.

ESO utilise son provider Vault/OpenBao (`provider.vault`, KV v2, auth Kubernetes). Aucun operateur OpenBao non officiel n'est ajoute : OpenBao reste deploye avec le chart Helm officiel.

## Architecture courante

```
OpenBao KMS bootstrap (Podman, hors cluster)
+-- KV v2 pour tfstate via vault-backend
+-- Root CA + intermediate CAs exportees dans kms-output/

OpenBao Infra (Kubernetes, namespace secrets)
+-- KV v2 source d'ESO
+-- PKI intermediate pour cert-manager
+-- SSH CA (ssh-client-signer, role flux)
+-- Kubernetes auth pour ESO/cert-manager/workloads autorises

OpenBao App (Kubernetes, namespace secrets)
+-- Coffre applicatif separe, reserve tant qu'aucun ClusterSecretStore app n'est cable

ESO
+-- ClusterSecretStore openbao-infra
+-- ExternalSecret / PushSecret reconciles par Flux
```

## Consequences

### Positives

- MPL-2.0, pas de vendor lock-in (fork Vault, Linux Foundation)
- Integration K8s native via auth Kubernetes + ESO
- Audit centralise dans OpenBao Infra pour les lectures de secrets day-2
- PKI simple sans service supplementaire step-ca
- Separation claire entre KMS bootstrap, secrets plateforme et futurs secrets applicatifs

### Negatives

- Fork recent, communaute plus petite que Vault
- Support entreprise limite (pas de HashiCorp support)
- Certaines features Vault Enterprise non disponibles (namespaces, Sentinel)
- Handoff OpenTofu -> Flux/ESO a documenter pour eviter les doubles owners

## Suite

ADR-033 precise la frontiere OpenTofu/Flux cible : plus de reconciliation dans Flux/Kustomize/HelmRelease, moins de pilotage Kubernetes par Terraform, sans introduire d'operateur OpenBao non recommande.
