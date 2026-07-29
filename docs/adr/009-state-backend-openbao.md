# ADR-009 : State backend HTTP via OpenBao KV v2

**Date** : 2026-03-10
**Statut** : Accepte, amende 2026-06-14
**Decideurs** : Equipe plateforme

## Contexte

OpenTofu a besoin d'un backend pour stocker le state de chaque stack Terraform. Les options classiques :

- **Local** : fichier `terraform.tfstate` sur disque -> pas de partage, pas de lock, secrets en clair
- **S3** : bucket S3 -> necessite un object store qui n'existe pas encore au bootstrap (chicken-and-egg)
- **Consul/etcd** : service supplementaire a deployer

## Decision

Utiliser un **backend HTTP** (`terraform { backend "http" {} }`) pointe vers `vault-backend`, un micro-service qui stocke le state dans **OpenBao KV v2**.

## Architecture courante

```
OpenTofu -> HTTP backend (localhost:8080)
    +-- vault-backend
        +-- OpenBao KMS bootstrap KV v2 (secret/data/tfstate/...)
            +-- Raft storage single-node dans le platform pod Podman
```

Le bootstrap est gere par le module Terraform `bootstrap/` et les targets Makefile :

```
make bootstrap
+-- tofu apply bootstrap/
+-- podman play kube -> pod "platform"
+-- OpenBao KMS bootstrap (single-node Raft)
+-- vault-backend sidecar dans le meme pod
+-- Gitea + Woodpecker + tofu-setup

make bootstrap-export
+-- exporte tokens/certs dans kms-output/
```

Les alias historiques `make kms-bootstrap` et `make kms-stop` existent encore comme compatibilite vers `bootstrap` / `bootstrap-stop`.

## Authentification

```
TF_HTTP_USERNAME = AppRole role-id     (kms-output/approle-role-id.txt)
TF_HTTP_PASSWORD = AppRole secret-id   (kms-output/approle-secret-id.txt)
backend "http" {
  address  = "http://localhost:8080/state/{stack-name}"
  username = "TOKEN"
}
```

## Consequences

### Positives

- **Zero dependance externe** : tourne en local ou sur la VM CI avec Podman, pas besoin de cloud S3 au bootstrap
- **State chiffre** : stockage dans OpenBao KV v2 + Raft at-rest
- **Locking** : vault-backend gere le lock via KV v2
- **Multi-stack** : chaque stack a son propre path (`/state/st4ck/{env}/{instance}/{region}/{stack}`)
- **Portable** : meme mecanisme local et en CI

### Negatives

- **Prerequis bootstrap** : `make bootstrap` doit tourner avant tout `tofu init`
- **Single point of failure bootstrap** : si le pod Podman tombe, plus d'acces au state
- **Snapshot manuel** : `make state-snapshot` pour backup Raft

### Migration future

Quand Garage est deploye et stabilise, le state pourrait etre migre vers un backend S3. Tant que le bootstrap doit fonctionner sans cluster, OpenBao KMS + vault-backend restent le backend canonique.
