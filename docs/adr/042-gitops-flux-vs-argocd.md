# ADR-042 : GitOps — Flux confirmé face à ArgoCD

**Date** : 2026-07-15
**Statut** : Accepté — documente un choix historique, avec ses conditions de réexamen
**Décideurs** : Équipe plateforme
**Reliés à** : ADR-028 (Flux owner-by-default), ADR-033 (frontière Tofu/Flux), ADR-034 (Hauler, phase OCIRepository), ADR-037 (promotion par tags)

## Contexte

Flux v2 est l'owner day-2 de la plateforme depuis l'origine, mais aucun
ADR ne trace le « pourquoi pas ArgoCD » — la question revient à chaque
revue. Les deux sont CNCF graduated, Helm/Kustomize/multi-cluster, drift
detection. La différence est philosophique : ArgoCD est *UI-first* avec
un serveur applicatif et son propre RBAC ; Flux est *CRD-first*, sans UI,
sur le RBAC Kubernetes natif.

## Ce qui ancre Flux dans NOTRE architecture

Au-delà des généralités, quatre mécanismes de la plateforme reposent sur
des primitives Flux sans équivalent direct ArgoCD :

1. **Le registre de versions unique** (`versions-configmap.yaml`) est
   consommé via `postBuild.substituteFrom` — chaque Kustomization enfant
   déclare sa substitution (non héritée, bug attrapé puis verrouillé par
   verify-local). ArgoCD n'a pas d'équivalent natif ; il faudrait un
   plugin de rendu ou générer les manifests.
2. **Les chaînes two-phase** (ESO→HR, HR→policies — ADR-033) utilisent
   `dependsOn` + health checks des Kustomizations/HelmReleases,
   validées de bout en bout par l'E2E local du 2026-07-15 (kyverno
   relâchée, zot correctement retenue).
3. **La remediation déclarative des HelmReleases** (retries,
   `cleanupOnFail`, rollback) porte la story « update sans perturber les
   workloads » (durcissement 2026-07-12).
4. **OCIRepository natif** est la phase 3 d'ADR-034 (charts servis par
   hauler en air-gap) ; côté ArgoCD le support OCI est plus récent et
   moins central.

S'y ajoutent : empreinte minimale (controllers purs, pas de serveur ni
d'UI = surface d'attaque réduite), bootstrap Tofu propre (flux-bootstrap
seed SSH + GitRepository), et RBAC 100 % Kubernetes — pas de second
modèle d'autorisation à auditer.

## Ce qu'ArgoCD ferait mieux — et nos réponses

- **Visibilité équipes** (état de sync, diffs, historique en 1 clic) :
  c'est SA vraie force. Notre réponse actuelle : **Headlamp est déjà
  déployé** (stack monitoring) et son plugin Flux couvre l'essentiel de
  la lecture ; `flux get`/events pour le reste. Si des équipes produit
  non-ops arrivent (KaaS), réévaluer — d'abord via Capacitor/Weave
  GitOps (UIs Flux), ArgoCD en dernier recours.
- **App-of-Apps / ApplicationSets** : notre équivalent est la
  Kustomization racine + `clusters/management/` — suffisant à notre
  échelle de fleet (le multi-env passe par des clusters indépendants,
  ADR-037, pas par un ArgoCD central).

## Décision

1. **Flux v2 confirmé** comme unique moteur GitOps day-2, sur tous les
   environnements. Pas de cohabitation ArgoCD (deux réconciliateurs =
   deux owners qui se battent — même argument qui a écarté Zarf en
   ADR-034).
2. **Conditions de réexamen explicites** : (a) des équipes non-ops ont
   besoin d'une UI de déploiement self-service ET les UIs Flux ne
   suffisent pas ; (b) le KaaS exige une distribution d'apps par tenant
   que ni Flux-par-tenant ni Sveltos (en évaluation phase A) ne couvrent.
   Hors ces cas, la question est close.

## Conséquences

- Fin des débats récurrents Flux/ArgoCD en revue : pointer ici.
- Les investissements session 2026-07 (substitution du registre,
  two-phase, E2E local Flux) sont actés comme des actifs structurants —
  changer de moteur les invaliderait, le coût de sortie est nommé.
- La réponse UI reste Headlamp(+plugin Flux) : à outiller dans la doc
  d'exploitation plutôt qu'à résoudre par un second control plane.
