# Reprise après panne

## Périmètre

`make dr-backup-kms` sauvegarde le **KMS bootstrap**, pas la plateforme
complète. Un snapshot Raft seul est insuffisant. Le bootstrap auto-initialisé
utilise `bootstrap-admin` et AppRole ; il n'exporte pas de `root-token.txt`.

| Donnée | Source | Incluse dans le bundle KMS |
|---|---|---|
| États des backends HTTP, clés Transit | Raft OpenBao bootstrap | Oui |
| Clé de scellement statique | Conteneur OpenBao et état externe | Oui |
| État externe du bootstrap | `bootstrap/terraform.tfstate`, ou état CI Scaleway exporté | Oui, chemin explicite |
| État interne, clés privées et CA racine | Volume `platform-tofu-state` | Oui |
| AppRole, tokens, CA et clés intermédiaires exportés | Volume `platform-kms-output` | Oui |
| Manifeste rendu et sources du setup | Hôte et sidecar | Oui |
| Base et dépôts Gitea, configuration Woodpecker | Autres volumes Podman | **Non** |
| Rafts OpenBao Infra/App | PVC Kubernetes | **Non** |
| PostgreSQL, objets Garage, sauvegardes Velero, images zot | PVC et stockage objet | **Non** |

Les clés de la CA racine se trouvent dans l'état du setup, pas toutes dans
`kms-output`. Conserver séparément les autres états locaux utilisés avant
migration vers le backend HTTP, la révision Git et les modifications non
publiées nécessaires au redéploiement.

## Sauvegarder le KMS

Suspendre les applications OpenTofu et les jobs CI pendant la capture. Le
script compare les états avant/après, mais ce contrôle ne remplace pas l'arrêt
des écritures concurrentes dans le backend.

```bash
export CONTAINER_HOST=unix:///chemin/vers/podman.sock
make dr-backup-kms
make dr-verify-backup BACKUP=/chemin/vers/la/sauvegarde
```

Le dossier est privé (`0700`), ses fichiers sont en `0600`. `backup.json`
contient les empreintes SHA-256 et les lignées des états. Le contrôle refuse
une archive incomplète ou corrompue, une clé de scellement différente et des
CA qui ne correspondent pas à l'état interne. Ces empreintes détectent une
altération accidentelle ; elles ne constituent pas une signature d'origine.

Par défaut, le script ouvre une session `bootstrap-admin` avec le mot de
passe du sidecar et la révoque après la capture. Pour une exécution distante,
utiliser un tunnel SSH et `BAO_PASSWORD_FILE`, ou `BAO_TOKEN_FILE` avec une
politique autorisant la lecture de `sys/storage/raft/snapshot`. Ne pas
transmettre de token dans la ligne de commande.

Sur Scaleway, exporter l'état **CI** courant avec `tofu state pull` dans un
fichier privé, puis fournir `BOOTSTRAP_STATE` et `BOOTSTRAP_MANIFEST` à la
cible. Le manifeste doit inclure pod, ConfigMaps et Secret, dont la clé de
scellement. La connexion Podman sélectionnée doit permettre de copier les
états/volumes : un tunnel HTTP seul ne suffit pas.

Chiffrer le bundle avant transfert hors site. Il contient la matière permettant
de déchiffrer les états et de signer des certificats. Le stockage distant ne
doit pas dépendre du Garage que l'on cherche à restaurer.

## Restaurer dans des ressources neuves

Ne pas lancer `make bootstrap` sur un état vide avant de restaurer Raft : cela
créerait de nouvelles clés et CA avant de rétablir les anciennes.

```bash
export CONTAINER_HOST=unix:///chemin/vers/moteur-de-recette.sock
python3 scripts/bootstrap-recover-kms.py /chemin/vers/la/sauvegarde \
  --name recovery-test --port 48200 --output /chemin/prive/recovery-test \
  --confirm-new-resources
```

Le script refuse les noms de ressources déjà présents. Il importe l'état
interne et les exports dans de nouveaux volumes, puis démarre **uniquement
OpenBao**, avec la clé d'origine. Avant toute authentification/restauration,
il compare l'identité HTTP à celle du conteneur créé sur le moteur sélectionné ;
une redirection de port vers une autre instance est refusée.
Aucun setup ou job CI n'écrit avant la restauration.
Il restaure Raft sans `force`, vérifie l'identité du cluster et
l'authentification avec l'AppRole sauvegardée. Il conserve les ressources de
recette pour inspection, y compris en cas d'échec.

Cette commande ne restaure pas Gitea, Woodpecker ni Kubernetes. Pour remettre
un bootstrap complet en service, restaurer aussi ses volumes CI, conserver
les états originaux, puis préparer un manifeste qui référence les volumes
récupérés et les chemins/ports de l'hôte de remplacement. Inspecter le plan :
aucune clé ou CA ne doit être recréée. La promotion vers un environnement
réel reste une opération de reprise supervisée, pas une commande automatique.

## Restaurer Raft sur un KMS existant

Cette opération remplace les données du KMS sélectionné. Arrêter les écritures,
faire une sauvegarde préalable et vérifier son identité.

```bash
curl --fail http://127.0.0.1:8200/v1/sys/health
make state-restore SNAPSHOT=/chemin/raft.snap CONFIRM_CLUSTER_ID=id-du-cluster-cible
```

L'API refuse une clé incompatible ; le script ne contourne jamais ce contrôle
avec `snapshot-force`. Restaurer un état OpenTofu n'annule pas les modifications
de l'infrastructure ou la révision suivie par Flux. Voir la
[référence OpenBao 2.5](https://openbao.org/docs/2.5.x/api/system/storage/raft/)
et les [contraintes du scellement statique](https://openbao.org/docs/2.5.x/configuration/seal/static/).

## Données applicatives

`make dr-backup-cnpg` déclenche une sauvegarde CNPG ; vérifier ensuite sa
condition de succès, pas seulement la création de l'objet. Les sauvegardes
CNPG et Velero placées dans Garage ne protègent pas contre la perte de ce
même Garage sans copie indépendante.

CNPG appartient à Flux. Préparer une restauration PostgreSQL dans un nouveau
`Cluster` CNPG avec `bootstrap.recovery` et sa source externe, dans un overlay
de reprise ; ne pas modifier `stacks/identity/main.tf` ni retirer CNPG d'un
état Tofu. Valider les données avant de basculer les consommateurs. Un exercice
CNPG/Velero complet demeure nécessaire avant de fixer un RPO/RTO.

## Preuves et limites

Le banc isolé du 27 septembre 2026 a validé une capture cohérente et une
restauration Raft dans un nouveau pod, avec conservation de l'identité KMS
et authentification AppRole d'origine. Les tests négatifs couvrent les clés
différentes, états vides, CA incohérentes et snapshots corrompus.

Ce résultat n'est pas une preuve de reprise intégrale : aucune durée de
rétablissement globale, restauration PostgreSQL/Velero ou reprise matérielle
Scaleway n'est garantie par ce test.
