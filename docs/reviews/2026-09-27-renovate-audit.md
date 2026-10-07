# Audit Renovate - 2026-09-27

## Verdict

Configuration preparee et extraction locale prouvee, **bot operationnel non
prouve**. Aucune version applicative modifiee par cet audit, aucune installation
GitHub App, aucun secret configure, aucune PR creee, aucun cloud ou Podman appele.
Le checkout est partage et contient des modifications non commitees : les
resultats locaux ne decrivent pas le contenu publie de `main`.

## Constats et corrections

1. **P1 - aucune configuration Renovate livree auparavant.** Recherche incluant
   les fichiers caches/non suivis et l'arbre GitHub `main` : aucun fichier
   Renovate, aucune configuration Dependabot, aucun workflow `.github`.
   Ajout de [`renovate.json`](../../renovate.json), sans creer de serveur/bot.
2. **P1 - le registre central etait invisible a l'extraction standard.**
   Sans configuration, aucun resultat pour `versions-configmap.yaml` ou les
   contexts. Le gestionnaire JSONata ajoute extrait 30 des 35 cles du registre
   et les deux versions Talos/Kubernetes des contexts. Les cinq exceptions
   manuelles sont enumerees ci-dessous ; aucun numero de version n'est duplique
   dans la configuration Renovate.
3. **P1 - groupe Velero incomplet sans ses valeurs Helm.** Le chart contient
   `valuesFrom`, pas l'image du plugin. L'extraction initiale ne trouvait donc
   pas le plugin. Ajout du gestionnaire `helm-values` sur les fichiers
   `values-*.yaml` : `velero/velero-plugin-for-aws` est maintenant extrait.
   Chart et plugin partagent `velero-aws`, sans separation majeur/mineur et sans
   automerge. La matrice de compatibilite reste obligatoire : un groupe ne
   garantit ni l'existence de deux mises a jour simultanees, ni leur compatibilite.
4. **P2 - perimetre des gestionnaires explicite.** Flux ne parcourt par defaut
   que `gotk-components.yaml` ; Kubernetes n'a pas de motif par defaut.
   Les chemins bootstrap/Flux sont maintenant declares. Les substitutions Flux
   `${...}` sont desactivees pour la mise a jour native : seul leur registre est
   modifie. Les repertoires de tests/cache, les charts vendores, `orca.yaml`,
   les exports et le manifeste Hauler genere sont exclus.

Ces choix suivent les documentations officielles
[Flux](https://docs.renovatebot.com/modules/manager/flux/),
[Kubernetes](https://docs.renovatebot.com/modules/manager/kubernetes/) et
[JSONata](https://docs.renovatebot.com/modules/manager/jsonata/).
Les versions de charts (`flux2`, `openbao`, `cloudnative-pg`, etc.) utilisent
la datasource Helm, pas les releases de l'application. Les deux charts OCI
utilisent Docker ; CAPI, Gateway API, Talos et Kubernetes utilisent GitHub Releases.

## GitHub : preuve distincte du moteur local

Lecture authentifiee via `gh api`, sans afficher les credentials et sans ecriture,
sur [`Destynova2/st4ck`](https://github.com/Destynova2/st4ck) :

| Controle | Observation au 2026-09-27 |
|---|---|
| Depot | Public, non archive, branche par defaut `main` |
| Dernier push retourne par l'API | `2026-07-22T06:59:23Z` |
| Arbre distant recursif | Non tronque ; aucun chemin Renovate ou `.github` |
| PR, tous etats, pagination complete | 3 PR ; aucune correspondance Renovate (auteur, titre ou branche) |
| Issues et PR, tous etats | 5 elements ; aucun Dependency Dashboard/Renovate |
| GitHub Actions | 0 run retourne ; donc aucun journal Actions a examiner |
| Checks du commit `main` | 0 check retourne |

L'absence de PR/checks **ne prouve pas** l'absence d'une App installee ni d'un
serveur externe. Installation, permissions, planification, politique heritee et
journaux du service Mend/self-hosted restent inconnus. Aucun acces au Gitea local
n'a ete tente. Ne pas presenter la configuration ajoutee comme une surveillance
active ou une preuve de PR publiees.

## Validation reproductible

Moteur officiel **Renovate 44.115.11**, release publiee le
`2026-09-27T10:30:41Z`, confirmee via l'API GitHub et le paquet npm ;
Node **24.15.0**. Voir la
[release officielle](https://github.com/renovatebot/renovate/releases/tag/44.115.11).
Outils d'audit uniquement dans un repertoire temporaire, pas d'installation de
service. Le module RE2 natif a ete charge : aucun recours silencieux a RegExp
dans la validation finale.

[`scripts/tests/test_renovate.py`](../../scripts/tests/test_renovate.py) copie les
sources de dependances publiques dans une fixture temporaire sans `.git`, state,
credentials ou exports. Elle ajoute des sentinelles d'exclusion, retire les
variables d'authentification de l'environnement enfant et execute le moteur
avec `--platform=local --dry-run=extract`. Aucune recherche de nouvelles versions,
creation de branche ou execution de provisioner n'est effectuee. Le
[mode local officiel](https://docs.renovatebot.com/modules/platform/local/)
reste experimental ; ce test ne simule pas la plateforme GitHub.

Commande exacte de la verification moteur de cet audit :

```sh
rtk proxy env RENOVATE_PACKAGE=/private/tmp/st4ck-renovate-audit.g0sOqd/runtime/node_modules/renovate RENOVATE_AUDIT_OUTPUT_DIR=/private/tmp/st4ck-renovate-audit.g0sOqd/evidence python3 -m unittest discover -s scripts/tests -p test_renovate.py -v
```

**12 tests reussis, 0 echec, 0 skip.** La suite invoque notamment le
[validateur officiel](https://docs.renovatebot.com/config-validation/)
avec `--strict --no-global renovate.json`, puis compare l'extraction avec/sans
configuration. Elle teste aussi le vrai updater : changer Kratos ne change ni
Hydra, pourtant de meme version, ni le commentaire adjacent. Les regles Velero
sont appliquees par le moteur, y compris pour une mise a jour majeure.

Sans installation locale du moteur, la commande ordinaire est :

```sh
rtk proxy python3 -m unittest discover -s scripts/tests -p test_renovate.py -v
```

Elle execute **6 tests de contrat et ignore explicitement 6 tests moteur**, avec
la raison `set RENOVATE_PACKAGE for real Renovate validation/extraction`.
Ces six skips sont : validateur/RE2, registre, contexts, gestionnaires natifs,
exclusions et updater/regles. Ils n'installent rien automatiquement. La discovery
CI actuelle execute les contrats, pas cette preuve moteur additionnelle ; ne pas
presenter le total de discovery incluant ces skips comme autant de tests passes.

Extraction configuree sur 210 fichiers source copies (plus sentinelles) :

| Gestionnaire | Fichiers extraits | Occurrences de dependances brutes |
|---|---:|---:|
| JSONata | 2 | 32 |
| Dockerfile | 3 | 6 |
| Go modules | 1 | 92 |
| Terraform | 25 | 124 |
| Woodpecker | 1 | 6 |
| Helm values | 3 | 3 |
| Kubernetes | 39 | 67 |
| Flux | 19 | 19 |

Ces occurrences ne sont **pas** autant de mises a jour disponibles : Flux contient
17 substitutions et 2 charts locaux ; Terraform signale 8 dependances locales et
39 sans version explicite. Kubernetes inclut les versions d'API, pas uniquement
les images. `helmv3` est active mais n'extrait aucune dependance de chart dans
cette fixture. Woodpecker extrait bien les images referencees par alias YAML ;
Terraform trouve `bootstrap/tofu/*.tf` malgre l'absence de `main.tf`.
Sans configuration, seuls Dockerfile, Go, Terraform et Woodpecker produisent des
resultats ; aucun des 32 pins JSONata n'est extrait.

Preuve locale detaillee et SHA-256 des sources :
`/private/tmp/st4ck-renovate-audit.g0sOqd/evidence/extraction.json`.
Ce chemin est temporaire ; les tests constituent la reproduction durable.

## Limites et coherence documentaire

- Les recherches initiales n'ont trouve aucune promesse Renovate dans la doc.
  L'ajout configure un comportement nouveau, il ne prouve pas une ancienne
  automatisation. La [reference CI](../reference/ci-cd.md) distingue deja
  validation Woodpecker, activation operateur et livraison Flux ; cette distinction
  s'applique aussi au bot Renovate.
- Le [guide upgrade](../how-to/upgrade.md) demande de regenerer Hauler depuis
  les sources. Renovate ne regenere pas `hauler-manifest.yaml` : cette etape et
  sa revue restent requises dans une PR de dependances. Aucun `postUpgradeTasks`
  privilegie n'a ete introduit.
- `garage_chart_version`, `kamaji_git_ref` et `kamaji_image_tag` restent manuels
  car ils pilotent des charts vendores, avec un couplage commit/image pour Kamaji.
  L'image Garage dans ses valeurs est detectee separement : sa PR doit aussi
  verifier la compatibilite du chart vendore.
- `karpenter_version` et `karpenter_capi_provider_version` sont des pins historiques
  non consommes par les ressources du provider natif actuel. Leur suppression
  coordonnee du registre et des variables serait une simplification, hors writeset.
- Les telechargements shell, la liste d'images de miroir et les references
  d'images dans des variables Terraform ne sont pas tous couverts. Ce travail ne
  pretend pas surveiller chaque executable, schema, image ou tag du depot.
- Aucune consultation globale de tous les registres n'a ete lancee : la preuve
  porte sur validation/extraction/remplacement, pas sur la disponibilite ni la
  compatibilite de chaque derniere version. L'audit des versions est separe.

Pour rendre le service operationnel, un operateur devra publier la configuration,
verifier le choix GitHub/Gitea et les permissions du bot, puis conserver un journal
de run et une PR/Dashboard reels. Ce sont des actions distinctes, non executees ici.
Les trois livrables sont nouveaux et non suivis dans ce checkout ; leur absence
de `git diff --stat` est normale. Aucun fichier existant des autres travaux n'a
ete modifie par cette tache.
