# ADR-036 : Débloquer l'autoscaling Scaleway — où investir l'effort de dev

**Date** : 2026-07-11
**Statut** : Proposé
**Décideurs** : Équipe plateforme
**Reliés à** : ADR-024 (autoscaling hybride), ADR-035 (pool EM statique — constats upstream)

## Contexte

L'ADR-035 a gelé l'autoscaling Elastic Metal sur deux blocages upstream :
CAPS (cluster-api-provider-scaleway) ne pilote que des Instances, et
karpenter-provider-cluster-api est un proof-of-concept. La question posée
ici : plutôt qu'attendre, **où investir un effort de développement pour
débloquer la chaîne** — et lequel a le meilleur ratio effort/levier.

## Options

### A — Contribuer le support Elastic Metal à CAPS
Ajouter un backend EM à `ScalewayMachine` (offre, flow install/rescue ou
image pré-appliquée, PN par AZ).

- Levier : débloque toute la chaîne CAPI (dont karpenter-capi et les
  MachineDeployments tenants ADR-025) avec le provider officiel.
- Coût/risques : API v1alpha2 jeune et mouvante ; buy-in mainteneurs
  inconnu (aucun signal EM dans le repo) ; le cycle de vie EM (~1 h
  d'install, facturation à l'heure) se modélise mal dans les timeouts
  Machine de CAPI ; e2e sur du métal payant.
- Premier pas gratuit : **ouvrir l'issue upstream** (brouillon en annexe)
  pour jauger l'intention avant d'écrire une ligne de Go.

### B — Développer un `karpenter-provider-scaleway` natif (recommandée)
Implémenter l'interface cloudprovider de Karpenter directement sur l'API
Scaleway (comme AWS/Azure/AlibabaCloud), en court-circuitant CAPI.

- **Phase Instances (MVP)** : remplace la chaîne expérimentale
  karpenter-capi → CAPS par un provider direct.
  - CRD `ScalewayNodeClass` : zone, image Talos (nom `{ns}-talos-…`),
    Private Network, security group, volume racine, tags.
  - Catalogue d'instance types + prix depuis l'API produits Scaleway →
    offres Karpenter (zone × type). Pas de spot chez Scaleway :
    on-demand uniquement, donc **pas de contrôleur d'interruption à
    écrire** — le provider est structurellement plus simple qu'AWS.
  - Bootstrap : machineconfig worker Talos injecté en user_data (la
    plateforme Talos `scaleway` lit les métadonnées d'instance) ;
    provider ID `scaleway://<instance-id>` pour l'appariement NodeClaim.
- **Phase 2 EM (warm pool piloté)** : le vrai déblocage du « >1 h →
  metal ». Des serveurs EM **pré-imagés Talos et éteints**
  (`modules/em-talos-bootstrap`) forment le pool ; « provisionner » =
  power-on + apply-config = **minutes**, compatible avec le
  registrationTTL de Karpenter — là où l'install EM à la demande (~1 h)
  ne le sera jamais. L'économie ne change pas (le métal alloué se paie
  éteint ou allumé) mais la *décision* devient pilotée par Karpenter :
  consolidation vers le métal quand la charge est soutenue, retour au
  pool sinon. C'est le modèle ADR-024, rendu implémentable.
- Coût : projet Go substantiel — MVP estimé 4-8 semaines à temps plein
  (référence : providers communautaires équivalents), plus la maintenance
  de suivi des releases karpenter-core. À assumer comme un vrai projet
  OSS, idéalement publié (visibilité + contributions).

### C — Stabiliser karpenter-provider-cluster-api upstream
Aider le projet sig à sortir du POC (scale-from-zero sans annotations,
suivi karpenter-core).

- Levier : profite à tout l'écosystème CAPI, garde notre chaîne actuelle.
- Mais reste bloqué par CAPS pour l'EM, et le rythme d'un projet sig
  expérimental ne dépend pas de nous. Opportuniste, pas structurant.

## Décision proposée

1. **Lancer A-issue immédiatement** (coût nul) : poster le brouillon en
   annexe sur `scaleway/cluster-api-provider-scaleway` et jauger la
   réponse mainteneurs sur 4-6 semaines.
2. **Spiker B (M0, ~1 semaine)** : un contrôleur minimal NodeClaim →
   `POST /instance/v1/servers` type fixe, join Talos par user_data, pour
   valider le chemin bootstrap de bout en bout avant tout engagement.
2bis. **Pont immédiat pour le métal (hors Karpenter, quelques jours)** :
   un mini pool-controller sur le pool pré-imagé — pods Pending portant
   la toleration `st4ck.io/pool=metal` → power-on API du prochain serveur
   du pool ; pool idle → drain + power-off. Il livre le comportement
   « workload long → métal » tout de suite et se jette le jour où B-M3
   (backend EM du provider natif) le remplace.
3. Décider après M0 + réponse upstream : si CAPS accueille l'EM, A devient
   prioritaire ; sinon B continue — M1 catalogue types+prix, M2
   consolidation/drift, M3 warm pool EM.
4. C reste opportuniste (issues/PRs ponctuelles si on y gagne).
5. Garder un œil sur **vCluster Auto Nodes** (cf. roadmap Phase G) — si le
   pattern se productise ailleurs, réévaluer avant d'investir M1+.

## Conséquences

- Le pattern « workload long → metal » a un chemin implémentable de bout
  en bout : pool pré-imagé (ADR-035, dès maintenant, statique) → pool
  piloté Karpenter (phase 2 de B, dynamique).
- L'investissement est séquencé avec deux points de sortie bon marché
  (réponse upstream, spike M0) avant le gros de l'effort.

## Annexe — brouillon d'issue CAPS (à poster en anglais)

> **Title**: Support Elastic Metal servers in ScalewayMachine
>
> **What**: `ScalewayMachine` currently provisions Instances only
> (`commercialType`). We'd like to discuss adding Elastic Metal support.
>
> **Use case**: we run a Talos-based platform (CAPI + CABPT + Kamaji) on
> Scaleway and want long-running workloads scheduled onto bare metal
> NodePools via karpenter-provider-cluster-api → MachineDeployments. The
> missing link is an infrastructure provider able to drive EM.
>
> **What EM support would need** (from our investigation):
> - offer selection (`EM-*` ranges) instead of `commercialType`;
> - a provisioning flow compatible with EM install latency: either the
>   official OS-install API, or adopting pre-imaged servers (we install
>   Talos via rescue mode + Image Factory raw image today);
> - Private Network attachment (per-AZ constraint);
> - Machine timeouts tuned for tens-of-minutes provisioning.
>
> **Questions**: is EM on the roadmap? Would you accept a contribution
> adding an EM backend (e.g. `spec.elasticMetal.offerType`), and if so,
> any design constraints we should follow? We're prepared to contribute
> implementation and testing.
