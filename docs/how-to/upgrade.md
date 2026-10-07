# Mise a jour d'un deploiement existant

> Attention, révision Flux du 2026-09-23 : suivre d'abord
> [ADR-043](../adr/043-flux-platform-ownership.md), avant de publier la révision
> surveillée par Flux. La procédure générique ci-dessous n'est pas validée
> en production pour l'upgrade HA OpenBao. Le cycle à deux phases conserve
> maintenant trois répliques dans Helm après amorçage ; une vraie mise à jour
> de chart reste à valider sur un cluster de recette avant `make upgrade`.

> Migration bootstrap du 26 septembre : avant de recréer un ancien pod,
> sauvegarder et migrer son état interne comme indiqué ci-dessous. Un snapshot
> Raft ne sauvegarde pas cet état local ni la clé de scellement du bootstrap.

## Cycle PKI

`make k8s-pki-apply` distingue une installation neuve d'un Raft déjà formé.
Seules les releases neuves/incomplètes sont amorcées à une réplique. Après
passage à trois et accord des trois pods sur un leader unique, une seconde
application fixe la cible Helm à trois. En cas d'interruption entre les deux
phases, relancer cette cible avec le même contexte ; ne pas forcer les values
à une réplique. Un StatefulSet absent avec des PVC existants, un compte
inattendu de répliques ou un Raft incohérent arrête le parcours pour diagnostic.
Les volumes ne sont pas supprimés automatiquement.

## Prerequis

- Un cluster Talos deja deploye (`make scaleway-up` ou `make local-up`)
- Acces kubectl/talosctl fonctionnel au cluster et SSH vers la VM CI
- vault-backend accessible (`curl http://localhost:8080/state/test` retourne HTTP 2xx/4xx)
- Le pod bootstrap tourne (`podman pod ps` montre `platform` en Running)
- Les fichiers `kms-output/approle-role-id.txt` et `kms-output/approle-secret-id.txt` existent
- Variable `TF_VAR_admin_password` exportee (>= 16 caracteres)
- Python 3.9+ et PyYAML sur la machine qui lance le bootstrap ; le provisioner
  CI installe `python3` et `python3-yaml` sur la VM avant le lancement
- Connexion Podman selectionnee explicitement, identique pour la sauvegarde,
  le preflight et l'application ; aucune autre mise a jour concurrente

## Mise a jour standard

La procedure complete, de `git pull` au deploiement :

```bash
# 1. Recuperer les dernieres modifications
git pull origin main

# 2. Lancer la mise a jour complete
make upgrade PROVIDER=scaleway
make upgrade PROVIDER=local GITEA_CLUSTER_HOST=192.0.2.10
```

Pour le parcours local, remplacer `192.0.2.10` par l'adresse de l'hote Gitea
joignable depuis le cluster. `ENV` reste `dev` par defaut ; `local` designe ici
le provider, pas un nom d'environnement.

`make upgrade` enchaine automatiquement :

1. **Preflight** -- verifie variables, fichiers, connectivite, validation des stacks
2. **Sauvegarde KMS** -- `dr-backup-kms` conserve Raft et les identites hors Raft
3. **Bootstrap update** -- regenere les artefacts via `make bootstrap` ; le
   remplacement declenche par Tofu passe par le controle de migration
4. **Provider apply** -- applique les changements d'infrastructure (Scaleway/local)
5. **k8s-up** -- deploie tous les stacks K8s dans l'ordre

La sauvegarde utilise par defaut `BOOTSTRAP_STATE=bootstrap/terraform.tfstate`
et `BOOTSTRAP_MANIFEST=$(BOOTSTRAP_DIR)/platform-pod.yaml`. Surcharger ces deux
chemins pour un autre bootstrap, sans melanger les fichiers d'une machine avec
le moteur Podman d'une autre. Le bundle KMS inclut notamment snapshot Raft,
etat externe, etat interne du setup, cle de scellement, exports PKI/credentials,
manifeste complet et sources du setup. Il ne sauvegarde pas a lui seul Gitea,
Woodpecker ni les donnees applicatives du cluster ; voir la
[procedure de reprise](disaster-recovery.md).

Pour valider avant de lancer :

```bash
make preflight
```

## Mise a jour du bootstrap uniquement

### Conservation de l'etat interne

Le sidecar utilise le volume `platform-tofu-state`, monte sur `/var/lib/tofu`.
Le controle du sidecar seul est trop tardif pour proteger l'etat temporaire
d'un ancien conteneur. Les chemins de remplacement local et CI utilisent donc
`scripts/bootstrap-preflight.py` **avant toute suppression du pod ou du Secret**.
Ne pas contourner ce controle en effacant `kms-output`, l'etat ou la cle retenue.

Sur un bootstrap antérieur, **avant tout `--replace`, arrêt avec suppression
du pod ou réapplication susceptible de le recréer** :

1. Identifier explicitement la connexion Podman et le pod concernés.
2. Sauvegarder l'état externe `bootstrap/terraform.tfstate`, la clé de
   scellement, un snapshot Raft et le volume `platform-kms-output` dans un
   emplacement privé. Ces sauvegardes contiennent des secrets.
3. Executer le preflight ci-dessous pendant que `platform-tofu-setup` existe
   encore. Il suspend temporairement un sidecar actif et refuse un verrou
   d'application present. Il lit l'etat persistant, ou exporte l'ancien
   `/tmp/tofu-work/terraform.tfstate` et sa sauvegarde si presente.
4. Le helper verifie JSON, version, lignee, numero de serie, ressources PKI
   non marquees pour remplacement et correspondance des certificats/cles
   exportes avec l'etat. Il copie l'etat legacy valide dans
   `platform-tofu-state` puis le relit **avant** toute suppression. Un etat
   persistant valide est conserve ; deux etats differents, meme de meme
   lignee, imposent une resolution manuelle. Aucune selection par date.
5. Régénérer le manifeste avec le module bootstrap et les variables/états
   existants, après inspection du plan : aucune clé ni CA ne doit être recréée.
6. Recréer le pod, puis vérifier la fin du setup et les empreintes des CA avant
   de reprendre les applications des stacks.

```bash
# Controle et migration seuls, sans suppression ni lancement du pod
python3 scripts/bootstrap-preflight.py \
  --manifest "$BOOTSTRAP_DIR/platform-pod.yaml"

# Ancien format : ajouter la ConfigMap separee uniquement si elle n'est
# pas deja incluse dans le manifeste (les objets dupliques sont refuses).
python3 scripts/bootstrap-preflight.py \
  --manifest "$BOOTSTRAP_DIR/platform-pod.yaml" \
  --configmap "$BOOTSTRAP_DIR/configmap.yaml"
```

Le mode sans `--replace` accepte un ancien manifeste sans volume d'etat cible.
Le mode `--replace`, utilise par les lanceurs, exige ce volume dans le nouveau
manifeste. Un conteneur arrete reste lisible ; ne pas le supprimer pour tenter
de debloquer une migration. Si conteneur et etat ont disparu, restaurer une
sauvegarde complete. Les regressions du helper sont testees avec Podman simule ;
cela ne constitue pas une recette de migration sur un moteur reel.

La cle comparee est celle de la **ConfigMap consommee par le pod**, pas seulement
un fichier de sauvegarde sur l'hote. Elle doit correspondre a `unseal.key` retenu
pres du manifeste et, si l'ancien conteneur Bao existe, a sa cle montee dans
`/bao/seal/unseal.key`. La CI compare aussi `unseal.key.bin` uploade. Une divergence,
une cle mal formee ou une erreur de lecture arrete le remplacement, meme sans PKI.
Un Raft existant sans aucune preuve de sa cle impose une restauration manuelle.

Les cles Terraform ont `prevent_destroy` : une rotation volontaire doit suivre
une procedure de migration de scellement, pas `taint` ou `-replace`.
`ignore_changes = all` seul ne protege pas contre ces operations.

`make bootstrap-update` delegue a `make bootstrap` pour regenerer le manifeste.
Le module local suit le contenu de la configuration, du pod rendu, des sources
`bootstrap/tofu/*.tf` et du helper. La CI suit aussi ces sources et le lanceur.
Conserver les variables et l'etat externe existants lors de cette application.

### Reapplication du manifeste

Si seul le pod bootstrap a change (nouvelle version d'image, config OpenBao) :

```bash
make bootstrap-update
```

Le helper valide et migre, puis supprime explicitement le seul pod `platform`
avant de lancer le manifeste prive qu'il vient de verifier. Il ajoute
`--build=false` uniquement si le client le propose. Il exige le support de
`--log-driver` avant suppression et lance ce pod avec `--log-driver=k8s-file`,
pour rendre les logs lisibles aussi depuis un client distant sans lecteur
journald. La configuration globale du moteur reste inchangee. Aucun volume
n'est supprime.
Le provisioner local n'a plus de suppression `when = destroy`, qui aurait
precede le controle de creation lors d'un remplacement Terraform.

Quand le pod existe, le helper compare aussi les ports du manifeste avec
`InfraConfig.PortBindings` du pod reel, adresses/protocoles/ports internes
inclus. Tout changement est refuse avant suspension ou suppression, meme
pour un pod arrete. Le contournement Make des ports deja occupes n'autorise
donc pas de nouveaux ports potentiellement utilises ailleurs. Conserver les
ports existants pour une mise a jour normale. Un changement de ports exige
une migration manuelle planifiee : sauvegarde, controle/migration de l'ancien
etat, arret, verification des ports sur l'hote du moteur et recreation apres
revue. Ne pas supprimer le pod pour contourner un refus d'identite ou d'etat.

Les fichiers contenant des secrets sont en `0600`, leurs repertoires en `0700`.
Sur la VM CI, le manifeste complet canonique est
`/opt/woodpecker/pod-with-secrets.yaml` : il contient `platform-config`,
`platform-secrets`, `bao-seal-key`, les autres ConfigMaps et le Pod. Utiliser ce
fichier pour une sauvegarde complete, pas le seul `platform-pod.yaml` uploade.
Ces fichiers et les archives temporaires ne doivent pas etre publies dans Git.

Un verrou local protege les appels du helper dans le meme repertoire. Il ne
remplace pas une exclusion operationnelle entre deux postes distincts visant
le meme moteur. Une interruption brutale peut laisser le sidecar suspendu :
diagnostiquer son etat avant de le reprendre, sans supprimer le conteneur.

References : [copie depuis un conteneur arrete](https://docs.podman.io/en/latest/markdown/podman-cp.1.html),
[ordre des provisioners OpenTofu](https://opentofu.org/docs/language/resources/provisioners/syntax/).

### Activation CI separee

La fin du setup bootstrap ne garantit ni l'activation du depot Woodpecker,
ni la livraison d'un webhook, ni un job CI reussi. L'ancien scraping OAuth
qui ignorait ses erreurs et injectait des secrets de deploiement est retire.
Suivre [l'activation explicite Woodpecker](woodpecker-activate.md) avec un
fichier de token personnel prive. Les anciennes credentials CI ne sont pas
supprimees automatiquement ; les auditer et revoquer celles devenues inutiles.

Le push Git initial utilise le `HEAD` du checkout source approuve comme
`refs/heads/main`, sans force. Un historique distant divergent arrete le setup
au lieu d'ecraser le depot ; le resoudre apres revue. Un succes anterieur du
resource `git_push` n'est pas rejoue automatiquement par un changement de son
script : ce provisioner est une initialisation, pas un mecanisme de publication.

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

**Restaurer un etat ne restaure pas l'infrastructure ni une revision Flux.**
Un ancien snapshot peut decrire des ressources qui ont deja change. Ne pas
enchainer sa restauration avec un `make k8s-up` sans diagnostic et revue des
plans : les manifests Git courants resteraient la cible de reconciliation.

Pour un rollback de code/configuration, identifier la revision a retablir,
maitriser les reconciliations Flux et verifier la compatibilite des migrations
et des donnees avant de publier/appliquer cette revision. Conserver une nouvelle
sauvegarde avant toute intervention. Pour une perte ou corruption du KMS,
suivre la [reprise complete](disaster-recovery.md), qui est une operation distincte.

La restauration **Raft seule** exige une confirmation explicite de l'identite
du cluster cible, relevee et verifiee avant l'operation :

```bash
make state-restore SNAPSHOT=/chemin/raft.snap \
  CONFIRM_CLUSTER_ID=id-du-cluster-cible
```

Le snapshot Raft contient les états envoyés au backend HTTP et les secrets
stockés dans ce Raft. Il ne contient ni l'état externe du module bootstrap,
ni l'état local du sidecar (`platform-tofu-state`), ni sa clé de scellement.
Sauvegarder ces éléments séparément ; une restauration Raft seule ne constitue
pas une restauration complète du bootstrap.

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
- `platform-tofu-state` -- état local du sidecar, notamment les clés et CA générées
- `platform-wp-agent-data` -- identité/configuration persistante de l'agent CI

Apres un redemarrage :

```bash
# Verifier l'etat d'OpenBao
curl -s http://localhost:8200/v1/sys/health | jq .

# Verifier vault-backend
curl -s http://localhost:8080/state/test

# Si le pod existe encore et est seulement arrete, le demarrer sans suppression
podman pod start platform
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

# Si le pod existe mais est arrete, le demarrer sans le supprimer
podman pod start platform
```
