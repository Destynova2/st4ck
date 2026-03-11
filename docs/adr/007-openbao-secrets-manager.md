# ADR-007 : OpenBao comme secrets manager (sans ESO ni step-ca)

**Date** : 2026-03-09
**Statut** : Accepte
**Decideurs** : Equipe plateforme

## Contexte

Gestion des secrets en mode air-gapped apres le changement de licence Vault (BSL). L'approche initiale prevoyait OpenBao + External Secrets Operator (ESO) + step-ca pour la PKI legere.

## Decision initiale

OpenBao (Linux Foundation, Apache 2.0) + ESO + cert-manager + step-ca.

## Amendements

### ESO retire

Les secrets sont auto-generes via `random_id` Terraform (ADR-008) et injectes directement dans les Helm values via `templatefile()`. ESO n'apporte pas de valeur ajoutee dans ce modele :
- Pas de secrets externes a synchroniser (tout est genere par Terraform)
- Les secrets vivent dans le state Terraform (chiffre via Transit OpenBao)
- L'Agent Injector OpenBao est disponible pour les workloads qui ont besoin de secrets dynamiques

**ESO pourra etre ajoute si** : des secrets doivent etre synchronises depuis un source externe, ou si des equipes veulent consommer des secrets OpenBao sans passer par Terraform.

### step-ca retire

cert-manager + Terraform TLS provider suffit :
- Root CA generee par `tls_private_key` + `tls_self_signed_cert` (Terraform)
- Intermediate CA signee par Root, injectee dans cert-manager
- `ClusterIssuer "internal-ca"` pour tous les certificats workloads
- step-ca = service supplementaire a operer, sans valeur ajoutee

## Architecture finale

```
OpenBao infra :
+-- Transit engine (chiffrement state OpenTofu)
+-- SSH CA (ssh-client-signer, role flux)
+-- Kubernetes auth (role flux-ssh)
+-- Agent Injector (sidecar pour secrets dynamiques)

OpenBao app :
+-- Secrets applicatifs (futur, Gate 2+)

PKI :
+-- Terraform TLS provider -> cert-manager ClusterIssuer
```

## Consequences

### Positives

- Apache 2.0, pas de vendor lock-in (fork Vault, Linux Foundation)
- Integration K8s native (auth kubernetes, agent injector)
- Transit engine pour chiffrement state (zero secret en clair)
- PKI simple sans service supplementaire

### Negatives

- Fork recent, communaute plus petite que Vault
- Support entreprise limite (pas de HashiCorp support)
- Certaines features Vault Enterprise non disponibles (namespaces, sentinel)
