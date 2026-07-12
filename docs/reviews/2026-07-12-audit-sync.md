# st4ck — audit Sync (cohérence doc-code)

**Date :** 2026-07-12
**Audit :** `/cli-audit-sync` — références périmées après la journée du 2026-07-12 :
registre de versions unique (`clusters/management/versions-configmap.yaml`),
suppression des pins `vars.mk` et de `clusters/management-eso/`, bump 24 charts
+ Talos v1.12.9 / K8s 1.35.6, ajout hauler (ADR-034), split monitoring two-phase.
**Périmètre :** tout le repo — 66 fichiers doc inventoriés (docs/, README,
CLAUDE.md, AGENTS.md, llms.txt, READMEs de stacks) + commentaires de code
(Makefile, *.tf, scripts, .woodpecker.yml, manifests Flux). Exclusions :
`docs/reviews/` et ADR 001-033 (archives datées — pas de rétro-édition),
`.terraform/` vendored.
**Score de cohérence : 5/10** — plusieurs commandes et liens cassés, 6 copies
manuelles du registre de versions toutes dérivées ; mais le cœur opérationnel
(how-to, tutorials, commands.md, ADR du jour) est à jour.

---

## Synthèse

| Couche | Vérifications | OK | Échecs | Warnings |
|--------|--------------|----|--------|----------|
| L1 — Structurel (liens, chemins) | ~180 liens/chemins | ~168 | 6 | 7 |
| L2 — Sémantique (versions, noms, ownership) | ~140 claims | ~65 | 12 | ~60 |
| L3 — Exécutable (commandes, cibles make) | ~90 commandes | 84 | 5 | 1 |
| Duplication (D/C/S/M) | 5 familles | — | 3 | 3 |

Le motif dominant : **le registre de versions a été créé aujourd'hui, mais ses
anciennes copies manuelles n'ont pas été purgées ni raccordées**. Six documents
restituent l'inventaire de versions à la main (techno.md, roadmap.md,
design/001 §20, hld appendix, badges README, AGENTS.md) — les six divergent du
registre. C'est exactement la dérive que le registre devait tuer (S-SSOT-02,
règle des trois de Fowler : 6 copies → erreur).

---

## Critiques (à corriger maintenant)

| # | Fichier:ligne | Problème | Ce que dit la doc | Ce que dit le code |
|---|---------------|----------|-------------------|---------------------|
| 1 | `scripts/mirror-images.txt:46-49` → `hauler-manifest.yaml:62-65` | Le staging hauler (introduit **aujourd'hui**, ADR-034) embarque les mauvaises images control-plane | `kube-apiserver/controller-manager/proxy/scheduler:v1.35.0` | cluster déployé en K8s **1.35.6** (`contexts/_defaults.yaml`). `mirror-images.txt` est maintenu à la main, non dérivé de `k8s_version` — `hauler-manifest-gen.py` réémet fidèlement les tags périmés |
| 2 | `CLAUDE.md:202`, `docs/roadmap.md:107`, `docs/roadmap.md:898` | Commande inexistante | `make scaleway-oidc` | cible renommée `oidc-register` (Makefile:309) |
| 3 | `docs/roadmap.md:241` | Commandes inexistantes | `make capi-init && make capi-create && make capi-delete` | cibles réelles : `k8s-capi-init/apply/destroy`, `managed-cluster-apply/destroy` |
| 4 | `docs/reference/config.md:5-13`, `docs/reference/commands.md:17-24` | Table « Version Variables (vars.mk) » morte | `TALOS_VERSION=v1.12.6`, `KUBERNETES_VERSION=1.35.4`, `CILIUM_VERSION`, `IMAGER_IMAGE` éditables dans vars.mk | vars.mk ne contient plus que `OUT_DIR` ; les 4 variables ont été supprimées aujourd'hui (et les valeurs affichées étaient déjà fausses) |
| 5 | `llms.txt:56` | Description inverse de la réalité | « [vars.mk](vars.mk): Version pinning (Talos, Kubernetes, Cilium) » | vars.mk documente lui-même que les pins n'y vivent PAS |
| 6 | `llms.txt:80-84` | 5 liens cassés (section Configuration) | `stacks/cni/values.yaml`, `stacks/monitoring/values-vm-stack.yaml`, `stacks/pki/values-openbao-infra.yaml`, `stacks/identity/values-hydra.yaml`, `stacks/storage/values-harbor.yaml` | déplacés sous `flux*/` : `stacks/cni/flux/values.yaml`, `stacks/monitoring/flux-vm/values-vm-stack.yaml`, `stacks/pki/flux/values-openbao-infra.yaml`, `stacks/identity/flux/values-hydra.yaml`, `stacks/storage/flux-harbor/values-harbor.yaml` |
| 7 | `Makefile:1133` + `CLAUDE.md:155-156` | Arbor documenté comme LE staging, et cassé | « # Arbor — unchanged » ; « make arbor # Pull images + Helm charts → arbor/manifest.json » | la recette résout les versions de charts en grepant `default = "..."` dans `stacks/*/variables.tf` — tous les defaults sont `null` depuis le registre → chaque `helm pull` échoue/saute. Successeur : `make hauler-*` (ADR-034), absent de CLAUDE.md |

---

## Warnings (à corriger bientôt)

### Copies manuelles du registre de versions (S-SSOT-02 — 6 copies, toutes dérivées)

| Fichier | Pins périmés (doc → registre) |
|---------|-------------------------------|
| `docs/techno.md` | 17 pins : Talos v1.12.6→**v1.12.9** (:12), K8s 1.35.4→**1.35.6** (:13), Harbor 1.16.2→**1.19.1** (:23,:138), local-path 0.0.35→**0.0.37** (:46), vm-k8s-stack 0.72.4→**0.86.0** (:52), vlogs 0.11.28→**0.13.8** (:53), vlogs-collector 0.2.11→**0.3.6** (:54), Headlamp 0.40.0→**0.43.0** (:55), OpenBao 0.25.6→**0.28.4** (:62-63), cert-manager v1.19.4→**v1.21.0** (:64), Kratos/Hydra 0.60.1→**0.62.1** (:115-116), Trivy 0.32.0→**0.34.0** (:123), Tetragon 1.6.0→**1.7.0** (:124), Kyverno 3.7.1→**3.8.2** (:125), Garage v2.2.0→**v2.3.0** (:136), Flux 2.14.1→**2.18.4** (:156) |
| `docs/roadmap.md` | 13 pins équivalents (:24,:35-37,:69,:104,:141-143,:174-176,:206,:208) — les cases « [x] fait » affirment des versions déployées qui ne le sont plus |
| `docs/design/001-hld-lld.md` §20 | 19 pins (:214,:1060,:1310-1331) dont Garage chart 0.9.2→**v2.3.0** |
| `docs/hld-talos-platform.md` | 6 pins (:153-156,:432,:640-645) |
| `README.md:5-6` | badges `Talos-v1.12.6` / `Kubernetes-1.35.4` → **v1.12.9 / 1.35.6** |
| `AGENTS.md:7-8` | « Talos v1.12.6 », « Kubernetes v1.35.4 » → **v1.12.9 / 1.35.6** |

Aussi : `docs/reference/commands.md:155` (« garage-chart … v2.2.0 » → v2.3.0),
`docs/NAMING.md:38` et `docs/MULTI-ENV.md:20-22,138-139` (exemples d'images
`st4ck-talos-v1.12.6-*` → v1.12.9).

### Defaults Terraform à moitié bumpés (C-DRY-04 — dérive entre copies)

| Fichier:ligne | Doc/code | Réalité |
|---------------|----------|---------|
| `modules/talos-cluster/variables.tf:20` | `kubernetes_version` default `"1.35.0"` | 1.35.6 — le commit ab08dc0 a bumpé `talos_version` (:14) mais oublié celui-ci |
| `envs/local/variables.tf:10,16` | defaults `v1.12.4` / `1.35.0` | v1.12.9 / 1.35.6 |
| `envs/vmware-airgap/vars.env:5-7` | `TALOS_VERSION="v1.12.4"`, `KUBERNETES_VERSION="1.35.0"`, imager v1.12.4 | copie manuelle des variables supprimées de vars.mk, consommée par `envs/vmware-airgap/scripts/*.sh` (legacy, mais en dérive : v1.12.9/1.35.6) |

### Kubeconfig — deux vérités dans le même fichier (S-SSOT-04)

- `CLAUDE.md:88` dit `~/.kube/$(CTX_ID)` (correct, Makefile:28) mais
  `CLAUDE.md:180` dit `~/.kube/talos-$(ENV)` (périmé) — contradiction interne.
- Même valeur périmée : `docs/reference/config.md:21`,
  `docs/hld-talos-platform.md:280,420-421`, `docs/design/001-hld-lld.md:933`,
  `docs/how-to/troubleshoot.md:96-97` (`~/.kube/talos-scaleway`).

### Ownership ESO (ADR-033 non répercuté partout)

| Fichier:ligne | Ce que dit la doc | Réalité |
|---------------|-------------------|---------|
| `CLAUDE.md:45,219` | stack external-secrets = « ESO + ClusterSecretStore (Tofu day-1 + Flux day-2) » | le `helm_release` ESO + namespace sont dans `stacks/pki/main.tf:564-592` ; `stacks/external-secrets/` ne contient plus que `flux-config/cluster-secret-store.yaml` |
| `llms.txt:69` | « ESO + ClusterSecretStore (Flux only) » | idem — ESO est tofu-owned (pki) |
| `docs/techno.md:180` | « Tofu day-1 + Flux day-2 » | idem |
| `.woodpecker.yml:14-18` | commentaire : external-secrets parmi les « six KaaS stacks » validés avec main.tf | le stack n'a pas de main.tf ; la boucle de validation (l.24-40) n'en liste que 5 |
| `CLAUDE.md:289` | « storage is self-contained (generates its own harbor_admin_password) » | généré dans `stacks/pki/secrets.tf:85` ; storage ne fait que le relire depuis OpenBao (`stacks/storage/outputs.tf:1-3`) |
| `docs/design/001-hld-lld.md:1219` | nœud Mermaid `stacks/external-secrets/flux/ HelmRepository + HelmRelease + ClusterSecretStore` | dossier supprimé aujourd'hui |

### Arbor → hauler (ADR-034 non répercuté)

- `docs/how-to/upgrade.md:55-77` — arbor présenté comme LE mécanisme de
  pré-staging (`make arbor`, `arbor/manifest.json`), aucune mention de hauler.
- `AGENTS.md:104` — idem.
- `Makefile:1140` — help text d'arbor sans note de dépréciation.
- `llms.txt:52` — décrit upgrade.md par « arbor staging ».

### Monitoring two-phase (split d'aujourd'hui, en-têtes non mis à jour)

- `stacks/monitoring/main.tf:70-78` — l'en-tête liste « VMRule for Flux
  alerts » parmi ce que « Tofu only manages » et pointe la HR vm-k8s-stack vers
  `flux/` ; le même fichier (l.209-214) et `clusters/management/monitoring-vm.yaml`
  disent l'inverse (VMRule → `flux-alerts/`, HR → `flux-vm/`).
- `stacks/security/flux-openclarity/helmrelease-openclarity.yaml:4` — « Tag is
  pinned to match var.openclarity_version in tofu » ; les lignes 14-16 du même
  fichier décrivent (correctement) la résolution `${openclarity_version}` via
  `substituteFrom`.
- `docs/explanation/architecture.md:223-232` — l'arbre GitOps montre
  `clusters/management/` avec des sous-dossiers `k8s-cni/ … k8s-storage/` qui
  n'existent pas (réalité : kustomization.yaml + 4 fichiers two-phase +
  versions-configmap.yaml).

### Divers

- « 30 ADRs » : `CLAUDE.md:58`, `AGENTS.md:95`, `README.md:120` → **33** fichiers dans `docs/adr/`.
- `.woodpecker.yml:102` — le path-trigger du job image-build inclut `vars.mk`
  (désormais inerte pour les versions) mais PAS `contexts/_defaults.yaml`, où
  vit maintenant le pin Talos qui devrait déclencher le rebuild d'image.
- `docs/reference/config.md:82,86,98,108,119,136` — chemins de values périmés
  (mêmes déplacements que llms.txt, cf. critique #6).

---

## Infos (mineur)

- Exemples/descriptions TF avec v1.12.4 : `envs/scaleway/image/main.tf:21`,
  `envs/scaleway/image/variables.tf:20`, `envs/scaleway/variables.tf:12`.
- Defaults tenant (choix possible, mais en retard sur la plateforme) :
  `stacks/managed-cluster/main.tf:108-109` (1.35.4 / v1.12.6),
  `stacks/managed-cluster/chart/values.yaml:16-17`,
  `stacks/kamaji/templates/tenant-control-plane.tpl.yaml:84`.
- Fixtures de test : `envs/scaleway/tests/setup/main.tf:65,70` (v1.12.4/1.35.0).
- `stacks/storage/chart/README.md:3` — badge helm-docs `0.9.2 / v2.2.0` :
  `Chart.yaml` du chart vendored non re-versionné lors du bump Garage v2.3.0.
- `AGENTS.md:47` — exemple `stacks/cni/values.yaml` (fichier réel :
  `values-local-path.yaml` / `flux/values.yaml`).
- `llms.txt` — pas d'entrée pour `clusters/management/versions-configmap.yaml`
  ni pour hauler (`hauler-manifest.yaml`, `scripts/hauler-manifest-gen.py`) ;
  l'index ADR saute 023-028 et 032 ; `Makefile:1178` écrit encore
  `arbor/manifest.json` comme manifeste d'artefacts.
- `contexts/README.md:11-19` — table des clés incomplète (manque
  `talos_version`, `k8s_version`, `cluster_shape`, `management_cidrs`).
- `.claude/shared-state.md:63,197` — « vars.mk — version pins » : journal de
  sprint daté (2026-04-23), périmé seulement si lu comme état courant.
- `docs/roadmap.md:506`, `docs/adr/034:17` — mentions arbor/vars.mk dans des
  sections narratives datées : acceptable.

---

## Ce qui est à jour (vérifié conforme)

- **Registre et consommateurs** : en-têtes de `vars.mk`,
  `clusters/management/versions-configmap.yaml`, `contexts/_defaults.yaml`
  (v1.12.9/1.35.6, note cilium_version), `stacks/cni/main.tf` (coalesce),
  `stacks/flux-bootstrap/main.tf` (substituteFrom + historique purge
  management-eso), `stacks/pki/main.tf:564-592` (ESO tofu-owned),
  `stacks/external-secrets/flux-config/`, docstring de
  `scripts/hauler-manifest-gen.py`, section Files de `hauler-manifest.yaml`
  (talos/talosctl v1.12.9), defaults `null` dans tous les
  `stacks/*/variables.tf` (aucun contournement du registre).
- **Two-phase monitoring** : `monitoring-vm.yaml`, `flux-vm/`, `flux-alerts/`,
  `clusters/management/kustomization.yaml` — câblage et commentaires corrects
  (seul l'en-tête de main.tf traîne, cf. warnings).
- **Docs** : `docs/reference/commands.md:44-50` (arbor « superseded by Hauler »
  + les 5 cibles hauler), ADR-034/035/036, `docs/design/002`,
  `docs/how-to/deploy.md`, `disaster-recovery.md`, `rotate-keys.md`,
  `docs/tutorials/getting-started.md` (kubeconfig `$(CTX_ID)` correct),
  `docs/reference/openbao-paths.md`, `ci-cd.md`, `docs/explanation/security.md`
  (ownership ADR-033 correct), `bootstrap.md`, `docs/index.md`,
  `CONTRIBUTING.md`, `contexts/README.md`, `stacks/registry-mirror/README.md`,
  `bootstrap/vault-kms-plugin/README.md`, `docs/lld/README.md`.
- Toutes les cibles `make` citées dans ces docs existent (y compris
  `scaleway-bootstrap-vm`, wrapper one-shot de `scaleway-ci-apply`).

---

## Carte terminologique (tier L)

| Concept | Termes rencontrés | Canonique |
|---------|-------------------|-----------|
| Staging d'artefacts | « arbor », « staging tree », « hauler », « artifact store » | **hauler** (ADR-034) ; arbor = déprécié, à marquer partout |
| Pin de versions | « vars.mk », « variables.tf defaults », « registry », « versions-configmap » | **`clusters/management/versions-configmap.yaml`** (+ `contexts/_defaults.yaml` pour talos/k8s machine) |
| Kubeconfig | `~/.kube/talos-$(ENV)`, `~/.kube/talos-scaleway`, `~/.kube/$(CTX_ID)` | **`~/.kube/$(CTX_ID)`** |
| Stack external-secrets | « ESO stack », « Tofu day-1 + Flux day-2 », « Flux only » | dossier = **ClusterSecretStore seul** ; chart ESO = **stacks/pki** (ADR-033) |
| VM de bootstrap | « CI VM » (`scaleway-ci-apply`), « bootstrap VM » (`scaleway-bootstrap-vm`) | deux cibles réelles distinctes (la 2e enveloppe la 1re en one-shot) — pas une dérive, à ne pas « unifier » |

---

## Recommandations (handoffs — non exécutés)

| Constat | Skill | Pourquoi |
|---------|-------|----------|
| 6 copies manuelles de l'inventaire de versions | `/cli-forge-doc` | remplacer les tables de techno.md/roadmap/hld/design par un lien vers le registre (ou une table générée — même approche que `hauler-manifest-gen.py`) |
| `mirror-images.txt` kube-* non dérivé de `k8s_version` | — (fix direct) | dériver les 4 tags kube-* de `contexts/_defaults.yaml` dans `hauler-manifest-gen.py`, comme c'est déjà fait pour Talos |
| Arbre GitOps faux dans architecture.md + nœud Mermaid ESO supprimé | `/cli-forge-schema` | régénérer les 2 diagrammes depuis l'état courant |
| Bloc arbor du Makefile cassé et déprécié | `/cli-audit-code` | candidat code mort — ADR-034 le garde en transition, mais il ne fonctionne plus ; trancher suppression vs réparation |
| upgrade.md section staging | `/cli-forge-readme` / `/cli-forge-doc` | réécrire le flux d'upgrade autour de `hauler-sync/save/serve` |

**Note M-AHA (anti-faux-DRY) :** les ADR 001-033 et `docs/reviews/` sont des
archives datées — les versions qu'ils citent sont historiques, ne pas les
rétro-éditer.
