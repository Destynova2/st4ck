# ADR-009 : State backend HTTP via OpenBao KV v2

**Date** : 2026-03-10
**Statut** : Accepte
**Decideurs** : Equipe plateforme

## Contexte

OpenTofu a besoin d'un backend pour stocker le state de chaque stack Terraform. Les options classiques :
- **Local** : fichier `terraform.tfstate` sur disque -> pas de partage, pas de lock, secrets en clair
- **S3** : bucket S3 -> necessite un object store qui n'existe pas encore au bootstrap (chicken-and-egg)
- **Consul/etcd** : service supplementaire a deployer

## Decision

Utiliser un **backend HTTP** (`terraform { backend "http" {} }`) pointe vers un micro-service `vault-backend` qui stocke le state dans **OpenBao KV v2**.

### Architecture

```
OpenTofu -> HTTP backend (localhost:8080)
    +-- vault-backend (Go, ~5 MB)
        +-- OpenBao KV v2 (state/{stack-name})
            +-- Raft storage (3 noeuds, Podman pod local)
```

### Bootstrap (kms-bootstrap)

```
make kms-bootstrap
+-- Podman play kube -> pod "openbao-kms" (3 noeuds Raft)
+-- Init + unseal cluster
+-- Enable KV v2 + Transit engines
+-- Create vault-backend token (policy: kv read/write + transit encrypt/decrypt)
+-- Start vault-backend sidecar dans le meme pod
```

### Authentification

```
TF_HTTP_PASSWORD = token vault-backend (lu depuis kms-output/vault-backend-token.txt)
backend "http" {
  address  = "http://localhost:8080/state/{stack-name}"
  username = "TOKEN"
}
```

## Consequences

### Positives

- **Zero dependance externe** : tourne en local (Podman), pas besoin de cloud S3 au bootstrap
- **State chiffre** : Transit engine OpenBao (aes256-gcm96, cle "state-encryption")
- **Locking** : vault-backend gere le lock via KV v2 (CAS)
- **Multi-stack** : chaque stack a son propre path (`state/k8s-cni`, `state/flux-bootstrap`, etc.)
- **Portable** : meme mecanisme local et en CI (vault-backend tourne aussi dans la VM CI)

### Negatives

- **Prerequis local** : `make kms-bootstrap` doit tourner avant tout `tofu init`
- **Single point of failure local** : si le pod Podman tombe, plus d'acces au state
- **Snapshot manuel** : `make state-snapshot` pour backup Raft

### Migration future

Quand Garage est deploye dans le cluster, le state peut etre migre vers un backend S3 :
```hcl
terraform { backend "s3" { bucket = "tfstate" ... } }
```
