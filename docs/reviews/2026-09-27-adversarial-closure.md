# Corrections et seconde revue contradictoire

État : corrections et recette à froid réalisées le 27 septembre 2026, branche
`docs/openbao-eso-flux-ownership`, sans commit ni publication GitHub.
Les fichiers déjà modifiés ont été conservés. `orca.yaml` reste hors périmètre.

## Huit constats initiaux

| Constat | Correction | Preuve / limite |
|---|---|---|
| Adaptateur de métriques sur le mauvais port | 8428 ; test de l'API réelle | Métriques fraîches des quatre nœuds et des pods sur le banc isolé |
| Clé statique dans des fichiers lisibles par tous | Artefacts privés, YAML structuré et permissions resserrées sur la VM | Tests de plan et de lancement simulé ; pas de VM Scaleway provisionnée |
| Fausse conservation de clé dans `launch.sh` | Comparaison du ConfigMap avec la clé réellement montée avant suppression | Tests négatifs ; remplacement local recetté |
| Sauvegarde basée sur un root token inexistant | Session admin révocable ou token explicite ; bundle contenant les états hors Raft | Capture, intégrité et restauration KMS réelle dans un nouveau pod |
| Perte de l'état legacy avant contrôle | Vérification/migration avant suppression ; refus sur incohérence | Tests simulés de migration ; recréation réelle avec état persistant |
| OpenTofu absent du job GitOps | Exécutable issu de l'image Tofu épinglée, contrôle d'architecture ; tests bootstrap inclus | Parité Linux ARM64 des étapes CI ; pas encore un job déclenché par Woodpecker |
| Mise à jour avec manifeste périmé et mauvais provider | Régénération et déclencheurs complets ; sélection local/Scaleway ; verrous conservés | Plans, tests de parcours Make et remplacement local réel |
| Faux succès et nettoyage dangereux de l'ancien E2E | Harnais neuf explicitement isolé, révision exacte, zéro exception et métriques obligatoires | Parcours neuf entièrement réussi sur D, sans reprise ni réparation |

## Défauts croisés supplémentaires

- Les séries node-exporter n'avaient pas le label `node` requis par l'adaptateur.
  Un port corrigé ne suffisait donc pas. Le relabeling et son contrat sont testés.
- Le volume persistant gardait des fichiers `.tf` supprimés du dépôt. Le setup
  renouvelle sa configuration sans toucher aux états ni au verrou providers.
- Le chemin libvirt lisait encore les identifiants Scaleway pour Flux. Les
  entrées sont maintenant choisies par provider, avec une adresse joignable
  depuis le cluster et sans mot de passe dans les arguments de la commande.
- Les mises à jour supprimaient les verrous providers ; la validation utilise
  désormais un répertoire de données temporaire et des verrous en lecture seule.
- L'arrêt bootstrap supprimait les conteneurs et donc l'état legacy. Il les
  arrête seulement. Le reset exige moteur explicite, sauvegarde vérifiée et
  identité KMS concordante ; aucun volume n'est sélectionné par préfixe global.
- Le teardown tuait les redirections Kubernetes de tous les projets. Cette
  action globale a été retirée.
- Les raccourcis de rotation seal/CA visaient des états obsolètes ou détruisaient
  les données avant la reprise. Ils échouent maintenant avant mutation. Cela
  bloque un danger, sans prétendre fournir une rotation non destructive.
- La nouvelle recette a exposé une différence Podman : `secret ls --format json`
  renvoie le texte `json`, contrairement à d'autres sous-commandes. Le contrôle
  utilise `secret exists` et avait correctement refusé de supprimer le pod.
- Les ports SSH Gitea étaient configurables au bootstrap mais figés à 2222
  dans Flux. Le Service, les Endpoints et les parcours local/E2E partagent
  maintenant le port choisi ; les ports invalides sont refusés.
- Les exports distants de credentials sont privés. Les helpers SSH conservent
  les clés hôte dans un fichier dédié et refusent leurs changements ; le premier
  contact reste TOFU sauf clés prévalidées. L'arrêt du tunnel utilise son socket
  de contrôle, pas un PID réutilisable ni une recherche globale de processus.
- La reprise KMS compare l'identité de l'adresse HTTP à celle du nouveau
  conteneur sélectionné avant authentification/restauration. Une redirection
  vers une autre instance est refusée par un test négatif.
- L'activation Woodpecker n'utilise plus le scraping OAuth ni un numéro de dépôt
  supposé. Un helper explicite vérifie identité, dépôt et résultat via API,
  sans injecter les anciens secrets de déploiement. Le webhook interne et l'URL
  OAuth navigateur sont distingués. Une activation ne prouve pas un job réussi.
- Le renouvellement des images Talos remplace le builder, lie le marqueur à sa
  version/recette/identité et arrête le script à la première erreur. Make impose
  build, attente et import dans cet ordre, même en parallèle. La conservation
  d'images refuse désormais toute erreur de retrait d'état avant destruction.
- Les composites Scaleway pouvaient lancer création, attente et installation,
  ou arrêt des services et destruction des VM, en parallèle. Ils sont maintenant
  séquentiels ; les erreurs d'arrêt KaaS/Kubernetes ne sont plus ignorées avant
  suppression de leurs dépendances. Tests avec faux outils et `make -j8`.
  L'export kubeconfig Scaleway est privé et atomique.
- Le teardown CI composite passe par la migration d'état locale et exige un
  bundle vérifié avant mutation. Sa fraîcheur, son appartenance au bon KMS et
  les consommateurs partagés restent à vérifier par l'opérateur. Le raccourci
  `scaleway-nuke`, qui ignorait les erreurs et détruisait le backend trop tôt,
  est désactivé avant mutation, comme les rotations critiques non recettées.

La première tentative à froid avec push non forcé a réellement révélé un commit
README créé automatiquement par Gitea. Elle a échoué avant Talos et n'est pas
comptée comme réussite. `auto_init=false` corrige ce cas, avec test de plan
simulé ; la nouvelle tentative part d'un moteur vide. Le schéma du
[provider Gitea verrouillé 0.7.0](https://github.com/go-gitea/terraform-provider-gitea/blob/v0.7.0/gitea/resource_gitea_repository.go#L380-L386)
ne marque pas `auto_init` comme `ForceNew` : ce changement seul ne remplace pas
un dépôt existant ; le handler de mise à jour n'en réinitialise pas le contenu.
Ce point est vérifié dans le code du provider, pas par un apply sur un dépôt réel.
La découverte des modules
valide désormais tous les dossiers contenant du HCL, pas uniquement ceux ayant
un `main.tf` : le setup interne `bootstrap/tofu` était sinon oublié.
La tentative suivante a passé bootstrap/Talos/CNI/PKI HA et tous les états
préalables, puis échoué avant Flux sur un scan SSH limité à Ed25519. Le harnais
accepte désormais RSA et Ed25519 sans assouplir les algorithmes SSH ; il vérifie
les clés immédiatement après bootstrap, avant de créer Talos. La tentative D
a ensuite réussi complètement, sans reprise ni exemption.

Les autres corrections provider/Flux et leur lecture fichier par fichier sont
dans le [journal détaillé](2026-09-27-provider-flux-review.md).
Le contrat image/import et ses limites sont dans le
[journal image Scaleway](2026-09-27-image-review.md).

## Lecture fichier par fichier

Ce journal distingue lecture complète, extraits ciblés et validation automatique.
Il ne certifie pas une revue manuelle de chaque fichier historique du dépôt.

| Fichier ou ensemble | Travail effectué |
|---|---|
| `scripts/bootstrap-backup.py` | Lecture complète, API/auth, snapshot, cohérence des clés/CA/états, contrôle d'intégrité |
| `scripts/bootstrap-recover-kms.py` | Lecture complète, absence d'écrasement, noms isolés, démarrage KMS seul, vérification AppRole |
| `scripts/bootstrap-reset.py` | Lecture complète, double identité HTTP/Podman, volume explicite, aucune suppression forcée des volumes |
| `scripts/bootstrap-preflight.py` | Lecture complète ; tests de conservation et refus avant destruction |
| `bootstrap/main.tf` | Lecture complète ; génération, permissions, identité et déclencheurs |
| `bootstrap/platform-pod.yaml` | Extraits config/seal, setup et volumes ; template complet rendu par tests |
| `bootstrap/tofu/pki.tf`, `vault.tf`, `providers.tf` | Lecture complète ; localisation des clés et authentification réelle |
| `bootstrap/tofu/gitea.tf`, `woodpecker.tf` | Lecture complète ; erreurs masquées et contrats d'activation CI examinés |
| `envs/scaleway/ci/main.tf` | Extraits génération/permissions/provisioners ; validation et tests mockés du module complet |
| `envs/scaleway/ci/launch.sh`, `outputs.tf` | Lecture complète ; clé utilisée, ordre de remplacement, entrées Gitea |
| `Makefile` | Extraits bootstrap, DR, mise à jour, Flux, libvirt, arrêt et rotations ; tests de parcours sans mutations |
| `scripts/apply-flux-bootstrap.py` | Lecture complète ; sélection d'état, endpoint, SSH et transport des secrets |
| `scripts/setup-woodpecker.py` | Lecture complète ; token privé, identité forge, activation, refus HTTP et absence de preuve pipeline |
| `envs/scaleway/image/*`, `scripts/tests/test_image_build.py` | Journal séparé fichier par fichier ; plans mockés, template exécuté avec faux outils |
| `stacks/flux-bootstrap/variables.tf` | Lecture complète ; entrées communes au script et à l'E2E |
| `scripts/verify-metrics.py` | Lecture complète ; vide, erreur API, ancienneté et valeurs invalides refusés |
| `scripts/verify-platform-ready.py` | Lecture complète ; inventaire attendu, génération et révision exacte |
| `stacks/autoscaling/flux/values-prometheus-adapter.yaml` | Lecture complète ; backend, requêtes et partage des API de métriques |
| `stacks/monitoring/flux-vm/values-vm-stack.yaml` | Lecture complète ; port/service et labels de collecte, comparaison au chart 0.86.0 réel |
| `scripts/e2e-isolated.py` | Lecture par sections ; cible dédiée, snapshot privé, bootstrap, CNI, états AppRole et assertions |
| `.woodpecker.yml`, `scripts/verify-local.sh` | Lecture complète ; dépendances des tests et correspondance des validations |
| `scripts/apply-pki.sh`, `check-openbao-ha.sh`, `flux-down.sh`, `flux-migrate-ownership.sh` | Lecture complète ; ordre et conditions d'arrêt, préconditions concurrentes |
| Tests nouveaux/modifiés du dossier `scripts/tests` | Lecture et exécution ; mocks distingués des preuves sur le banc |
| Guides DR, upgrade, CI, E2E et rotation | Commandes croisées avec les implémentations ; anciennes garanties retirées ou marquées historiques |
| ADR-023 et HLD-001 | Extraits obsolètes corrigés/signalés ; pas de réécriture des décisions historiques |

## Preuves locales

Sur `st4ck-clean-31xyod`, avant mise à l'arrêt avec disques conservés :

- 56 objets attendus, zéro échec et zéro exception à la révision locale
  `534e4f8545a6183e24e718d211befd97b597085e`.
- Métriques CPU/mémoire fraîches des quatre nœuds Ready et métriques de pods valides.
- Nouveau pod `st4ck-dr-audit` restauré à partir du bundle, avec clé d'origine,
  identité KMS conservée et authentification AppRole réussie.
- Après remplacement du bootstrap : trois CA et clé statique identiques octet
  pour octet ; lignées des deux états et identité KMS conservées.
- Passe finale locale du 27 septembre : 108 contrôles, zéro échec,
  212 tests Python et 18 tests de revue Flux réussis, y compris les dernières
  protections de restauration, conservation d'images et premier dépôt Gitea.

La passe complète inclut les tests Go avec race detector, la validation des
modules, les suites OpenTofu simulées (dont le nouveau contrat EM), ShellCheck,
les rendus Kustomize et les contrats du graphe Flux. Le graphe statique comprend
112 objets, 16 Kustomizations filles et 18 releases ; ce n'est pas le même
inventaire que les 56 objets de readiness contrôlés sur le cluster réel.

Artefacts privés dans `/private/tmp/st4ck-clean-e2e.31xyoD`. Ils contiennent des
secrets et ne doivent pas être publiés. Kubeconfig personnel et ancienne CA du
dépôt : empreintes inchangées. Aucun nettoyage du moteur Podman partagé.

## Recette à froid finale

Moteur dédié neuf `st4ck-review-ef0dc64c-d`, contexte
`e2e-review-ef0dc64c-d`, révision de la copie privée
`9bb85db4c21eed9fa99b3d7dea03eb0c26a0185e` :

- Harnais maintenu terminé avec code 0, aucun correctif injecté pendant le run.
- Bootstrap neuf, contrôle SSH précoce, Talos, CNI et stockage par défaut,
  PKI/OpenBao HA, états des services via AppRole puis Flux installés.
- Bonne révision Git, 56 objets attendus, zéro échec et zéro exemption.
- Métriques CPU/mémoire fraîches de tous les nœuds Ready et métriques de pods.
- Deuxième contrôle strict réussi après les métriques ; quatre nœuds Ready,
  tous les pods Ready ou Succeeded.
- Kubescape inclus : trois `node-agent`, l'operator et son storage sont
  Running/Ready dans l'inventaire final, sans désactivation ni exemption.

Résultat relu dans
`/private/tmp/st4ck-clean-e2e.31xyoD/review-ef0dc64c-d/run/result.json`, avec
`metrics.log` et la fin de `platform-strict.log`. Les échecs de convergence
transitoires avant les deux derniers contrôles restent visibles dans le journal.
Les tentatives précédentes conservent leur statut d'échec et leurs disques ;
leurs VM sont arrêtées. Les derniers changements Make et tests, non utilisés
par ce harnais direct, sont validés séparément sur le checkout courant.

## Parité CI

Rejeu local sur le moteur dédié, avec les images déclarées dans Woodpecker et
une copie récente du checkout : préparation Tofu/kubeconform, validation des
28 modules, 56 scénarios OpenTofu sur neuf modules et vérification GitOps réussis.
L'image `alpine/k8s:1.35.4` a exécuté OpenTofu `1.12.5 linux_arm64`, les
212 tests Python et les 18 tests de revue Flux avec succès.

Rendu : 18 charts, 390 ressources, 338 conformes au schéma, 52 sans schéma
disponible explicitement ignorées, zéro ressource invalide et zéro erreur.
Le provider passe aussi avec `go1.26.5 linux/arm64` : formatage, tests avec
race detector, `go vet`, builds Linux amd64 et arm64 sans CGO. Les six étapes
déclarées de la CI sont donc rejouées avec succès dans leurs images exactes.
Ce rejeu ne constitue pas un job réellement déclenché par webhook Woodpecker.
Les durées, versions, révisions, empreintes, tentatives échouées et états des
machines figurent dans la [recette détaillée E2E/CI](2026-09-27-cold-e2e-ci.md).
Un contrôle strict et des métriques fonctionnelles réussissent également après
les six étapes CI ; le banc D reste en fonctionnement.

## Limites

Les tests simulés et le Talos en conteneurs ne prouvent pas un boot sur matériel
réel, une migration VM/Elastic Metal, les disponibilités/quota cloud ou une
restauration complète CNPG/Velero. Le provider reste désactivé par défaut.
Les rotations non destructives de seal/CA restent à concevoir et à recetter.
La destruction globale multi-environnement n'est pas une fonctionnalité validée.
Les références officielles de restauration sont liées dans le guide DR.
