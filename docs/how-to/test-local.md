# Tester la plateforme en local — plan complet

Tout ce qui se teste SANS Scaleway ni materiel, ordonne par cout et par
ce que chaque niveau prouve. Etat des lieux au 2026-07-14 (post ADR-034
hauler, ADR-038 kubescape, ADR-039 zot, mode local-docker arm64).

## Vue d'ensemble

| Niveau | Quoi | Duree | Prerequis | Etat |
|---|---|---|---|---|
| 0 | Statique (validate/render/tests unitaires) | ~3 min | rien | ✅ tout existe — a bundler en 1 cible |
| 1 | Rendu + schemas (kubeconform, HR×values) | ~10 min | brew kubeconform | ⬜ a outiller |
| 2 | Bootstrap podman E2E (platform pod) | ~15-20 min | podman rootful | ✅ cible existante, a rejouer |
| 3 | Cluster Talos local + stacks + Flux | ~10-30 min | local-docker-up, **VM podman 24 Gi / 12 vCPU** | ✅ 3.1 valide le 2026-07-15 (voir verdict) ; 3.2-3.4 ⬜ |
| 4 | Mirror hauler → containerd Talos | ~30 min | niveaux 2+3 | ⬜ **ferme le point ouvert ADR-034** |
| 5 | Harnais kwok du provider karpenter | ~2-4 h build | brew kwok | ⬜ derniere marche avant EM reel |

## Niveau 0 — Statique (a chaque commit, CI-able)

Tout est deja en place, disperse. A bundler dans une cible `make
verify-local` unique :

- `tofu validate` sur les 15 stacks + `tofu fmt -check -recursive`
- `tofu test` : suites .tftest.hcl (envs/scaleway/{iam,image,ci,.} +
  modules/em-talos-bootstrap — goldens provider_id inclus)
- `kubectl kustomize` sur les 12 arbres de manifests
- **Substitution 0-placeholder** : rendu + `flux envsubst` avec les
  variables du registre → aucun `${...}` residuel (technique validee —
  a attrape le bug substituteFrom non herite)
- `go build && go test -race ./...` du provider karpenter (62 tests)
- `shellcheck` scripts/, `gitleaks` (hook), `make -n` des cibles clefs
- Determinisme du generateur hauler (`hauler-manifest` → diff vide)

Ce que ca prouve : coherence interne totale. Ce que ca ne prouve pas :
que les charts acceptent nos values, que les CRDs existent.

## Niveau 1 — Rendu + schemas (avant chaque bump de versions)

- **`helm template` de CHAQUE HelmRelease avec ses values** a la version
  du registre — attrape les values incompatibles AU BUMP au lieu du
  deploy (ex. vm-k8s-stack 0.72→0.86 = 14 minors de bundle). Scriptable :
  lire les HR Flux, resoudre `${x_version}` via le registre, templater.
- **kubeconform** sur tout le rendu substitue (schemas K8s 1.35 + CRDs
  Flux/VM/Kyverno depuis le datree catalog) — attrape les apiVersion et
  champs invalides que kustomize laisse passer.
- `woodpecker-cli lint .woodpecker.yml`.

## Niveau 2 — Bootstrap podman E2E (stage 0 entier)

```bash
make bootstrap          # platform pod : OpenBao KMS + vault-backend + Gitea + Woodpecker
curl -s localhost:8080/state/test   # state backend up
make state-snapshot     # cycle DR snapshot/restore
make bootstrap-stop
```

Jamais rejoue depuis le registre de versions et les fixes du jour.
Prouve : init KMS, PKI root, seeds, state locking. Attention : la
machine podman est passee rootful (requis par local-docker) — bootstrap
fonctionne aussi en rootful.

## Niveau 3 — Cluster Talos local + stacks + Flux day-2

Acquis (valide 2026-07-13) : `make local-docker-up` → Talos v1.12.9
arm64 en containers + Cilium kube-proxy-free avec NOS values, coredns
vert, `cilium status` OK.

**Dimensionnement (lecon des 2 crashs du 2026-07-15)** : la limite
memoire par defaut de talosctl est 2 Gio/noeud — la stack complete
cgroup-thrash dedans (sockets unix en i/o timeout, API server mort,
et la VM podman peut mourir avec). Le script cree desormais 1 CP a
6 Go + 4 workers a 4 Go (`WORKERS`/`MEM_CP`/`MEM_WORKER`
surchargeables). Mesures : le CP thrash a 2.9/3 (etcd + watches de
5 noeuds + tous les DaemonSets) ; un worker thrash aussi a 3 Go des
que vmsingle + trivy-server y bindent leurs PVC (NotReady constate).
Budget limites 6+4x4 = 22 Go sur une machine podman 24 Gi / 12 vCPU
(limites != usage ; usage mesure ~14 Go). Depannage a chaud sans
rebuild : `podman update --memory 4g --memory-swap 4g <node>`.
**Disque : 100 Go** — la stack complete x5 noeuds consomme ~54 Go
(images imbriquees + PVC) ; a 64 Go les kubelets declenchent
DiskPressure et evincent en boucle (cert-manager en a fait les frais
le 2026-07-16). Redimensionner : `podman machine set --disk-size 100`
PUIS, dans la VM, `sudo growpart /dev/vda 4 && sudo xfs_growfs /`
(CoreOS n'auto-grandit pas la partition apres coup) ; enfin redemarrer
les workers marques DiskPressure (condition cadvisor figee sinon).
Contrainte CLI : le provisioner docker de talosctl >= 1.13 est
mono-controlplane (`--controlplanes` n'existe que pour qemu,
Linux-only) — le quorum etcd 3 CP reste hors de portee des containers
(→ VMs : envs/local, ou spike virtu vz/Apple Silicon).

Extensions a caler, dans l'ordre de valeur :

1. **Flux day-2 E2E** : `flux install` sur le cluster local + le root
   Kustomization pointe sur le Gitea du bootstrap (niveau 2) →
   reconciliation reelle de clusters/management. Prouve : two-phase,
   remediation, substituteFrom, PDB, tout le graphe Flux — sur de vrais
   CRDs. C'est ~80 % du risque day-2 restant.

   **VALIDE le 2026-07-15** (cluster 1 CP + 4 workers x 3 Go, VM podman
   24 Gi / 12 vCPU, runbook scripte dans le scratchpad de session) :
   - Les 16 HelmReleases sortent de la reconciliation avec les
     **versions concretes du registre** (`substituteFrom
     platform-versions` prouve de bout en bout : cilium 1.17.13,
     vm-k8s-stack 0.86.0, openbao 0.28.4, velero 11.4.0, ...).
   - **Chaines two-phase** : security-kyverno Ready → kyverno-policies
     lance (transition phase 1 → 2 observee) ; storage-zot correctement
     RETENU par storage-zot-eso (l'ExternalSecret ne peut etre Ready
     sans OpenBao seede — c'est le comportement concu).
   - **Boucle day-2 complete** : le bug velero `dependsOn garage`
     fantome (garage est tofu-owned, le CR HelmRelease n'existe
     jamais) a ete trouve par ce test, corrige, commit, pousse sur le
     Gitea local → Flux a ramasse et velero est passe en install
     reelle. GitOps end-to-end sur infrastructure locale.
   - 10+ HRs Ready (cert-manager, cilium, kyverno, tetragon, openbao
     x2, headlamp, victoria-logs x2, ...). Echecs residuels tous
     rattaches aux 2 manques day-1 assumes de ce niveau : pas de
     StorageClass (stack cni = tofu) → PVC Pending, et pas d'OpenBao
     seede (stack pki = tofu) → identity/grafana en attente de
     secrets ESO. C'est le perimetre du point 4 ci-dessous.
   - Egalement valide en passant : le « dry-run onion » ADR-033 (CRDs
     cert-manager statiques PUIS rendu ESO complet PUIS webhook), la
     survie du cluster aux reboots durs de la VM (etcd sur volumes),
     et l'auto-unseal du KMS bootstrap apres restart (volumes podman).
2. **zot smoke** : HR zot avec un override filesystem (pas de Garage en
   local) → `skopeo copy` push/pull + login htpasswd + pull anonyme.
3. **kubescape smoke** : deposer un fichier EICAR dans un pod → verifier
   l'evenement malware du node-agent.
4. **Golden path tofu-first** (l'ordre REEL du pipeline — leçon
   œuf-poule du run 3.1 : en Flux-first, cert-manager/openbao
   appartiennent a Flux avant que leurs preconditions tofu n'existent,
   et il faut poser a la main 7 secrets + 2 Certificates + 7 seeds KV ;
   en tofu-first tout cela est pose par les stacks, comme en prod).
   Runbook (contexte `dev-docker-local`, etat dans le vault-backend du
   bootstrap — VB_PORT=18080 etc. si ports decales) :

   ```bash
   KUBECONFIG_OUT=~/.kube/st4ck-dev-docker-local SKIP_CILIUM=1 \
     bash scripts/local-docker-up.sh st4ck-tofu   # nodes NotReady : normal
   make k8s-cni-apply  ENV=dev INSTANCE=docker REGION=local VB_PORT=18080
   make k8s-pki-apply  ENV=dev INSTANCE=docker REGION=local VB_PORT=18080
   # ... puis vagues monitoring/identity/security/storage au besoin,
   make flux-bootstrap-apply ENV=dev INSTANCE=docker REGION=local VB_PORT=18080
   ```

   Valide en plus du 3.1 : l'ordre day-1, le handoff tofu→Flux
   (adoption des releases Helm), et les seeds reels (secrets.tf).
   Acquis du 2026-07-16 en attendant : la variante manuelle-fidele sur
   le cluster Flux-first a prouve TOUTE la chaine post-day-1 —
   issuer bootstrap Ready → Certificates emis → OpenBao Infra
   auto-init + scale HA x3 (values declaratives) → Job Flux
   bootstrap-openbao-pki Completed (pki_int, roles, auth k8s) →
   ClusterSecretStore "store validated" (auth kubernetes, role eso).

Limites structurelles du mode container : pas de vraie surface OS Talos
(upgrade kernel, machine config bas niveau), 1 seul CP (pas de quorum
etcd 3 noeuds — limite CLI talosctl, voir Dimensionnement), pas de
PN/LB. Piste pour les lever sur Mac : spike virtu Apple Silicon —
Talos v1.12 arm64 gele sur QEMU/HVF (siderolabs/talos#13108) mais la
voie Virtualization.framework (UTM backend Apple, puis Lima vz + image
nocloud, reseau vmnet) est credible et donnerait quorum 3 CP, upgrades
OS et extensions systeme (prerequis Longhorn) en local.

## Niveau 4 — Mirror hauler → containerd (ferme ADR-034)

Le point ouvert n°1 de l'ADR-034 (naming `?ns=`, collision prouvee en
PoC) devient testable SANS cluster dev Scaleway :

```bash
make hauler-sync                      # store complet (~qq Go, une fois)
make hauler-serve                     # registre OCI :5000 sur le Mac
# cluster local recree avec un patch registries.mirrors pointant sur
# host.containers.internal:5000, puis :
crictl pull docker.io/library/busybox:stable   # via le mirror ?
```

Verdict attendu : mirror transparent OK / KO → si KO, valider le repli
`rewrite:` + endpoints par upstream avec `overridePath` (documente dans
l'ADR). Ce test decide l'architecture air-gap finale.

## Niveau 5 — Harnais kwok du provider karpenter

karpenter-core + notre provider + FakeBackend contre un cluster kwok
(noeuds simules — l'outil de test de karpenter lui-meme) : cycle
NodeClaim COMPLET — Create → noeud joint (simule avec le providerID
attendu) → matching → Registered → Delete. Derniere marche avant de
louer le premier EM ; complement logiciel du runbook materiel du
M0-REPORT (denylist kubelet + p95 power-on restent hardware-only).

## Ce qui ne se teste PAS en local (assume)

- Surface OS Talos reelle : upgrades, machine config kernel → hote KVM
  (`envs/local`) ou Scaleway.
- Tout le plan Scaleway : IAM, image import, PN par AZ, LB, CI VM.
- Elastic Metal : denylist `provider-id`, p95 power-on→Ready, e2e
  NodePool 0→1→0 (runbook M0-REPORT §3, EM loue a l'heure ~1-2 €).
- Perf realiste (pki ~10 min, vagues k8s-up) : les chiffres locaux ne
  transferent pas.
- Woodpecker CI de bout en bout (agent sur la VM CI).

## Ordre recommande

1. Cible `make verify-local` (niveau 0 bundle) — 1 h d'outillage, gain
   permanent (+ step CI).
2. Niveau 2 rejoue (bootstrap) puis niveau 3.1 (Flux day-2 E2E) — le
   plus gros retour sur effort.
3. Niveau 4 (mirror) — decide l'architecture air-gap.
4. Niveau 1 (outillage bump) et niveau 5 (kwok) en tache de fond.
