# Plan de reprise d'activite (Disaster Recovery)

## Scenario

Tout est detruit. Vous clonez le depot Git et reconstruisez la plateforme a partir de zero.

---

## 1. Inventaire : que sauvegarder ?

| Donnee | Emplacement | Regenerable ? | Criticite |
|--------|-------------|---------------|-----------|
| tfstate (tous les stacks) | OpenBao Raft (bootstrap pod) | Non | **Critique** |
| CA Root + Sub-CAs (pem + cles) | `kms-output/` | Non (cles privees) | **Critique** |
| AppRole credentials | `kms-output/approle-*.txt` | Non | **Critique** |
| Root token OpenBao | `kms-output/root-token.txt` | Non | **Critique** |
| Unseal key (bootstrap) | `kms-output/unseal.key` | Non | **Critique** |
| Donnees PostgreSQL (CNPG) | Barman -> Garage S3 `cnpg-backups/` | Non | **Haute** |
| Donnees Garage (objets S3) | PVC Garage (3 replicas, Raft interne) | Non | Haute |
| Images Harbor | Garage bucket `harbor-registry/` | Partiellement (rebuild CI) | Moyenne |
| Backups Velero | Garage bucket `velero-backups/` | Non | Haute |
| Donnees Gitea | PVC bootstrap pod | Rebuild depuis Git upstream | Moyenne |
| Secrets applicatifs (Hydra, Pomerium...) | tfstate (random_id dans state) | Oui si tfstate restaure | Critique |
| Configs Kubernetes (manifests) | Depot Git | Oui (deterministe) | Faible |
| Machine secrets Talos | tfstate env | Oui si tfstate restaure | Critique |

### Ce qui peut etre regenere

- Les manifests Kubernetes (tout est dans Git)
- Les images container (pull depuis registres publics)
- Les Helm charts (fetch depuis upstream)
- Les certificats TLS leaf (cert-manager les re-emet)
- Les tokens in-cluster OpenBao (re-init automatique)

### Ce qui DOIT etre restaure

- `kms-output/` (CA Root, cles privees, tokens bootstrap)
- Snapshot Raft OpenBao (contient tous les tfstates)
- Backups CNPG barman (donnees PostgreSQL Kratos/Hydra)

---

## 2. Strategie de sauvegarde

### 2.1 Sauvegarde bootstrap (Raft + kms-output)

```bash
# Sauvegarde manuelle
make dr-backup-kms

# Cron recommande (quotidien)
0 3 * * * cd /chemin/vers/talos && make dr-backup-kms
```

Produit dans `~/talos-dr-backups/<date>/` :
- `raft.snap` : snapshot Raft (contient TOUS les tfstates)
- `kms-output/` : copie integrale (CA, tokens, cles)

### 2.2 Sauvegarde CNPG (PostgreSQL)

Barman-cloud envoie automatiquement les WAL et bases vers Garage S3 :
- **Bucket** : `cnpg-backups/identity-pg`
- **Endpoint** : `http://garage-s3.garage.svc.cluster.local:3900`
- **Frequence** : quotidien a 02:00 UTC (ScheduledBackup CRD)
- **Retention** : 14 jours

```bash
# Backup manuel immediat
make dr-backup-cnpg

# Verifier les backups
kubectl -n identity get backups
```

### 2.3 Sauvegarde Velero (ressources K8s + PVC)

Velero sauvegarde les ressources Kubernetes vers Garage S3 :
- **Bucket** : `velero-backups/`
- Configurez des `Schedule` Velero pour les namespaces critiques

### 2.4 Stockage hors-site

**Les sauvegardes doivent etre stockees hors de la plateforme.**

Options recommandees :
1. **Scaleway Object Storage** : bucket prive, chiffrement SSE-C
2. **Restic/Rclone** vers un stockage distant chiffre
3. **Support physique** chiffre (cle USB, disque externe) en lieu sur

```bash
# Exemple : sync vers Scaleway Object Storage
rclone sync ~/talos-dr-backups/ scw:talos-dr-backups/ --crypt-remote
```

Frequence recommandee :
- `kms-output/` : a chaque changement (rare)
- Raft snapshot : quotidien
- CNPG barman : automatique (continu via WAL)

---

## 3. Objectifs RPO / RTO

| Composant | RPO (perte max) | RTO (temps restauration) |
|-----------|-----------------|--------------------------|
| Bootstrap (tfstate + CA) | 24h (snapshot quotidien) | ~10 min |
| Infra cloud (VMs, reseau) | 0 (deterministe via TF) | ~15 min |
| CNI + stacks K8s | 0 (deterministe via TF) | ~15 min |
| PostgreSQL (CNPG) | ~5 min (WAL continu) | ~10 min |
| Donnees Garage S3 | Variable (3 replicas) | ~5 min (si PVC intactes) |
| **Total plateforme** | **24h** | **~60 min** |

Pour ameliorer le RPO bootstrap a < 1h : augmenter la frequence du cron Raft snapshot.

---

## 4. Runbook de restauration

### Pre-requis

- Acces au depot Git (`git clone`)
- Podman installe
- OpenTofu installe
- Copie de la derniere sauvegarde DR (`~/talos-dr-backups/<date>/`)
- Credentials cloud (Scaleway IAM `secret.tfvars` ou equivalent)

### Etape 0 : Preparer l'environnement

```bash
git clone <url-depot> talos && cd talos

# Restaurer kms-output/ depuis la sauvegarde
cp -r ~/talos-dr-backups/<date>/kms-output ./kms-output/

# Verifier l'integrite
make dr-verify-backup
```

### Etape 1 : Relancer le bootstrap

```bash
# Demarre le pod plateforme (OpenBao + Gitea + vault-backend)
make bootstrap

# Exporter les credentials (si pas deja dans kms-output/)
make bootstrap-export
```

### Etape 2 : Restaurer le Raft snapshot

```bash
# Restaurer les tfstates depuis le snapshot
make state-restore SNAPSHOT=~/talos-dr-backups/<date>/raft.snap

# Verifier la sante d'OpenBao
curl -s http://localhost:8200/v1/sys/health | jq .

# Verifier qu'un state est lisible
curl -s -u "$TF_HTTP_USERNAME:$TF_HTTP_PASSWORD" \
  http://localhost:8080/state/cni | head -c 100
```

**Note** : Si le snapshot n'est pas disponible, les tfstates sont perdus.
Dans ce cas, il faut reconstruire depuis zero (etape 1-alt ci-dessous).

### Etape 1-alt : Reconstruction sans snapshot (perte totale)

Si le Raft snapshot est indisponible :

```bash
# Le bootstrap regenere un OpenBao vierge
make bootstrap

# Re-initialiser tous les backends
make k8s-init

# Les stacks vont creer de nouveaux secrets (random_id)
# Les anciennes donnees CNPG ne seront PAS recuperables
# (nouvelles cles CA = anciens certificats invalides)
```

> En perte totale sans kms-output/, la PKI Root CA est perdue.
> Tous les certificats devront etre re-emis. Les donnees chiffrees
> avec les anciennes cles sont irrecuperables.

### Etape 3 : Deployer l'infrastructure cloud

```bash
# Scaleway (exemple)
make scaleway-iam-apply          # IAM (si pas deja fait)
make scaleway-image-apply        # Image Talos (si pas en cache)
make scaleway-apply              # Cluster (VMs + reseau)
make scaleway-kubeconfig         # Exporter kubeconfig
```

### Etape 4 : Deployer les stacks K8s

```bash
# Pipeline complet (ordre sequentiel garanti)
make k8s-up
```

Ceci deploie dans l'ordre : CNI -> storage (local-path) -> PKI -> monitoring -> identity -> security -> storage (complet) -> Flux.

### Etape 5 : Restaurer PostgreSQL depuis barman

Si les donnees CNPG doivent etre restaurees depuis barman (et non depuis un initdb vierge), modifier temporairement le Cluster CRD :

```yaml
# stacks/identity/main.tf — remplacer bootstrap.initdb par :
spec:
  bootstrap:
    recovery:
      source: identity-pg-backup
  externalClusters:
    - name: identity-pg-backup
      barmanObjectStore:
        destinationPath: "s3://cnpg-backups/identity-pg"
        endpointURL: "http://garage-s3.garage.svc.cluster.local:3900"
        s3Credentials:
          accessKeyId:
            name: cnpg-s3-credentials
            key: access_key
          secretAccessKey:
            name: cnpg-s3-credentials
            key: secret_key
```

Apres restauration, revenir a `bootstrap.initdb` et faire `tofu state rm` du cluster CNPG pour eviter un re-deploy.

### Etape 6 : Verifier la sante

```bash
# Cilium
kubectl -n kube-system get pods -l app.kubernetes.io/name=cilium-agent

# OpenBao in-cluster
kubectl -n secrets exec openbao-infra-0 -- bao status

# CNPG PostgreSQL
kubectl -n identity get cluster identity-pg
kubectl -n identity get backups

# Flux
kubectl -n flux-system get kustomizations

# Tous les pods
kubectl get pods -A | grep -v Running | grep -v Completed
```

---

## 5. Diagramme de l'ordre de restauration

```
Sauvegarde DR (hors-site)
    |
    v
[1] kms-output/ restaure
    |
    v
[2] make bootstrap              <- pod plateforme (OpenBao + Gitea)
    |
    v
[3] make state-restore          <- tfstates dans OpenBao KV v2
    |
    v
[4] make scaleway-apply         <- infra cloud (VMs, reseau, LB)
    |
    v
[5] make k8s-up                 <- tous les stacks K8s
    |   |-- cni (Cilium)
    |   |-- storage (local-path)
    |   |-- pki (CA + cert-manager + OpenBao in-cluster)
    |   |-- monitoring
    |   |-- identity (CNPG + Kratos + Hydra + Pomerium)
    |   |-- security
    |   |-- storage (Garage + Velero + Harbor)
    |   +-- flux-bootstrap
    |
    v
[6] Restaurer CNPG barman       <- si donnees PostgreSQL necessaires
    |
    v
[7] Verification sante
```

---

## 6. Checklist de maintenance

- [ ] **Hebdomadaire** : `make dr-backup` (Raft + kms-output)
- [ ] **Hebdomadaire** : Verifier les backups CNPG (`kubectl -n identity get backups`)
- [ ] **Mensuel** : Tester la restauration sur un env local (`make ENV=local local-up`)
- [ ] **Mensuel** : Synchroniser les sauvegardes hors-site
- [ ] **A chaque changement CA** : Sauvegarder `kms-output/` immediatement
- [ ] **Trimestriel** : DR drill complet (restauration integrale sur env de test)

---

## 7. Commandes make utiles

| Commande | Description |
|----------|-------------|
| `make dr-backup` | Sauvegarde complete (Raft + kms-output + trigger CNPG) |
| `make dr-backup-kms` | Sauvegarde bootstrap uniquement (Raft + kms-output) |
| `make dr-backup-cnpg` | Trigger backup CNPG manuel immediat |
| `make dr-verify-backup` | Verifier l'integrite de la derniere sauvegarde |
| `make state-snapshot` | Snapshot Raft seul (dans kms-output/) |
| `make state-restore SNAPSHOT=...` | Restaurer un snapshot Raft |
