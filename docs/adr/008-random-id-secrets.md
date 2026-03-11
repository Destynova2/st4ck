# ADR-008 : Secrets auto-generes via random_id Terraform

**Date** : 2026-03-09
**Statut** : Accepte
**Decideurs** : Equipe plateforme

## Contexte

La gestion initiale des secrets reposait sur des fichiers `secret.tfvars` manuels : l'operateur devait generer et fournir chaque secret (tokens OpenBao, passwords Harbor, shared secrets Pomerium, etc.) avant le deploy.

## Probleme

- **Risque d'erreur humaine** : copier-coller de secrets, oubli de rotation
- **Secrets en clair sur disque** dans les `.tfvars`
- **Non-reproductible** : chaque deploy necessite une intervention manuelle
- **Pomerium strict** : exige exactement 32 bytes raw pour shared_secret/cookie_secret, pas un hex string

## Decision

Tous les secrets sont generes automatiquement par `random_id` Terraform :

```hcl
resource "random_id" "garage_rpc_secret" { byte_length = 32 }
resource "random_id" "pomerium_shared_secret" { byte_length = 32 }
```

- `.hex` (64 chars) : tokens, admin passwords, RPC secrets
- `.b64_std` (base64, 32 bytes raw) : Pomerium shared/cookie secrets (strict 32 bytes)

Injectes dans les Helm values via `templatefile()`.

## Consequences

### Positives

- **Zero intervention manuelle** : `make k8s-up` genere tout
- **Secrets uniques par deploy** : chaque `tofu apply` sur un nouveau state produit de nouveaux secrets
- **Jamais en clair sur disque** : stockes uniquement dans le state Terraform
- **State chiffre** : Transit engine OpenBao (cle aes256-gcm96 "state-encryption")

### Negatives

- **State = source de verite** : perte du state = perte des secrets -> backup Velero + snapshot Raft OpenBao
- **Pas de rotation automatique** : les secrets sont stables tant que le state ne change pas
