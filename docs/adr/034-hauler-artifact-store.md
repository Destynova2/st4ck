# ADR-034 : Hauler comme magasin d'artefacts (remplacement d'arbor)

**Date** : 2026-07-11
**Statut** : Proposé
**Décideurs** : Équipe plateforme
**Reliés à** : ADR-028 (Flux owner-by-default), ADR-033 (frontière OpenTofu/Flux), roadmap Phase E (« ADR-029bis à créer » — cet ADR le matérialise)

## Contexte

Le staging d'artefacts repose aujourd'hui sur `make arbor` / `make arbor-verify`,
entièrement inline dans le Makefile. L'audit du mécanisme actuel révèle :

- **Sources de vérité éclatées** : les images sont extraites par grep de
  `bootstrap/platform-pod.yaml`, les charts par grep des `main.tf` de chaque
  stack (avec déréférencement manuel des `var.X` dans `variables.tf`).
  `vars.mk` n'est la source de rien, et dérive déjà de
  `contexts/_defaults.yaml` (Talos v1.12.6 vs v1.12.4).
- **Les charts OCI sont silencieusement ignorés** : le filtre
  `grep -q '/' && continue` saute tout chart dont le nom contient un `/` —
  Karpenter (`oci://public.ecr.aws/karpenter`) et cluster-api-operator ne sont
  jamais stagés. En air-gap, le stack autoscaling ne se déploierait pas.
- **Vérification partielle** : `arbor-verify` recontrôle le SHA256 des charts
  mais pas les digests des images (seulement leur présence podman).
- **Pas de portabilité** : les images vivent dans le store podman local ; il
  n'existe pas d'export un-fichier pour franchir une frontière air-gap.
- **Aucune vérification de signature** amont (cosign) au moment du pull.

Côté mirror, les patches `registry-mirror-scr.yaml` redirigent 6 registries
publics vers un namespace SCR public (`rg.fr-par.scw.cloud/st4ck-mirror`,
host codé en dur par région). La roadmap Phase E prévoit un mirror sur la VM
CI avec sync périodique — sans ADR ni outillage à ce jour.

Zarf et Hauler ont été évalués comme candidats à la simplification du
bootstrap et des mises à jour.

## Options considérées

### Option A — Statu quo (arbor Makefile)
Fonctionne pour le chemin nominal, mais les 5 lacunes ci-dessus sont
structurelles : chaque nouvelle famille d'artefacts (charts OCI, binaires,
images factory) demande du shell inline supplémentaire.

### Option B — Zarf (rejetée)
Zarf packe images + charts + manifests et **orchestre leur déploiement**
(`zarf init` seede son propre registre, `zarf package deploy` applique).
Trois incompatibilités :

1. **Il ne peut remplacer ni OpenTofu ni Flux.** La partie dure du bootstrap
   est pré-Kubernetes (platform pod podman, OpenBao KMS, vault-backend,
   provisioning Scaleway) — hors périmètre Zarf. Et Zarf déploie en push
   one-shot : pas de réconciliation continue ni de correction de drift —
   le rôle de Flux (ADR-028).
2. **Troisième owner** : sa valeur ajoutée (orchestrer le déploiement) entre
   en conflit direct avec la frontière à deux owners tranchée par l'ADR-033.
3. **Doublons** : registre embarqué vs Harbor, signing vs la policy cosign du
   stack security.

### Option C — Hauler v2 (retenue)
Hauler (hauler-dev/hauler, Rancher Government Solutions, Apache-2.0,
v2.0.1 du 2026-06-23) ne fait **que la logistique d'artefacts** : store OCI
content-addressed alimenté par un manifest déclaratif, export tarball,
serveur registry + fileserver. Aucune opinion de déploiement : Tofu Day-1 et
Flux Day-2 restent les deux seuls owners.

| Besoin | arbor aujourd'hui | Hauler |
|---|---|---|
| Liste déclarative images + charts + fichiers | greps Makefile éclatés | `hauler-manifest.yaml` (kinds `Images`/`Charts`/`Files`, apiVersion `content.hauler.cattle.io/v1`) |
| Pinning | tags implicites | tag, digest `@sha256:`, `version:` chart, platform `linux/amd64` par annotation |
| Charts OCI | **ignorés** | supportés (`repoURL: oci://…`), + `add-images: true` |
| Vérification | shasum charts uniquement | store OCI adressé par digest + **cosign embarqué au pull** (keyed/keyless, OCI 1.1 Referrers) |
| Export air-gap | aucun | `hauler store save --chunk-size` → tarball zstd, `load` réassemble |
| Mirror registry | SCR public séparé | `hauler store serve registry` (:5000, API Distribution v2 réelle) |
| Inspection/diff | manifest.json maison | `hauler store info`, `sync --dry-run` |
| Plateformes | — | binaires darwin/arm64 (laptop) et linux/amd64 (VM CI) |

## Décision

1. **Adopter Hauler ≥ v2.0.1 comme couche transport/staging d'artefacts.**
   Il remplace arbor, pas OpenTofu ni Flux — la frontière ADR-033 est
   inchangée.
2. **`hauler-manifest.yaml` versionné dans Git, généré** par une cible
   `make hauler-manifest`. Les versions de charts se résolvent contre le
   **registre de versions unique** `clusters/management/versions-configmap.yaml`
   (consommé aussi par Tofu via `local.platform_versions` et par Flux via
   `postBuild.substituteFrom`) ; les images viennent de `platform-pod.yaml`
   + `scripts/mirror-images.txt`, les fichiers de l'Image Factory
   (talosctl, raw scaleway + metal). Un bump de version = une édition du
   registre ; le diff du manifest dans les PRs devient la revue des bumps.
3. **`make arbor` → `hauler store sync`, `arbor-verify` → `hauler store
   info`** + digest natif du store. Les anciens noms restent en alias le
   temps de la transition. Air-gap : `store save`/`load` chunké, intégré à
   la procédure DR.
4. **Servir le store depuis la VM CI** (`hauler store serve registry`,
   port 5000) comme endpoint candidat du patch registry-mirror (Phase E
   roadmap) — **conditionné à la validation du point ouvert n°1 ci-dessous**.
   Repli : conserver le mirror SCR transparent et n'utiliser Hauler que pour
   staging + air-gap.
5. **Piste ultérieure** : consommer les charts servis en OCI via Flux
   `OCIRepository` → `HelmRelease` (chemin recommandé Flux ≥ 2.3), ce qui
   apporte la valeur « bundle signé déterministe » de Zarf sans owner
   supplémentaire.

## Points ouverts à valider (bloquants avant la phase 2)

1. **RÉSOLU PAR TEST RÉEL (2026-07-14, cluster Talos local + trafic
   containerd observé)** — verdict en deux moitiés :
   - ✅ **docker.io : mirror transparent fonctionnel tel quel.** containerd
     demande `/v2/library/<x>?ns=docker.io`, hauler sert exactement ce
     chemin → 200 sur manifests + blobs (busybox prouvé de bout en bout,
     image installée sur le nœud via le mirror).
   - ❌ **Upstreams non-Docker : échec par construction.** containerd
     demande le chemin NU (`/v2/pause?ns=registry.k8s.io`,
     `/v2/siderolabs/kubelet?ns=ghcr.io`) ; hauler stocke/sert sous
     `library/pause` ou chemin plein → 404 → fallback upstream. En
     connecté c'est un aller-retour perdu ; **en air-gap c'est bloquant**.
   Suite actée : expérimenter `rewrite:` dans le générateur pour stocker
   les images non-docker sous leur chemin nu (le générateur devra
   détecter les collisions de chemin nu inter-upstreams et échouer
   bruyamment — aucune dans le parc actuel), sinon replis : endpoints
   par upstream + `overridePath`, ou config serveur containerd par host.
   Le mirror docker.io peut être activé dès maintenant.
2. **Croissance du store** : pas de GC automatique (delete granulaire depuis
   v1.4.0 seulement). Politique à définir : rebuild périodique du store +
   `--exclude-extras` + platform pinné.
3. **TLS/auth** : serve = HTTP nu par défaut ; flags natifs `--tls-cert`/
   `--tls-key` disponibles (vérifié sur v2.0.1). HTTP acceptable pour un
   mirror Talos sur PN privé ; TLS via les sub-CAs PKI si exposition au-delà.

## Plan de mise en œuvre

- **Phase 0 — PoC (dev)** : binaire installé, manifest minimal (stack cni),
  `store sync` + `serve registry`, patch `registries.mirrors` d'un cluster
  dev pointé dessus. Critère de sortie : pull transparent OK ou décision de
  repli (rewrite / SCR).
- **Phase 1 — Remplacement d'arbor** : générateur `make hauler-manifest`,
  manifest complet (corrige le trou charts OCI), bascule des cibles
  `arbor`/`arbor-verify`, mise à jour docs (upgrade.md, commands.md).
- **Phase 2 — Mirror VM CI (Phase E roadmap)** : `serve registry` en unité
  systemd/quadlet sur la VM CI, sync périodique (cron), variable d'endpoint
  dans le patch registry-mirror (supprime le host `fr-par` codé en dur).
- **Phase 3 — Option Flux OCI** : migration progressive des HelmReleases vers
  `OCIRepository`.

## Conséquences

- Une seule commande et un seul fichier remplacent ~60 lignes de shell inline
  Makefile ; les mises à jour deviennent : bump → régénération du manifest →
  `sync --dry-run` (diff visible) → apply Tofu/Flux.
- Le chemin air-gap (objectif de la roadmap) obtient son chaînon manquant :
  export un-tarball vérifiable, signé, rechargeable côté isolé.
- Dépendance nouvelle à un binaire tiers (RGS) — mitigée par Apache-2.0,
  format 100 % OCI standard (le store reste lisible par n'importe quel outil
  OCI), et maintien des alias arbor pendant la transition.
