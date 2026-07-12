# Mise a jour d'un deploiement existant

## Prerequis

- Un cluster Talos deja deploye (`make scaleway-up` ou `make ENV=local local-up`)
- Acces SSH/kubectl fonctionnel vers le cluster
- vault-backend accessible (`curl http://localhost:8080/state/test` retourne HTTP 2xx/4xx)
- Le pod bootstrap tourne (`podman pod ps` montre `platform` en Running)
- Les fichiers `kms-output/approle-role-id.txt` et `kms-output/approle-secret-id.txt` existent
- Variable `TF_VAR_admin_password` exportee (>= 16 caracteres)

## Mise a jour standard

La procedure complete, de `git pull` au deploiement :

```bash
# 1. Recuperer les dernieres modifications
git pull origin main

# 2. Lancer la mise a jour complete
make upgrade              # ENV=scaleway par defaut
make upgrade ENV=local    # pour un deploiement local
```

`make upgrade` enchaine automatiquement :

1. **Preflight** -- verifie variables, fichiers, connectivite, validation des stacks
2. **Snapshot** -- sauvegarde Raft de tous les etats OpenBao
3. **Bootstrap update** -- si `bootstrap/` a change, re-cree le pod (PVC preserves)
4. **Provider apply** -- applique les changements d'infrastructure (Scaleway/local)
5. **k8s-up** -- deploie tous les stacks K8s dans l'ordre

Pour valider avant de lancer :

```bash
make preflight
```

## Mise a jour du bootstrap uniquement

Si seul le pod bootstrap a change (nouvelle version d'image, config OpenBao) :

```bash
make bootstrap-update
```

Cette commande execute `podman play kube --replace` qui re-cree le pod avec la
nouvelle configuration sans perdre les donnees PVC (OpenBao Raft, Gitea, Woodpecker).

Le flag `--replace` :
- Arrete les containers existants
- Re-cree le pod avec les nouvelles specs
- Reattache les PVC existants (pas de perte de donnees)

## Hauler / staging d'artefacts (pre-staging, ADR-034)

Pour les environnements a bande passante limitee, les deploiements
reproductibles et l'air-gap, hauler pre-telecharge toutes les dependances
dans un store OCI adresse par digest. Les versions viennent du registre
unique (`clusters/management/versions-configmap.yaml`) :

```bash
# 1. Regenerer le manifest depuis le registre de versions
make hauler-manifest

# 2. Synchroniser le store (delta uniquement — store adresse par digest)
make hauler-sync

# 3. Verifier le contenu du store
make hauler-verify

# 4. Deployer normalement
make upgrade
```

Air-gap : `make hauler-save` exporte le store en tarball zstd (chunkable),
`hauler store load` le reimporte cote isole et `make hauler-serve` expose
un registre OCI local (port 5000) pour Flux/containerd.

Contenu du store :
- `hauler-manifest.yaml` -- inventaire declaratif (images + charts + files),
  versionne dans Git, genere par `scripts/hauler-manifest-gen.py`
- `haul/` -- store OCI local (gitignore), digests verifies au pull (cosign)
- Images control-plane (`kube-*`) retaguees automatiquement sur le
  `k8s_version` des contexts

Les cibles `make arbor` / `arbor-verify` sont des alias deprecies qui
deleguent aux cibles hauler.

## Rollback

En cas de probleme apres une mise a jour :

```bash
# 1. Lister les snapshots disponibles
ls kms-output/raft-snapshot-*.snap

# 2. Restaurer un snapshot
make state-restore SNAPSHOT=kms-output/raft-snapshot-20260319-143000.snap

# 3. Re-appliquer les stacks (elles utiliseront l'ancien etat)
make k8s-up
```

Le snapshot Raft contient **tous** les etats OpenTofu (tous les stacks + provider)
ainsi que les secrets PKI et les tokens AppRole. La restauration est atomique.

## Variables obligatoires ajoutees

| Variable | Description | Exemple |
|----------|-------------|---------|
| `TF_VAR_admin_password` | Mot de passe admin (Gitea, WP, OpenBao bootstrap-admin) | `export TF_VAR_admin_password="MonMotDePasse16chars"` |

La variable doit contenir au minimum 16 caracteres (validation dans `bootstrap/main.tf`).

## Troubleshooting courant

### Token expire

Les tokens AppRole (vault-backend) sont auto-renouvelables avec une periode de 768h.
Ils ne devraient jamais expirer en usage normal. Si le probleme persiste :

```bash
# Re-exporter les credentials depuis le PVC
make bootstrap-export

# Verifier les fichiers
cat kms-output/approle-role-id.txt
cat kms-output/approle-secret-id.txt
```

### Redemarrage du pod bootstrap

Les donnees sont preservees dans les PVC podman :
- `platform-bao-data` -- donnees Raft OpenBao (etats TF, secrets, PKI)
- `platform-gitea-data` -- depot git, base SQLite
- `platform-wp-data` -- configuration Woodpecker
- `platform-kms-output` -- tokens et certificats exportes

Apres un redemarrage :

```bash
# Verifier l'etat d'OpenBao
curl -s http://localhost:8200/v1/sys/health | jq .

# Verifier vault-backend
curl -s http://localhost:8080/state/test

# Si le pod est arrete, le relancer
make bootstrap-update
```

### Preflight echoue sur la validation d'un stack

```bash
# Identifier le stack en erreur
make preflight

# Debugger manuellement
cd stacks/<stack-en-erreur>
tofu init -backend=false -input=false
tofu validate
```

### vault-backend inaccessible

```bash
# Verifier le pod
podman pod ps

# Voir les logs
podman logs platform-vault-backend

# Relancer si necessaire
make bootstrap-update
```
