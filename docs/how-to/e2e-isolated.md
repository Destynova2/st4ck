# Recette locale strictement isolee

`scripts/e2e-local.sh` lance le parcours maintenu dans `e2e-isolated.py`.
Sans configuration explicite, il echoue avant tout acces au runtime. L'ancien
parcours a contexte fixe, les resets de tfstate et le manifeste Flux alternatif
ont ete retires. `e2e-nightly.sh` delegue au meme parcours sans push, skip vert,
reprise implicite ou nettoyage.

## Prerequis

- Un moteur Podman **dedie a cette seule execution**, rootful, vide de pods,
  conteneurs, volumes et secrets, sans reseau personnalise. Les images en cache sont
  permises. Ne pas vider un moteur partage pour satisfaire ce controle.
- Une connexion Podman nommee, **non definie par defaut**, vers un socket Unix
  local existant. Les connexions SSH/TCP sont refusees. Sur macOS, utiliser le
  socket transfere d'une VM dediee, pas celui du moteur quotidien. Le harnais
  ne cree ni ne reconfigure de VM et ne change pas la connexion par defaut.
  Pour Lima, renseigner obligatoirement `lima_instance` : le nom, le socket,
  l'etat Running et le partage writable au meme chemin sont controles.
- Au moins 8 CPU, 28 Gio de RAM visibles via `podman info` (prevoir 32 Gio
  alloues a la VM pour couvrir la reserve du noyau), et environ 120 Gio
  de disque disponibles sur cette VM. L'espace disque n'est pas precontrole.
  Le serveur Podman doit voir le futur `run_dir` **au meme chemin absolu**,
  car le bootstrap monte sa copie du depot dans `/source`.
- Corriger les montages automatiques de cette VM avant creation des noeuds,
  comme explique dans [test-local.md](test-local.md#piege-podman--montage-injecte-dans-talos).
  Le harnais controle les quatre noeuds et refuse `/run/secrets` en lecture seule.
- Python 3 avec PyYAML, Bash, Git, jq, OpenTofu compatible avec les modules
  (CI : 1.12.5), kubectl, Helm, ssh-keyscan et talosctl **exactement** a la version
  de `contexts/_defaults.yaml`. Le CLI et les images utilisent l'architecture
  native du banc. Aucune installation automatique des outils.
  PyYAML doit aussi fonctionner avec un HOME vide : les packages du user-site
  ne suffisent pas. Utiliser un venv prive via `E2E_PYTHON` si necessaire ;
  les provisioners `python3` reutilisent cet interpreteur controle.
- Connectivite aux registres, providers et charts : cette recette n'est pas
  air-gap. Ports declares libres sur l'hote, accessibles depuis le poste et
  publies par la VM. Le port SSH Gitea declare (`2222` dans l'exemple) est
  propage au scan de cle et a `gitea_external_port` de `stacks/flux-bootstrap`.
  Il doit etre libre, comme les six autres ports du bootstrap.

## Configuration obligatoire

Creer un fichier JSON hors du depot, par exemple
`/private/tmp/st4ck-e2e-20260927-a.json`. Exemple a adapter aux chemins reels :

```json
{
  "run_dir": "/private/tmp/st4ck-e2e-20260927-a",
  "context": "e2e-st4ck-20260927-a",
  "podman_connection": "st4ck-e2e-20260927-a",
  "lima_instance": "st4ck-e2e-20260927-a",
  "subnet": "10.59.0.0/24",
  "talosctl": "/chemin/absolu/talosctl-v1.12.9",
  "ports": {
    "kms": 43820,
    "kms_cluster": 43821,
    "vb": 43808,
    "gitea_http": 43300,
    "gitea_ssh": 2222,
    "wp_http": 43800,
    "wp_grpc": 43900
  },
  "timeout_minutes": 45,
  "metrics_timeout_minutes": 10
}
```

Le repertoire final `run_dir` ne doit **pas exister**, meme vide. Son parent
doit exister. Le chemin doit etre canonique, hors du depot, sans lien symbolique,
espace ni metacaractere shell (`/private/tmp` sur macOS, pas son alias `/tmp`).
Le contexte doit commencer par `e2e-` et etre unique. Le /24 prive doit etre
reserve a ce banc, sans chevauchement avec les reseaux de l'hote/VM ; le harnais
refuse les plages Kubernetes par defaut mais ne peut pas prouver toutes les
routes de la VM. `talosctl` est facultatif si la bonne version est deja sur PATH.
`lima_instance` doit etre omis pour un moteur Unix natif hors Lima.

### Preparation Lima macOS

Creer une VM neuve nommee explicitement, avec 8 CPU, **32 Gio alloues**, un
disque de 120 Gio et seulement le parent prive de `run_dir` partage en ecriture
au meme chemin. Ne pas partager le depot de travail ni le HOME. Avant toute
creation Talos, le provisionnement de cette VM doit creer un fichier
`/etc/containers/mounts.conf` vide ; le precontrole exige qu'il existe et soit
vide. Conserver le transfert du socket rootful `/run/podman/podman.sock` vers
`{{.Dir}}/sock/podman.sock` et le forwarding automatique Lima.

```bash
rtk proxy podman system connection add --default=false st4ck-e2e-20260927-a unix:///Users/USER/.lima/st4ck-e2e-20260927-a/sock/podman.sock
rtk proxy python3 -m venv /private/tmp/st4ck-e2e-tools-20260927-a
rtk proxy /private/tmp/st4ck-e2e-tools-20260927-a/bin/python3 -m pip install PyYAML==6.0.3
```

Verifier que la connexion par defaut n'a pas change. Ne jamais executer
`podman system connection default` pour cette recette. Exporter l'interpreteur
via `E2E_PYTHON=/private/tmp/st4ck-e2e-tools-20260927-a/bin/python3` pour les
commandes suivantes (ou utiliser `rtk proxy env E2E_PYTHON=... bash ...`).

Le wrapper prive `e2e-podman.sh` execute **uniquement `kube play` dans la VM
designee**, via `limactl shell`, avec `--log-driver=k8s-file`. Cela evite le
double forwarding macOS du client Podman distant et de Lima, et permet de
lire les logs depuis le client macOS sans pilote journald. Les autres appels
Podman fixent explicitement le socket Unix. Aucun reglage global de logs,
changement de connexion par defaut ou demarrage implicite de VM n'est fait.

```bash
rtk proxy bash scripts/e2e-local.sh --config /private/tmp/st4ck-e2e-20260927-a.json --check
rtk proxy bash scripts/e2e-local.sh --config /private/tmp/st4ck-e2e-20260927-a.json
```

`--check` effectue uniquement les precontroles : pas de snapshot, commit,
conteneur ou cluster. Des caches clients temporaires peuvent etre crees puis
retires. Pour Lima, le partage declare est controle, pas sa lisibilite effective
depuis un conteneur futur. Ce precontrole ne prouve pas la convergence future.
Le point d'entree Make existant accepte aussi la variable d'environnement :

```bash
rtk proxy env E2E_CONFIG=/private/tmp/st4ck-e2e-20260927-a.json make e2e-local
```

## Parcours et verdict

1. Le harnais copie les fichiers suivis et non ignores, y compris les changements
   non commites, vers `run_dir/repo`. Il exclut etats, caches Terraform,
   `kms-output`, configurations Kubernetes/Talos, tfvars et overrides locaux.
   `orca.yaml` et les fichiers `.orca*` sont egalement exclus.
   Les liens symboliques sont refuses. Les fichiers locaux sensibles sous des
   noms arbitraires doivent rester gitignores : ce filtre n'est pas un scanner
   de secrets. La copie est commitee **uniquement dans son propre depot prive** ;
   l'index, les commits et les remotes du depot de travail restent inchanges.
2. Bootstrap neuf : CA, AppRole, Gitea et etat propres au moteur dedie. Le shell
   et les provisioners recoivent un HOME prive, KUBECONFIG/TALOSCONFIG propres,
   CONTAINER_HOST et DOCKER_HOST fixes au meme socket. Les identifiants cloud,
   variables TF et configurations utilisateur ne sont pas herites.
   Avant de creer Talos, le harnais recupere et controle les cles SSH RSA et/ou
   Ed25519 du Gitea dedie. Il conserve ces cles pour Flux ; aucun algorithme
   faible ni contournement de verification SSH n'est active.
3. Talos cree un CP et trois workers de 6 Go, sans CNI. Le harnais installe la
   stack CNI pendant l'attente Talos, puis exige le succes du controle de sante.
4. PKI via le wrapper a deux phases, puis monitoring et etats de migration
   identity/security/storage/autoscaling. Les stacks utilisent le backend HTTP
   du bootstrap dedie avec AppRole et `/state/e2e/CONTEXTE/STACK`, sans reset,
   migration d'etat existant ni backend local injecte dans le depot de travail.
5. La stack **reelle** `flux-bootstrap` installe Flux et ses credentials ESO.
   La branche main du Gitea dedie doit contenir exactement le SHA du snapshot.
   Aucun push n'est fait vers le Gitea partage.
6. `verify-platform-ready.py` tourne **depuis la copie du depot**, sur sa revision
   exacte et son inventaire attendu. Aucune exemption, pas meme Kubescape.
   Puis `verify-metrics.py` exige des metriques CPU/memoire fraiches pour tous
   les noeuds Ready et des metriques de pods non vides et valides.
7. Les attentes sont bornees (45 min de convergence, 10 min de metriques par
   defaut, plus la duree bornee de la derniere requete). Erreurs API persistantes,
   inventaire absent ou revision incorrecte echouent. La readiness stricte est
   recontrolee apres les metriques ; les quatre noeuds et tous les pods doivent
   etre prets, hors pods termines avec succes.

Seul ce parcours complet ecrit `result.json` avec `PASS`. Les preuves et journaux
restent dans `run_dir`, protege par des permissions privees. Ils peuvent contenir
des secrets, ainsi que les manifestes et tfvars : ne pas publier ce repertoire
comme artefact CI public. Les echecs gardent leurs journaux et retournent un
code non nul. Aucun retry ne passe silencieusement en reparation ou en exemption.

## Conservation et limites

Pas de teardown automatique, meme apres succes. Le harnais ne supprime aucun
pod, volume, etat, secret ou connexion existant. Apres analyse, retirer uniquement
la VM/moteur que l'operateur a cree pour cette execution, en verifiant son nom.
Ne pas utiliser `make local-docker-down`, `make bootstrap-stop`, `podman system
prune` ou une commande globale comme raccourci. Une nouvelle recette exige une
autre configuration, un autre repertoire et un nouveau moteur vide.

Le 27 septembre 2026, la commande maintenue a passe a froid sur le banc D,
revision `9bb85db4c21eed9fa99b3d7dea03eb0c26a0185e`, sans reparation ni
modification pendant l'execution : inventaire strict 56/0/0 avant et apres les
metriques fonctionnelles, quatre noeuds Ready, 94 pods Running/Ready et 14
Succeeded. Les tentatives B et C avaient echoue et restent comptees comme
echecs. Voir le [rapport de recette et de parite CI](../reviews/2026-09-27-cold-e2e-ci.md)
pour les revisions, artefacts prives, resultats et limites. Ce succes ponctuel
ne transforme pas les anciens prototypes repris manuellement en preuves a froid.

Un succes de ce parcours prouve installation, convergence et metriques au
moment du controle. Il ne prouve ni recommandations VPA, detection malware,
endurance, performances, haute disponibilite etcd (un seul CP), upgrade/reprise
avec donnees, restauration Velero, mirror air-gap, pipeline Woodpecker complet,
ni integration cloud/Elastic Metal ou validation materielle.
