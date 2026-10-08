# Audit Ponytail et qualite du code

Date : 2026-09-26. Branche locale : `docs/openbao-eso-flux-ownership`.
Etat examine : travail non commite, migration Flux et provider Scaleway hybride inclus.

Les constats et scores ci-dessous decrivent la passe initiale. Le suivi des
correctifs du meme jour est ajoute en fin de document ; les anciens numeros
de ligne et overlays de diagnostic ne ciblent plus le code actuel.

## Verdict

**5 constats P1 / Tier 3, 3 constats P2 / Tier 2. Pas de validation production.**

La direction Flux reste pertinente. Les defauts portent surtout sur les
permissions du premier deploiement et sur les transitions apres erreur.
Les tests actuels passent sans couvrir plusieurs contrats du chemin reel.

Ponytail a ete applique comme methode de revue, a partir de son
[skill officiel](https://github.com/dietrichgebert/ponytail/blob/main/skills/ponytail/SKILL.md) :
necessite, code existant, bibliotheque standard, mecanisme natif, dependances
deja presentes, puis modification minimale. Aucun binaire Ponytail ni
installation globale. La grille `cli-audit-code` a ete appliquee aux 12 dimensions.

Audit par echantillonnage centre sur le lot Flux/autoscaling, pas lecture
exhaustive du depot. Lecture approfondie de plus de vingt fichiers : entree
du controleur, fournisseurs EM/VM, reservations, SDK VM, tests, chart/RBAC,
bootstrap Garage, PKI, migration/arret Flux, graphe GitOps, CI et orchestration.
Les gros fichiers ont ete examines par index de symboles et extraits cibles.
Le cycle de vie Karpenter a ete verifie dans la dependance locale epinglee
`sigs.k8s.io/karpenter@v1.14.0`.

## Tier 3 : corrections prioritaires

### F01 - P1 - Garage ne peut pas creer ses Secrets sur un cluster neuf

- **Dimensions / motif** : C5, C9 ; contrat de permissions incomplet.
- **Preuve** : [job.yaml:42](/Users/ludwig/workspace/st4ck/stacks/storage/flux-bootstrap/job.yaml:42) autorise seulement `get, patch` sur les trois Secrets ; [bootstrap.sh:50](/Users/ludwig/workspace/st4ck/stacks/storage/flux-bootstrap/bootstrap.sh:50) les applique cote serveur sans creation prealable.
- **Effet** : un cluster neuf atteint la creation des credentials S3 puis recoit un refus d'autorisation. Le Job ne termine pas ; ses consommateurs Flux restent bloques. La restauration d'un Secret supprime est egalement impossible.
- **Triangulation** : lecture du RBAC et du graphe, plus [contrat Kubernetes SSA](https://kubernetes.io/docs/reference/using-api/server-side-apply/#access-control-and-permissions). Une creation par SSA exige aussi `create`. Les doubles de test acceptent tout `apply` sans evaluer le RBAC.
- **Correction** : precreer explicitement les objets dont le Job remplit les donnees, ou ajouter une permission de creation adaptee au namespace ; conserver la restriction des droits de modification. Tester avec l'identite reelle du ServiceAccount, pas seulement un faux kubectl.
- **Refutation** : montrer une creation de ces trois Secrets avant le Job, ou une permission `create` effectivement accordee a ce ServiceAccount par le graphe livre.
- **Confiance** : HIGH. **Effort** : faible. Pas de reproduction sur API server reel dans cette passe.

### F02 - P1 - Le test KWOK supprime un cluster meme avant sa creation

- **Dimensions / motif** : C5, C10 ; nettoyage sans preuve de propriete.
- **Preuve** : [run.sh:40](/Users/ludwig/workspace/st4ck/karpenter-provider-scaleway/hack/kwok-e2e/run.sh:40) supprime le cluster depuis le nettoyage inconditionnel ; [run.sh:78](/Users/ludwig/workspace/st4ck/karpenter-provider-scaleway/hack/kwok-e2e/run.sh:78) supprime aussi le nom cible avant creation.
- **Effet** : un echec de prerequis suffit a supprimer un cluster homonyme preexistant. `KWOK_CLUSTER` permet de viser un autre nom que celui par defaut. `KEEP=1` ne protege pas de la suppression initiale si le preflight reussit.
- **Reproduction** : seul `kwokctl` est remplace par un enregistreur inoffensif ; `kwok` manque. Le preflight echoue, puis la trace contient `delete cluster --name audit-no-real-cluster`. Aucun vrai cluster n'a ete touche.
- **Correction** : refuser un nom deja utilise, retenir un nom unique et ne nettoyer qu'un cluster cree par cette execution. Le mode de remise a zero doit etre explicite.
- **Refutation** : le nettoyage prouve que cette execution a cree le cluster avant toute suppression.
- **Confiance** : HIGH. **Effort** : faible. Defaut du harnais importe, distinct du provider.

### F03 - P1 - Un refus d'allumage EM devient un faux succes au retry

- **Dimensions / motif** : C5, C10 ; transition d'etat incomplete.
- **Preuve** : [durable.go:110](/Users/ludwig/workspace/st4ck/karpenter-provider-scaleway/pkg/cloudprovider/durable.go:110) enregistre `starting` avant l'appel et conserve cet etat pour toutes les erreurs. Au retry, ce bloc est saute et le NodeClaim est retourne meme si le serveur est toujours arrete.
- **Effet** : un refus explicite `ErrNotStartable` bloque le premier serveur, alors qu'un second serveur disponible n'est pas essaye. La suppression refuse ensuite de liberer cette reservation dite ambigue.
- **Reproduction** : `aaa` et `bbb` arretes, `aaa` refuse l'allumage. Premier Create en erreur ; second Create en succes pour `aaa`, toujours arrete ; un seul appel Start, `bbb` jamais essaye.
- **Correction** : distinguer un rejet definitif d'une reponse inconnue. Traiter le rejet sans faux succes et essayer les autres candidats admissibles ; conserver la protection persistante pour les vrais timeouts ambigus.
- **Refutation** : un test utilisant `New` / `Durable` montre le passage au second candidat apres un rejet definitif, et aucun succes pour le premier serveur arrete.
- **Confiance** : HIGH. **Effort** : moyen. Regression par rapport au comportement couvert par l'ancien [test:392](/Users/ludwig/workspace/st4ck/karpenter-provider-scaleway/pkg/cloudprovider/cloudprovider_test.go:392).

### F04 - P1 - Une mise a jour Helm OpenBao peut casser le quorum

- **Dimensions / motif** : C10, C12 ; Double Ownership sur le nombre de repliques.
- **Preuve** : [main.tf:210](/Users/ludwig/workspace/st4ck/stacks/pki/main.tf:210) et [main.tf:315](/Users/ludwig/workspace/st4ck/stacks/pki/main.tf:315) conservent une replique dans Helm. Le passage a trois est une action externe ; son trigger suit l'identifiant stable de release et le script, pas chaque revision Helm.
- **Effet** : une mise a jour peut ramener un Raft a trois membres sur un seul pod. Le provisioner de retour a trois n'est pas garanti de rejouer. OpenBao Infra et App sont concernes.
- **Reproduction** : ancien manifeste = 1, live = 3, nouveau manifeste = 1 ; le calcul Kubernetes du three-way merge utilise pour ce type de mise a jour produit `{"spec":{"replicas":1}}`.
- **Correction** : separer l'amorcage 1 -> 3 de l'etat cible durable a trois, puis faire gerer cet etat par un seul proprietaire. Tester une vraie mise a jour de chart sur un Raft deja forme avant de reouvrir le parcours generique d'upgrade.
- **Refutation** : une mise a jour Helm d'un cluster existant conserve trois pods et le quorum sans action externe non declaree.
- **Confiance** : HIGH sur la derive de replicas ; l'indisponibilite complete n'a pas ete injectee sur cluster. **Effort** : eleve. Risque deja documente en ADR-043, toujours non corrige, pas une nouvelle regression attribuee a cette passe.

### F05 - P1 - Une creation VM partielle peut survivre a son NodeClaim

- **Dimensions / motif** : C5, C10, C12 ; Resource Leak, contrat de finalisation incomplet.
- **Preuve** : [vm.go:249](/Users/ludwig/workspace/st4ck/karpenter-provider-scaleway/pkg/cloudprovider/vm.go:249) cree l'intention puis la VM ; une erreur peut revenir avant publication de `status.providerID`. Le core Karpenter v1.14.0 n'appelle `cloudProvider.Delete` en finalisation que si ce champ est non vide (`pkg/controllers/nodeclaim/lifecycle/controller.go:234`).
- **Effet** : apres une creation acceptee mais une reponse perdue, supprimer le NodeClaim avant sa recuperation peut laisser la VM et sa Lease sans proprietaire Kubernetes actif. Un timeout de lancement peut mener a la meme finalisation. L'absence de TTL sur les Leases protege les machines, mais ne constitue pas une reconciliation des orphelins.
- **Reproduction** : vrai controleur de cycle de vie Karpenter, faux client Kubernetes et faux Scaleway. Apres finalisation : NodeClaim absent, une VM restante, une Lease restante, zero appel Delete du fournisseur.
- **Aggravation** : [flux-down.sh:9](/Users/ludwig/workspace/st4ck/scripts/flux-down.sh:9) ne verifie que le nombre de NodeClaims. Il peut accepter un arret alors que des intentions orphelines subsistent.
- **Correction** : definir une reconciliation des intentions independante de ce garde-fou du core, protegeant les operations partielles et les suppressions concurrentes ; bloquer l'arret si des reservations actives ou ambigues restent presentes. Ne pas ajouter d'expiration aveugle ou de suppression automatique des Leases.
- **Refutation** : le meme scenario avec le core epingle termine ou garde explicitement suivie la ressource externe, et empeche le demontage premature du controleur.
- **Confiance** : HIGH. **Effort** : eleve. La preuve executee porte sur VM ; revoir aussi le contrat pre-providerID du backend EM.

## Tier 2 : simplifications et couverture

### F06 - P2 - Une creation VM repete la validation distante

- **Dimensions / motif** : C2, C4 ; Duplicate Work, Long Method.
- **Preuve** : [vm.go:199](/Users/ludwig/workspace/st4ck/karpenter-provider-scaleway/pkg/cloudprovider/vm.go:199) valide, puis appelle `GetInstanceTypes`, qui valide encore a [vm.go:159](/Users/ludwig/workspace/st4ck/karpenter-provider-scaleway/pkg/cloudprovider/vm.go:159). Chaque validation SDK relit l'image et le catalogue ; `hydrate` relit ensuite les types/disponibilites.
- **Reproduction** : une seule creation nominale appelle deux fois `Backend.Validate`.
- **Correction Ponytail** : faire circuler le resultat deja obtenu pendant une operation ; reutiliser le type selectionne. Pas besoin d'un nouveau framework de cache. Ne pas mettre en cache les preuves d'appartenance ou l'etat necessaire aux suppressions.
- **Refutation** : des invariants distincts, documentes et testes, exigent ces deux validations completes au meme endroit du cycle.
- **Confiance** : HIGH. **Effort** : faible. Le cout exact en latence/quota n'a pas ete mesure sur Scaleway.

### F07 - P2 - La CI Flux ne teste pas le rendu des charts de la plateforme

- **Dimensions / motif** : C8 ; Test Gap / faux signal de livraison valide.
- **Preuve** : [.woodpecker.yml:60](/Users/ludwig/workspace/st4ck/.woodpecker.yml:60) execute le validateur sans `--render-helm`. [verify-gitops.py:149](/Users/ludwig/workspace/st4ck/scripts/verify-gitops.py:149) ne telecharge ni ne rend les charts dans ce mode. Les tests du chart natif optionnel ne couvrent pas les 18 releases de plateforme.
- **Effet** : une version de chart inexistante, une erreur de template ou certaines values invalides peuvent passer ce job. Le graphe valide ne prouve ni l'existence des versions ni la validite des manifests rendus.
- **Correction Ponytail** : reutiliser `verify-render.sh` dans une etape CI avec ses outils epingles. Ne pas creer un second moteur de verification. Conserver explicites les limites des schemas CRD et des Secrets ESO non resolus hors cluster.
- **Refutation** : une etape CI effectivement raccordee rend toutes les releases atteignables avec les versions de cette revision et echoue sur un chart invalide.
- **Confiance** : MEDIUM, analyse statique ; pipeline distant non execute. **Effort** : moyen.

### F08 - P2 - Deux implementations EM entretiennent une couverture trompeuse

- **Dimensions / motif** : C3, C4, C8 ; Parallel Implementations / Lava Flow.
- **Preuve** : [cloudprovider.go:74](/Users/ludwig/workspace/st4ck/karpenter-provider-scaleway/pkg/cloudprovider/cloudprovider.go:74) garde l'ancienne reservation en memoire ; [durable.go:34](/Users/ludwig/workspace/st4ck/karpenter-provider-scaleway/pkg/cloudprovider/durable.go:34) est le constructeur de production. Les tests historiques passent par `newBase`, notamment les tests de rejet d'allumage qui restent verts malgre F03.
- **Mesure** : couverture inter-paquets des tests existants : ancien Create 92,9 %, ancien Delete 94,7 % ; Durable.GetInstanceTypes 0 %, tout le dispatch Hybrid 0 %, VM.Get/List 0 %, controleur de statut VM 0 %. Les reservations, elles, sont bien exercees indirectement : ne pas interpreter l'absence de tests propres au paquet comme une absence totale de couverture.
- **Correction Ponytail** : porter d'abord les scenarios utiles sur le constructeur de production, puis retirer les anciens Create/Delete, la table de reservations en memoire et leurs helpers devenus inutiles. Garder les helpers d'inventaire et de conversion encore utilises. `Store.Owned` n'a pas d'appelant dans le module et peut etre retire si aucun besoin concret ne le justifie.
- **Refutation** : un appelant de production depend reellement de l'ancien cycle de reservation, ou les tests actuels exercent le dispatch de production complet.
- **Confiance** : HIGH, graphe d'appels, mesure de couverture et reproduction F03. **Effort** : moyen a eleve.

## Score cli-audit-code

**CQI : 5,9 / 10 sur le perimetre examine.** Evaluation humaine ponderee,
pas score d'un analyseur automatique ni moyenne de tout le depot.
Les P1 restent bloquants quelle que soit la moyenne. Pas d'estimation SQALE
en heures : la recette materielle et la migration HA ne sont pas mesurees.

| Dimension | Poids | Score / 1 | Contribution / 10 | Justification |
|---|---:|---:|---:|---|
| C1 Nommage et lisibilite | 8 % | 0,80 | 0,640 | Responsabilites et chemins generalement identifiables |
| C2 Fonctions et complexite | 12 % | 0,50 | 0,600 | Longs cycles Create/bootstrap, validations repetitives |
| C3 Modules | 10 % | 0,60 | 0,600 | Interfaces backend utiles, double implementation EM |
| C4 DRY | 8 % | 0,50 | 0,400 | Moteurs et lectures distantes dupliques |
| C5 Erreurs et robustesse | 10 % | 0,40 | 0,400 | Rejet definitif/ambiguite et finalisation incomplets |
| C6 Types et idiomes | 8 % | 0,70 | 0,560 | Interfaces Go, erreurs typees ; phases encore en strings |
| C7 Documentation | 5 % | 0,75 | 0,375 | ADR et limites explicites, commentaires historiques parfois perimes |
| C8 Tests | 12 % | 0,50 | 0,600 | Bons cas negatifs, mais chemins de production importants absents |
| C9 Securite et validation | 10 % | 0,70 | 0,700 | Secrets confines, ownership controle ; RBAC Garage incomplet |
| C10 Etat | 7 % | 0,50 | 0,350 | CAS et persistence utiles, transitions/orphelins a terminer |
| C11 Charge cognitive | 5 % | 0,60 | 0,300 | Enchainements multi-etapes et deux modeles EM |
| C12 Architecture | 5 % | 0,70 | 0,350 | Propriete Flux clarifiee ; interfaces de cycle de vie a fermer |
| **Total** | **100 %** | | **5,875** | Arrondi a 5,9 |

## Points solides

- Flux possede un graphe explicite, avec verification des cycles et doubles proprietaires.
- Le provider natif reste hors du graphe actif et desactive par defaut.
- Les reservations persistantes avec comparaison de version et controle d'UID evitent de reprendre arbitrairement une machine appartenant a une autre demande.
- Les tests couvrent deja des timeouts, redemarrages, changements de tags, tailles VM et secrets de bootstrap invalides.
- Les garde-fous sur les disques non locaux et les frontieres de secrets doivent rester presents pendant la simplification.
- Le diagnostic HA n'efface plus de PVC pour masquer un echec.

## Verifications de cette passe

| Verification | Resultat | Limite |
|---|---|---|
| `go test -race -coverprofile=... ./...` | Succes | Simulateurs et HTTP local, pas Scaleway reel |
| `go test -coverpkg=./... -coverprofile=... ./...` | Succes ; couverture agregee 58,7 % | Inclut executables, simulateur et code genere ; pas un indicateur de surete a lui seul |
| 24 tests Python | Succes | Doubles kubectl, pas d'autorisation RBAC reelle |
| Graphe GitOps | 112 objets, 16 Kustomizations enfants, 18 releases | Pas de rendu Helm dans cette commande |
| Format Tofu et `git diff --check` | Succes | Aucune garantie fonctionnelle |
| 4 diagnostics Go ajoutes via overlay temporaire | F03, F04, F05, F06 reproduits | Leurs assertions caracterisent les defauts, elles ne les corrigent pas |
| Preflight KWOK avec commande factice | F02 reproduit | Aucune suppression reelle |

Reproductions temporaires, sans modification des sources du provider :
[audit_test.go](/tmp/st4ck-audit-20260926/audit_test.go),
[overlay.json](/tmp/st4ck-audit-20260926/overlay.json),
[trace KWOK](/tmp/st4ck-audit-20260926/kwok-calls.log).
Elles dependent de ce checkout et ne sont pas des tests durables du depot.

Commande de reproduction Go depuis `karpenter-provider-scaleway` :

```sh
rtk proxy go test -overlay=/tmp/st4ck-audit-20260926/overlay.json ./pkg/cloudprovider -run TestAudit -count=1 -v
```

Pas de deploiement, de provisionnement Scaleway, de modification de secrets,
de commit ni de push. `orca.yaml` et les changements preexistants sont preserves.
Le rendu des 18 charts, les builds multiarchitecture et les tests Tofu complets
annonces lors du lot precedent ne sont pas presentes comme reexecutes ici.

## Ordre recommande

1. Corriger F01 et F02, avec tests de permissions et de nettoyage.
2. Fermer F03/F05 sur le cycle de vie reel Karpenter avant toute activation native.
3. Fermer F04 avant un upgrade OpenBao ; traiter l'etat existant autant que l'installation neuve.
4. Porter les tests sur le chemin de production, supprimer les doublons EM et les lectures VM repetitives, raccorder le rendu Helm a la CI.
5. Recette en laboratoire : installation Flux neuve, migration avec donnees, mise a jour HA, puis cycles VM -> EM -> VM, drain/PDB, pannes API et reprise apres interruption.

La politique de bascule fondee sur une charge soutenue pendant deux heures
n'est toujours pas implementee. Les poids des NodePools et delais de
consolidation ne la remplacent pas. KaaS/Gateway reste egalement un chantier
distinct. Aucun nouveau controleur de politique n'est propose avant de
stabiliser les contrats de creation, de reprise et de suppression existants.

Passes complementaires pertinentes apres correction : `cli-audit-test` pour
le contrat core/provider et les droits reels, `cli-audit-shell` pour les
scripts de destruction, `cli-audit-sync` pour les anciens parcours KaaS et
les comptages de releases. Elles n'ont pas ete executees dans cette passe.

## Suivi des correctifs du 2026-09-26

| Constat | Modification | Verification et limite |
|---|---|---|
| F01 | Droit de creation des Secrets dans `storage`, modifications toujours restreintes aux trois noms | Contrat RBAC et bootstrap testes ; autorisation ensuite verifiee sur une API Kubernetes locale reelle (voir ci-dessous) |
| F02 | Nom KWOK unique, refus d'adoption, nettoyage conditionne a une creation reussie | Cinq scenarios sans vrai cluster : prerequis, nom existant, creation echouee, nettoyage propre et KEEP |
| F03 | Phase persistante `rejected`, confirmation stopped, candidat suivant ; ambiguite toujours conservee | Tests via le constructeur durable, notamment refus du dernier serveur et passage au suivant |
| F04 | Amorcer une fois a 1, verifier le passage a 3, enregistrer 3 dans Helm ; garde-fous natifs sur HA/PVC | Plans Tofu simules et orchestration shell testes ; upgrade de chart sur vrai Raft encore requis |
| F05 | Finalizer avant creation externe, terminaison pre-providerID, arret Flux bloque par les reservations | Core Karpenter reel avec API simulees : VM acceptee/reponse perdue, issue inconnue, reprise, suppression nominale et echec d'ecriture du finalizer |
| F06 | Reutilisation du chemin interne de selection de types, une seule validation par creation | Compteur de validations ; pas de nouveau cache |
| F07 | Rendu des charts via le script existant dans Woodpecker ; kubeconform v0.8.0 | 18 charts rendus localement ; commande d'installation CI testee ; pipeline distant non lance |
| F08 | Tests historiques transferes au constructeur durable ; anciens Create/Delete et reservations memoire supprimes | Tests race, dispatch hybride VM/EM et erreurs d'identite ; `Store.Owned` inutilise retire |

La couverture inter-paquets mesuree apres ces changements est de 64,0 %.
`Durable.GetInstanceTypes` passe de 0 a 73,7 %, `Hybrid.Create/Get` a 100 %,
`VM.Get/List` a 68,8/78,6 %. Le controleur de statut VM reste non couvert :
ce score n'est pas une certification operationnelle. Aucun nouveau CQI global
n'est attribue sans une seconde revue complete.

Verifications locales : suites Go avec detection des races, `go vet`, builds
Linux amd64/arm64, 36 tests Python, six executions Tofu PKI (fixture puis cinq
plans), validation des stacks et rendu des 18 charts. Les schemas CRD absents
restent ignores explicitement ; les valeurs ESO ne sont pas resolues hors cluster.
La passe finale de `verify-local.sh` termine avec 99 controles reussis et aucun
echec ; `git diff --check` et le format Go sont egalement propres.

### F09 - P1 supplementaire : les anciens tests ecrivaient dans kms-output

La revue du harnais Tofu a revele que
`envs/scaleway/tests/setup/main.tf` ecrivait sans condition un faux certificat
dans le chemin de deploiement `kms-output/root-ca.pem`. Les verifications
globales de cette passe ont execute ce test avant sa decouverte. Le fichier
local contient cette fixture ; son contenu avant execution n'a pas ete
sauvegarde ni verifie, donc aucune preservation de ce certificat n'est affirmee.

Le harnais utilise maintenant `local_file` dans son propre `.fixtures`, supprime
a la fin des tests. Une assertion impose cette isolation. Il faut reexporter
le vrai certificat depuis le bootstrap de reference avant de deployer : ne pas
generer une nouvelle autorite pour masquer le probleme. Aucun acces a la VM
ni remplacement automatique par un certificat suppose correct n'a ete tente.
L'empreinte du fichier de deploiement reste identique avant et apres la passe
finale des tests corriges ; cela ne restaure pas son contenu anterieur.

Les tests cluster historiques ne valident toujours que leur module fixture
et ses variables copiees, pas un plan reel de `envs/scaleway` : limite de
couverture conservee et explicite, distincte du correctif d'isolation.

Le bootstrap depuis la VM est documente dans
[le guide de deploiement](../how-to/deploy.md) : services deja presents, mais
depot complet et outils d'administration a preparer. Aucun deploiement cloud,
commit ou push dans cette passe. L'extension native reste desactivee ; la
politique de charge soutenue deux heures et la recette materielle restent ouvertes.

## Integration locale supplementaire du 2026-09-26

- **KWOK natif PASS** : Kubernetes 1.35.6 sur macOS arm64, core Karpenter
  1.14.0 et constructeur EM durable. NodePool 0 -> 1 -> 0 en 24 secondes :
  NodeClaim Registered/Initialized, providerID identique sur le Node,
  finalisation, serveur simule arrete et aucune Lease de reservation restante.
  Le backend Scaleway et le kubelet sont simules ; aucune VM ou machine EM
  n'a ete creee. Pas de workloads/PDB ni de bascule hybride dans ce scenario.
- **Garage RBAC PASS** : manifeste du depot applique sur la meme API reelle,
  requetes sous l'identite du ServiceAccount. Creation et mise a jour SSA des
  trois Secrets puis verification des valeurs stockees ; lecture/patch d'un
  Secret etranger, creation dans `identity` et suppression refuses (Forbidden).
  Le script `scripts/verify-garage-rbac.py` conserve cette verification.
- **Isolation** : kubeconfig et ports dedies, artefacts propres au run ; les
  cinq tests du nettoyage passent. Le cluster jetable a ete supprime et le
  controleur n'est plus actif. Le kubeconfig habituel n'a pas ete modifie.
- **Non-regression** : `verify-local.sh` rejoue apres ces ajouts, 99 controles
  reussis et zero echec, dont 36 tests Python et les tests Go avec detection
  des races. `shellcheck` du harnais KWOK et `git diff --check` passent aussi.
  Les empreintes du kubeconfig habituel et de `kms-output/root-ca.pem` sont
  identiques avant/apres ; le besoin de reexport F09 reste entier.
- **Rendu Helm rejoue** : 18 charts, aucune erreur de rendu/schema disponible.
  Les schemas CRD absents restent ignores explicitement ; ce succes n'est
  pas une installation des releases ni une resolution des secrets ESO.

Preuves du cycle conservees dans
`/tmp/st4ck-local-validation-20260926/kwok-run2/` (journal du controleur,
NodeClaim enregistre, Node rattache, etats des serveurs avant/apres arret).
Un premier essai, interrompu par une edition du harnais pendant son execution,
a ete nettoye puis rejoue integralement ; seul le second fait foi.

La recette complete Flux/OpenBao n'a pas ete lancee : VM Podman partagee
presque pleine (2,3 Go libres) et harnais `e2e-local.sh` non isole, avec
assertions acceptant des inventaires vides. Ces risques doivent etre fermes
avant une recette sur une VM dediee. Voir le
[plan de validation locale actualise](../how-to/test-local.md).
