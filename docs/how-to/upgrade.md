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

## Arbor / staging tree (pre-staging)

Pour les environnements a bande passante limitee ou les deploiements reproductibles,
l'arbor pre-telecharge toutes les dependances :

```bash
# 1. Pre-telecharger images + charts + git
make arbor

# 2. Verifier que tout est present
make arbor-verify

# 3. Deployer normalement (les images sont deja en cache local)
make upgrade
```

L'arbor genere un fichier `arbor/manifest.json` listant tous les artefacts avec
leurs SHA256. Le dossier `arbor/` est dans `.gitignore`.

Contenu du staging tree :
- `arbor/charts/` -- tous les charts Helm (`.tgz`) avec les versions exactes
- `arbor/manifest.json` -- inventaire complet (images + charts + SHA256)
- Cache podman local -- toutes les images de `platform-pod.yaml`

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
