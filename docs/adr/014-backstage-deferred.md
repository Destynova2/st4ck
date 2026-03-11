# ADR-014 : Backstage IDP — differe (Headlamp + Pomerium suffisent)

**Date** : 2026-03-09
**Statut** : Differe
**Decideurs** : Equipe plateforme

## Contexte

Backstage (Spotify, CNCF Incubating) etait envisage comme Internal Developer Platform (IDP) pour le self-service developpeur, le catalogue de services, et les golden paths.

## Analyse

La stack actuelle couvre les besoins UI/portail :
- **Headlamp** (kubernetes-sigs) : UI K8s, healthmap cluster, navigation resources
- **Grafana** : dashboards observabilite, alertes
- **Pomerium** : proxy authentifiant zero-trust, SSO tous composants
- **Hubble UI** : observabilite reseau

Backstage ajouterait :
- Catalogue de services (service ownership, API docs)
- Software templates (golden paths pour creer des services)
- Plugins ecosystem (K8s, CI/CD, monitoring)

## Decision

**Differer Backstage.** Les besoins actuels sont couverts. Backstage pertinent quand :
1. Plusieurs equipes developpement consomment la plateforme (Gate 3, Cozystack)
2. Besoin de golden paths standardises (templates de deploiement)
3. Catalogue de services necessaire (>20 services)

## Raisons du report

- **Node.js** : runtime lourd pour un environnement air-gapped (node_modules, build)
- **Ressources** : ~1-2 GB RAM, PostgreSQL requis
- **Complexite operationnelle** : plugins a maintenir, mises a jour frequentes
- **Pas de multi-tenant** : une seule equipe plateforme actuellement

## Reconsiderer si

- Phase 3.5 Cozystack deploye (self-service multi-tenant)
- >3 equipes consomment la plateforme
- Besoin de golden paths documentes et reproductibles

## Alternative possible

- **Backstage** si IDP complet necessaire
- **Port** (Getport.io) si IDP plus leger souhaite
