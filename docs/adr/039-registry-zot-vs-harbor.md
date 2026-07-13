# ADR-039 : Registre interne — pilote zot, Harbor réévalué à sa v2.16

**Date** : 2026-07-13
**Statut** : Proposé
**Décideurs** : Équipe plateforme
**Reliés à** : ADR-034 (Hauler), ADR-003 (Garage S3), ADR-037 (envs par tags)
**Preuves** : `docs/reviews/2026-07-13-harbor-arm-openclarity.md` (Q1)

## Contexte

Harbor n'a **aucune release GA arm64** (v2.15.2 incluse, vérifié sur les
manifests) — c'est le principal bloqueur ARM du parc. MAIS l'upstream a
mergé le multi-arch complet en mai-juin 2026 (PRs #22311, #23282 ;
pipeline de release arm64 sur `main`) : la **v2.16 devrait être la
première GA arm64**, sans date engagée (cadence ~trimestrielle). Les
builds tiers sont tous morts ou risqués (harbor-arm : dernier commit
2022 ; Bitnami : retiré du gratuit ; octohelm : 1 mainteneur).

**zot** (CNCF, v2.1.18, cadence mensuelle) coche toutes les cases de
notre usage : arm64 natif, binaire Go unique, **backend S3 → Garage
directement**, Trivy embarqué, vérification cosign/notation, webhooks
CloudEvents, **pull-through cache + miroir périodique** (`extensions.sync`
— recoupe la story mirror d'ADR-034), OIDC, chart Helm actif.

Fonctionnalités Harbor réellement perdues : projets/quotas, robot
accounts, réplication push vers registries externes, immutabilité de
tags, blocage de pull sur CVE. Dans notre stack, l'enforcement est déjà
à l'admission (Kyverno + cosign) et le scan in-cluster (trivy-operator) :
la perte est largement théorique aujourd'hui — elle redeviendrait réelle
en KaaS multi-tenant (quotas/projets par tenant).

### Vérification complémentaire (2026-07-14) — autres registries et tags dev

- **ghcr.io/goharbor** existe et miroite les releases… **amd64 uniquement**
  (v2.15.2 vérifié) ; pas de tag `dev`. Aucun autre canal officiel arm64.
- **Aucun tag v2.16 (même RC)** sur Docker Hub à ce jour (414 tags scannés).
- Les seuls artefacts arm64 du projet : les tags **`dev` / `dev-arm64`**
  (nightly de `main`, rebuild quotidien — vérifié frais de la veille).
  Utilisable pour un env dev jetable À CONDITION de : pinner par digest
  (tag mutable), aligner les 8-9 composants sur le même nightly, et
  accepter deux risques — qualité nightly sans correctifs garantis, et
  **schéma DB potentiellement en avance sur la future v2.16** (un env
  monté sur `dev` peut ne pas migrer proprement vers la GA). zot reste
  la recommandation pour le profil local ; l'option dev-tags est
  documentée ici comme dépannage volontairement borné aux envs jetables.

## Décision proposée

1. **Piloter zot** comme registre du profil local/ARM immédiatement
   (S3 → Garage, sync pull-through comme miroir hauler-compatible).
2. **Garder Harbor sur les environnements Scaleway amd64** en attendant
   sa v2.16 — aucun geste.
3. **Point de décision à la sortie de Harbor v2.16** (premier GA arm64
   attendu) : si le pilote zot couvre l'usage réel → bascule complète et
   ADR d'exécution ; si les besoins KaaS (projets/quotas/réplication
   push par tenant) se sont matérialisés → Harbor v2.16 partout, zot
   reste le registre du profil local.

## Conséquences

- Le profil local/ARM cesse d'exclure « le registre » : il en a un.
- Deux registres cohabitent temporairement (Harbor amd64 / zot local) —
  assumé, borné par le point de décision v2.16.
- Le pin `zot_version` entre au registre de versions comme les autres.
