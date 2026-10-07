# Kubescape et reconstruction locale, 26 septembre 2026

## Périmètre

Suite de la [première recette partielle](2026-09-26-local-platform-e2e.md).
Branche `docs/openbao-eso-flux-ownership`, modifications non commitées dans
le dépôt de travail. Aucun déploiement Scaleway ni publication GitHub.

Après diagnostic sur le premier banc, création d'une **nouvelle VM** Lima
`st4ck-clean-31xyod` : Fedora 44 ARM64, Podman rootful, 8 CPU, 28 Gio,
120 Gio de disque. Aucun volume, état Tofu ni certificat du premier banc
n'a été réutilisé. Nouveau bootstrap, nouvelles CA, nouveau cluster Talos
1.12.9 / Kubernetes 1.35.6 : un control plane et trois workers, 6 Go chacun.
Ce sont des nœuds Talos conteneurisés, pas quatre VM Talos indépendantes.

Le premier passage strict valide la révision
`07c279200640655d5da54a38102db25091457fb8` du Gitea jetable : 18 releases Ready,
56 objets attendus, zéro échec et aucune exemption. La copie est ensuite
actualisée vers `e18589f3fdd46eec086029da2bcd94f085f3be36` pour les derniers
correctifs bootstrap et tests, sans changement du graphe Flux. Le second
passage strict valide également cette révision sans échec ni exemption.
Les comptes
rendus sont postérieurs à cette copie. Les stacks utilisent leurs états locaux
isolés ; le backend HTTP/AppRole est exercé séparément.

Artefacts privés : `/private/tmp/st4ck-clean-e2e.31xyoD`.
Ce répertoire contient des secrets jetables : ne pas le publier. Le pilote
temporaire `control.py` n'est pas un harnais de recette maintenu dans le dépôt.
La VM précédente `st4ck-e2e-hvyapz` est arrêtée, son disque est conservé.

## Cause Kubescape

Fedora injectait `/usr/share/rhel/secrets:/run/secrets` en lecture seule via
`/usr/share/containers/mounts.conf`. Ce montage apparaissait dans
`/proc/1/mountinfo` des nœuds Talos et se propageait via le `hostPath /run`
de l'agent. Le montage du jeton de service account échouait alors sur un
système de fichiers en lecture seule, avant même de lancer l'agent.

Sur le premier banc, le retrait ciblé de ce seul montage dans les workers
a suffi : trois agents à 2/2 et release Ready. Sur la nouvelle VM,
`/etc/containers/mounts.conf` est vide dès le provisionnement, avant création
des nœuds. Les quatre nœuds sont contrôlés ; aucune injection n'est présente.
Le chart Kubescape **1.40.2 reste inchangé**, sans suppression du compte de
service, du scan, ni ajout d'une exemption au verdict.

Le démarrage à froid donne trois agents à 2/2, un opérateur et un stockage
Ready, sans redémarrage. Preuve : `kubescape-cold-start.json`.
Le script `check-talos-container-mounts.sh` détecte désormais ce montage et
`local-docker-up.sh` l'appelle avant d'installer les services.
Voir la [priorité des fichiers mounts.conf](https://github.com/containers/common/blob/main/docs/containers-mounts.conf.5.md).

## Autres défauts du démarrage à froid

1. Le bootstrap mélangeait `Secret` et `ConfigMap` dans `--configmap`, que
   Podman refuse. Le manifeste local généré est maintenant autonome et privé
   (0600), avec configuration, secrets et pod dans le même document multidoc.
2. Podman détectait un Dockerfile voisin et tentait un build implicite de
   vault-backend vers un tag contenant un digest. `--build=false` rend le
   lancement explicite sur le moteur Linux ; le build volontaire reste une
   cible séparée. Le lanceur détecte les options proposées et omet ce drapeau
   sur le client distant macOS, qui ne sait pas construire d'image.
   Voir [Podman kube play](https://docs.podman.io/en/latest/markdown/podman-kube-play.1.html).
3. Les digests OpenBao 2.5.1 et Matchbox 0.10.0 du bootstrap désignaient des
   images amd64. Ils ciblent maintenant les index multiarchitectures, sans
   changement de version. Les sept images exécutées dans le nouveau pod
   sont Linux ARM64 ; ce contrôle ne constitue pas un audit de tous les
   digests de tout le dépôt.
4. L'état interne du setup était éphémère. Le volume `platform-tofu-state`
   conserve maintenant l'état et les CA. Un état absent face à une PKI
   existante arrête le setup avant initialisation. L'injection de variables
   passe par `TF_VAR_*`, sans `eval`.
5. Talos 1.12.9 n'accepte pas `--wait=false` sur le provisionneur Docker.
   Le script local attend maintenant API et enregistrement des nœuds pendant
   que le contrôle de création tourne, puis installe le CNI. Il propage les
   erreurs du processus et ne laisse pas son vérificateur tourner après
   `SKIP_CILIUM=1`. Quatre tests ciblés couvrent ces comportements.
6. La sonde `httpGet` de Matchbox était traduite en appel à `curl` par Podman,
   mais l'image ne contient pas cet outil. Le service répondait puis était
   redémarré toutes les trois sondes échouées. Une sonde `exec` utilise
   maintenant `wget`, présent et testé dans cette image, avec délai borné.
   Le pod bootstrap entier est recréé une seconde fois pour vérifier ce
   correctif et la conservation de sa PKI.

La migration d'un bootstrap existant nécessite de récupérer son ancien état
**avant** de recréer le pod. Voir la [procédure et ses limites](../how-to/upgrade.md#conservation-de-letat-interne).

## Contrôles réalisés

| Contrôle | Résultat |
|---|---|
| Analyse locale | 102 contrôles réussis, zéro échec ; 61 tests Python, tests Go avec race detector et tests Tofu simulés inclus |
| Talos et CNI | Quatre nœuds Ready ; Cilium et local-path installés à froid |
| Bootstrap recréé | Trois CA identiques et même lignée d'état après remplacement du pod entier |
| État setup manquant | Initialisation refusée ; CA existante préservée |
| Backend HTTP/AppRole | Écriture, lecture, verrouillage, plan idempotent et destruction de la seule ressource de test |
| OpenBao Infra et App | Trois membres par cluster, identifiant commun, accord de leader ; remplacement réel des pods 0 et plan PKI sans changement |
| ESO | Secret SSH Flux supprimé puis recréé avec nouvel UID et données strictement identiques, non affichées |
| Kubescape | Installation Helm réussie à froid ; trois agents à 2/2, opérateur et stockage Ready |
| Flux complet | Dernière révision : 18/18 releases et 17/17 Kustomizations Ready ; 56 objets attendus, zéro échec, zéro exemption |
| Santé effective | 94 pods actifs prêts, CNPG à 3/3 ; aucune pression mémoire, disque ou PID déclarée par les quatre nœuds |
| Matchbox | Cinq sondes consécutives réussies et zéro redémarrage après correction |
| Garage S3 | Écriture puis relecture identique de 1 Kio ; seul l'objet jetable est supprimé |

Preuves : `verify-local-closure.log`, `bootstrap-probe-final.log`,
`state-probe-final.log`, `ha-probe.log`, `pki-idempotence.log`,
`eso-probe.log`, `s3-probe-final.log`, `bootstrap-architecture.json`,
`kubescape-cold-start.json`, `platform-initial-strict.log` et
`platform-final-strict.log`. L'inventaire final est dans
`platform-final-inventory.json`, sa synthèse dans `platform-runtime-summary.log`,
les sondes Matchbox dans `matchbox-health-final.log`.

## Interventions et limites

Cette reconstruction part d'états vides mais n'est **pas un parcours sans
intervention** : les premiers lancements ont révélé les défauts Podman et
Talos ci-dessus, puis ont été repris après correction. Une injection de panne
OpenBao lancée trop tôt a interrompu le seed Grafana (403) ; l'application a
réussi après la fin de ce test, sans élargissement des droits. Ne pas lancer
les tests de panne en parallèle des écritures de bootstrap.

Un collecteur VictoriaLogs limité à 128 Mio a subi trois OOM au démarrage,
puis est redevenu Ready sans intervention. L'inventaire final ne montre aucun
pod actif non prêt ni pression mémoire/disque sur les quatre nœuds. Cela
valide l'état final, pas l'endurance ni le dimensionnement sous charge ; le
budget mémoire de ce collecteur reste à qualifier. Des redémarrages de
démarrage KEDA, Pomerium et control plane sont également conservés dans
`platform-runtime-final.json`, et ne sont pas effacés du bilan.

Le test valide le démarrage de Kubescape, pas la détection d'une menace ou
la réception d'une alerte. Aucun test EICAR concluant n'est ajouté ici.
Les services et points de santé Woodpecker/Matchbox répondent, mais aucun
pipeline CI complet ni démarrage PXE n'a été exécuté. Karpenter matériel
reste opt-in : bascule VM/EM sous charge, drain/PDB, restauration Velero,
upgrade OpenBao et migration de données existantes restent à recetter.

Le kubeconfig habituel et les fichiers KMS réels sont laissés à l'écart.
La CA réelle du checkout, déjà signalée comme fixture invalide, n'est pas
restaurée par ce banc : réexporter la CA canonique avant un vrai déploiement.

Le moteur partagé compte finalement 50 conteneurs, dont 35 actifs, et 127
volumes. Un nouveau conteneur et un volume `k4di-catalog-qualification` ont
été créés par un autre travail pendant la recette ; ils n'ont pas été
modifiés. Les volumes détachés `deploy_nativedbdata` et
`deploy_nativedbreplicadata` sont toujours présents, les empreintes du
kubeconfig habituel et de la CA du checkout sont inchangées.

La nouvelle VM reste allumée à la fin de la recette. Son kubeconfig isolé
est `/private/tmp/st4ck-clean-e2e.31xyoD/kubeconfig`, contexte
`st4ck-clean-31xyod`. Pour libérer ses ressources sans supprimer son disque,
arrêter explicitement cette seule instance avec
`limactl stop st4ck-clean-31xyod`. Ne pas arrêter le moteur Podman partagé.
