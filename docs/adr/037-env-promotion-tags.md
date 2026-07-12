# ADR-037 : Promotion d'environnements par tags, projets Scaleway isolés

**Date** : 2026-07-12
**Statut** : Accepté
**Décideurs** : Équipe plateforme
**Reliés à** : ADR-028 (Flux owner-by-default), ADR-033 (frontière Tofu/Flux)

## Contexte

Tous les clusters suivent aujourd'hui la branche `main` du repo de
management : un bump du registre de versions se propage à chaque
environnement en ≤ 10 min, simultanément. Acceptable tant qu'il n'existe
que du dev ; inacceptable dès qu'un qa/prod existe. Les options de
livraison progressive classiques (Flagger/canary, branches par env,
overlays per-env du registre) ajoutent chacune de la machinerie dans le
cluster ou de la divergence entre branches.

## Décision

1. **Un projet Scaleway par classe d'environnement** (dev, qa, prod) —
   rien en commun : IAM, PN, clusters, states, bootstrap distincts.
   L'isolation est au niveau du cloud, pas du cluster.
2. **Une seule branche (`main`), promotion par tags.** dev suit `main` ;
   qa et prod pinnent un **tag de release** de cette même branche
   (`flux_git_tag` dans `stacks/flux-bootstrap`). Promouvoir = re-tester
   la plateforme **bout en bout dans l'env cible** puis avancer le tag.
   Pas de cherry-pick, pas de branches d'env divergentes.
3. **Pas de Flagger/canary au niveau plateforme** : la granularité de
   promotion est l'environnement entier (projet isolé), testé e2e. Le
   canary intra-cluster reste possible plus tard au niveau workload si
   un vrai besoin apparaît.

## Conséquences

- Le registre de versions reste unique et sans overlay : c'est le tag
  qui fige ce qu'un env consomme, pas une copie du registre.
- Un env cassé par un bump ne peut être que dev (seul suiveur de
  `main`) ; qa/prod ne bougent que par décision explicite (tag).
- Le pipeline de release doit produire des tags testés — le harnais e2e
  par env est le gate de promotion (à outiller : critères de sortie,
  smoke post-déploiement).
- Rollback qa/prod = re-pointer le tag précédent (une variable).
