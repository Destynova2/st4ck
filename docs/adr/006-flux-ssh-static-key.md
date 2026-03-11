# ADR-006 : Flux SSH statique (go-git incompatible SSH CA)

**Date** : 2026-03-11
**Statut** : Accepte
**Decideurs** : Equipe plateforme

## Contexte

Pour l'authentification Flux -> Gitea, l'approche ideale etait :
1. OpenBao SSH CA signe des certificats courts (TTL 2h)
2. L'Agent Injector (sidecar) renouvelle automatiquement le cert (renew a 2/3 du TTL)
3. Gitea fait confiance au CA via `SSH_TRUSTED_USER_CA_KEYS`
4. Aucun deploy key statique, rotation automatique

L'infrastructure SSH CA a ete deployee dans OpenBao :
- Engine `ssh-client-signer` avec role `flux` (TTL 2h, max 24h)
- Auth method `kubernetes` avec role `flux-ssh` lie au SA `flux2-source-controller`
- Policy `flux-ssh` autorisant `create/update` sur `ssh-client-signer/sign/flux`
- Agent Injector active sur OpenBao infra

## Probleme

**Flux source-controller utilise go-git**, pas le binaire `ssh` systeme :
- go-git gere les connexions SSH via `golang.org/x/crypto/ssh` en process
- Il lit la cle privee depuis un K8s secret (`secretRef`), pas depuis le filesystem
- **go-git ne supporte pas les certificats SSH CA** dans son transport SSH
- `GIT_SSH_COMMAND` n'a aucun effet car go-git ne shell-out pas vers `ssh`
- L'option `gitImplementation: libgit2` (qui supportait le SSH systeme) est **deprecee et supprimee** dans Flux v2

## Decision

Utiliser une **cle SSH ed25519 statique** generee par Terraform (`tls_private_key`), stockee dans un K8s secret, referencee par le GitRepository via `secretRef`.

```hcl
resource "tls_private_key" "flux_ssh" {
  algorithm = "ED25519"
}
```

La cle publique est ajoutee manuellement comme deploy key dans Gitea.

## Infrastructure SSH CA conservee

L'infrastructure SSH CA reste operationnelle pour les workloads qui utilisent le SSH systeme :
- **Woodpecker CI agents** : pipeline steps qui clonent via SSH
- **Custom controllers** : tout pod qui shell-out vers `git clone` via SSH
- **Operateurs humains** : acces SSH signe par le CA (via `bao ssh -role=...`)

## Consequences

- Flux utilise une cle statique (pas de rotation auto)
- La cle privee est dans le state Terraform (chiffre via Transit OpenBao)
- Rotation manuelle possible : `tofu taint tls_private_key.flux_ssh && tofu apply`
- Le `known_hosts` dans le secret doit etre mis a jour quand Gitea est deploye
