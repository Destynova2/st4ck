# ADR-008 : Secrets auto-generes via Terraform

**Date** : 2026-03-09
**Statut** : Accepte, amende 2026-06-14 par ADR-033
**Decideurs** : Equipe plateforme

## Contexte

La gestion initiale des secrets reposait sur des fichiers `secret.tfvars` manuels : l'operateur devait generer et fournir chaque secret (tokens OpenBao, passwords Harbor, shared secrets Pomerium, etc.) avant le deploy.

## Probleme

- **Risque d'erreur humaine** : copier-coller de secrets, oubli de rotation
- **Secrets en clair sur disque** dans les `.tfvars`
- **Non-reproductible** : chaque deploy necessite une intervention manuelle
- **Contraintes de format** : certains secrets exigent des bytes raw/base64 stricts, d'autres des passwords ou cles asymetriques

## Decision

Tous les secrets plateforme sont generes automatiquement par Terraform, avec le type de ressource adapte :

```hcl
resource "random_password" "hydra_system_secret" { length = 64 }
resource "random_bytes" "pomerium_shared_secret" { length = 32 }
resource "tls_private_key" "cosign" { algorithm = "ED25519" }
```

Types utilises :

- `random_password` : mots de passe, client secrets, tokens humains/lisibles
- `random_bytes` : secrets binaires stricts, seal keys, RPC secrets
- `tls_private_key` : Root/Sub-CAs, Flux SSH, Cosign

Les valeurs sont stockees dans le state chiffre via le bootstrap OpenBao KMS. Les secrets consommables par les workloads sont ensuite seedes dans OpenBao Infra (`secret/...`) puis synchronises par ESO vers les Kubernetes Secrets.

## Consequences

### Positives

- **Zero intervention manuelle** : `make k8s-up` genere tout
- **Secrets uniques par deploy** : chaque nouveau state produit de nouveaux secrets
- **Jamais en clair dans Git** : les valeurs vivent dans le state chiffre et/ou OpenBao Infra
- **Formats corrects** : bytes, passwords et cles asymetriques sont generes par les providers adaptes
- **Day-2 GitOps** : ESO peut reconciler les Kubernetes Secrets depuis OpenBao Infra

### Negatives

- **State = source de verite initiale** : perte du state = perte des secrets initiaux si OpenBao n'est pas restaure
- **Rotation explicite** : les secrets sont stables tant que le state ne change pas ; la rotation doit passer par les targets dediees
- **Double phase** : generation Terraform puis seed OpenBao/ESO tant que la plateforme n'a pas de coffre applicatif autonome au tout debut

## Suite

ADR-033 propose de reduire progressivement les consommations directes de sorties Terraform et de faire de Flux + ESO le chemin day-2 canonique.
