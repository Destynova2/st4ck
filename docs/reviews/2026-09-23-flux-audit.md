# Revue plateforme et migration Flux

Date : 2026-09-23. Branche : `docs/openbao-eso-flux-ownership`, base `db27134`.
Les références distantes ont été relues ; le provider EM de
`feat/karpenter-provider-scaleway` (`ca2e411`) est désormais intégré avec un
backend VM et des réservations durables. Aucune infrastructure appliquée.

## Risques restant ouverts

| Priorité | Constat | Suite requise |
|---|---|---|
| P1 | Les releases OpenBao ont des values de bootstrap à une réplique, puis une mise à l'échelle externe à trois ; une mise à jour Helm peut perdre le quorum | Concevoir et tester le cycle HA d'upgrade, avant d'utiliser `make upgrade` ; voir [ADR-043](../adr/043-flux-platform-ownership.md) |
| P1 | KaaS n'a pas de chaîne Gateway/LB/tenant autoscaling complètement câblée | Activer les fonctionnalités Cilium nécessaires, installer un gestionnaire LB et prouver le périmètre du kubeconfig tenant |
| P1 | Le provider hybride est testé sur des API simulées, pas sur les machines Scaleway ; les issues API ambiguës peuvent nécessiter une reprise manuelle | Recette VM et deux réutilisations EM, réseau/stockage/identités vérifiés ; voir [ADR-044](../adr/044-scaleway-vm-metal-rules.md) |
| P1 | Des commandes de rotation historiques ciblent encore `bootstrap/tofu`, ou la clé Cosign dans l'état security alors qu'elle appartient à PKI | Revoir les rotations et leur propagation ESO/Flux avec tests de reprise ; ne pas les utiliser telles quelles |
| P1 | La migration des propriétaires change l'inventaire Flux | Exécuter la préparation sans pruning avant de publier la révision suivie, puis tester la migration avec données |

Les risques ci-dessus sont distincts des défauts corrigés. Les tests locaux ne
prouvent ni l'installation réelle, ni la conservation des données lors d'une
migration, ni le fonctionnement VM/métal sur du matériel Scaleway.

## Réévaluation de l'ancien audit

| Sujet | État et changement |
|---|---|
| Woodpecker divergent | Supprimé le second chemin de déploiement ; CI de validation, Flux day-2, Make pour l'infrastructure |
| Double propriété Tofu/Flux | Bootstrap conservé dans Tofu ; services transférés par blocs `removed/destroy=false`, procédure explicite côté Flux |
| OpenBao App | Le bootstrap 1 → 3 existait déjà ; contrôle ajouté du leader commun et récupération automatique par effacement des PVC supprimée |
| KaaS Gateway | Doublon du namespace Kamaji retiré, canal experimental imposé pour TLSRoute ; chaîne réseau toujours incomplète |
| Versions | Registre central déjà présent ; son ConfigMap est amorcé une fois par Tofu puis réconcilié par Flux |
| CNPG implicite | Opérateur partagé et étapes certificats, credentials, base, applications explicites ; CA TLS et cron corrigés |
| Storage écrit dans identity | Job Garage limité à storage ; identity synchronise ses credentials via ESO et RBAC restreint |
| Grafana | Un seul propriétaire du secret ; dashboard rendu depuis le JSON réel au lieu du ConfigMap vide |
| PKI Job | Vrai Job Kustomize, sans faux hooks Helm ni TTL ; import explicite de l'intermédiaire manquant |
| Tests image et management-eso | Anciens problèmes déjà corrigés dans la branche relue ; pas de régression introduite |
| Formatage | Contrôle récursif et modules imbriqués intégrés aux vérifications |

## Simplifications adoptées

- Un chemin de livraison des services et un graphe de dépendances inspectable.
- États de migration conservés aux anciennes adresses, sans réimport ni recréation.
- Plus de lecture inter-stack du tfstate PKI pour le stockage.
- Arrêt Flux des feuilles vers les dépendances, en attendant leur suppression.
- Vérificateur des objets effectivement atteignables et tests des scénarios négatifs.

## Validation et limites

- `bash scripts/verify-local.sh` : formatage, validations Tofu, quatre suites
  Scaleway simulées, Kustomize, substitutions, ShellCheck, manifest hauler,
  propriété et dépendances Flux.
- `python3 -m unittest discover -s scripts/tests` : graphe, Garage, OpenBao HA,
  migration sans désinstallation et ordre de suppression, avec API simulées.
- `bash scripts/verify-render.sh` : les 18 releases atteignables rendent ;
  les ressources sans schéma sont signalées comme ignorées par kubeconform.
- Le provider intégré possède des tests Go sur backends simulés et serveur
  HTTP local, dont concurrence/reprise et SDK VM ; aucun appel Scaleway réel.

La prochaine étape d'exploitation est une recette : installation neuve, copie
représentative d'un cluster existant, migration sans perte, réconciliation et
arrêt contrôlé. Les procédures de migration et les règles VM/métal sont dans
les deux ADR cités, pas dans un automatisme activé sur les clusters existants.
