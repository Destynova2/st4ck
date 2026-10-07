# Tester la plateforme en local — plan complet

## Etat courant au 2026-09-26

Les comptes rendus de juillet ci-dessous sont historiques. Ils ne valident
pas la migration Flux actuelle (ADR-043) ni le provider hybride actuel
(ADR-044). Une API Kubernetes reelle avec des noeuds simules ne prouve pas
le fonctionnement des conteneurs, du CNI ou du materiel Scaleway.

| Verification | Resultat actuel | Portee exacte |
|---|---|---|
| Statique, tests Go/Python/Tofu | Rejoues le 26 septembre : 102 controles reussis, 0 echec | Inclut 61 tests Python ; plans avec providers simules, pas de deploiement cloud |
| Rendu Helm | Rejoue le 26 septembre : 18 charts rendus, aucune erreur | Les schemas CRD manquants sont ignores explicitement ; secrets ESO non resolus |
| Karpenter sur KWOK natif | PASS le 26 septembre, 24 secondes hors premier telechargement | Vraie API Kubernetes 1.35.6 et vrai core Karpenter 1.14.0 ; API EM et kubelet simules |
| Autorisations Garage sur cette API | PASS le 26 septembre | SSA create/update et donnees relues ; acces non autorises refuses |
| Installation Talos + Flux | Nouveau banc : quatre noeuds Ready, 18 HelmReleases Ready sur 18 | 56 objets controles, verdict strict vert sans exemption ; demarrage avec corrections et reprises, pas une installation sans intervention |
| Kubescape | PASS au demarrage a froid | Trois agents 2/2, operateur et stockage prets ; aucune preuve de detection malware |
| Recreer le bootstrap | PASS avec etat persistant | Trois CA et lignee d'etat conservees ; absence d'etat face a une PKI existante refusee |
| Amorcage et reprise OpenBao HA | PASS sur vrais pods locaux le 26 septembre, apres correction du split-brain | Infra et App : trois membres, identifiant commun, remplacement du pod 0, accord de leader et plan Tofu sans changement ; montee de version non testee |
| VM -> EM -> VM Scaleway | Non valide | Demande aussi une recette cloud/materielle ; pas de redimensionnement en place |

### Banc leger reproductible

Le harnais Karpenter accepte le runtime natif : aucune VM Podman requise.
Il utilise un nom unique, un kubeconfig et des artefacts propres a chaque
execution, refuse un cluster preexistant et ne supprime que sa propre
creation reussie. Les ports sont surchargeables pour eviter les collisions.

Depuis la racine du depot :

```bash
KWOK_RUNTIME=binary KWOK_KUBE_VERSION=v1.35.6 \
  E2E_DEBUG_ADDR=127.0.0.1:38085 E2E_METRICS_PORT=38087 E2E_HEALTH_PORT=38088 \
  bash karpenter-provider-scaleway/hack/kwok-e2e/run.sh
```

Ce test prouve le cycle NodePool statique 0 -> 1 -> 0, les conditions
Registered/Initialized, l'identite providerID, la disparition du NodeClaim
et du Node, l'arret du serveur simule et l'absence de reservation restante.
Il ne teste ni une bascule VM/EM sous charge, ni l'eviction de workloads
avec PDB, ni le boot Talos reel.

Pour exercer aussi le RBAC Garage, conserver explicitement ce banc avec
`KEEP=1`, puis fournir le kubeconfig et le contexte uniques annonces :

```bash
python3 scripts/verify-garage-rbac.py \
  --kubeconfig /chemin/du/banc/kubeconfig \
  --context kwok-karpenter-em-e2e-IDENTIFIANT
```

Le test cree seulement des namespaces jetables et des Secrets factices,
refuse des namespaces deja presents et nettoie ceux qu'il a crees. Il
utilise le RBAC du manifeste reel et l'identite `garage-bootstrap` : les
trois Secrets peuvent etre crees, modifies et lus ; la lecture et la
modification d'un Secret etranger, la creation dans `identity` et la
suppression sont refusees. Le droit `create` reste namespace-wide dans
`storage` : ce test ne pretend pas le restreindre a trois noms.
Apres un run `KEEP=1`, arreter uniquement le controleur indique s'il tourne
encore, puis utiliser la commande de suppression annoncee, avec son
`--kubeconfig` explicite. Ne pas supprimer tous les clusters KWOK.

### Recette complete et suites

#### Piege Podman : montage injecte dans Talos

Sur le banc Fedora, `/usr/share/containers/mounts.conf` injectait
`/usr/share/rhel/secrets:/run/secrets` en lecture seule dans les conteneurs
Talos. Le `hostPath /run` de Kubescape propageait ce montage : containerd
ne pouvait plus monter le jeton du service account, d'où `StartError`.
Ce n'était pas une raison de désactiver Kubescape, son compte de service
ou ses protections. La même version du chart démarre après correction du
montage hôte.

Préparer **uniquement une VM Podman dédiée** avec un fichier
`/etc/containers/mounts.conf` vide, avant de créer ses nœuds. Ce fichier
remplace les montages automatiques de la distribution ; ne pas modifier
celui d'un moteur partagé sans analyser les besoins de ses autres projets.
Voir la [configuration officielle des montages Podman](https://github.com/containers/common/blob/main/docs/containers-mounts.conf.5.md).
Une modification du fichier n'enlève pas les montages des conteneurs déjà
créés : recréer les nœuds jetables, pas les volumes d'autres applications.

`local-docker-up.sh` vérifie désormais `/proc/1/mountinfo` sur chaque nœud
et refuse un `/run/secrets` en lecture seule. Le contrôle est aussi utilisable
seul avec une configuration Talos isolée :

```bash
TALOSCONFIG=/chemin/du/banc/talosconfig TALOSCTL=/chemin/vers/talosctl-v1.12.9 \
  bash scripts/check-talos-container-mounts.sh CONTEXTE_DU_BANC IP_NOEUD_1 IP_NOEUD_2
```

La CLI Talos doit correspondre à l'image. Avec 1.12.9, `cluster create docker`
n'accepte pas `--wait=false` et attend le réseau ; le script prépare donc le
CNI pendant cette attente. En mode `SKIP_CILIUM=1`, il attend l'API et
l'enregistrement de tous les nœuds puis arrête seulement son propre contrôle
de santé, avant de laisser Tofu installer Cilium.

#### Resultats des deux recettes

La première recette du 26 septembre a utilisé une VM Lima dédiée (8 CPU, 28 Gio,
120 Gio), une copie du travail non commite, son propre Gitea et ses propres
etats, certificats et contextes. Le moteur Podman partagé conservait alors
ses 49 conteneurs et 126 volumes ; le nettoyage prealable n'a concerne que
des images inutilisees. Voir le
[premier compte rendu et ses limites](../reviews/2026-09-26-local-platform-e2e.md).
Une seconde VM vide a ensuite validé Kubescape et les 18 releases, avec
nouveaux états et nouvelles CA. Voir la
[reconstruction et les correctifs](../reviews/2026-09-26-kubescape-clean-bootstrap.md).
Le collecteur de logs a connu des OOM à froid puis s'est rétabli ; la
convergence finale n'est pas un test d'endurance ou de capacité.

Le harnais historique a ete remplace par le [parcours maintenu strictement
isole](e2e-isolated.md). `make e2e-local` exige desormais `E2E_CONFIG` :
repertoire inexistant hors du depot, contexte unique et connexion Podman
non-default vers un moteur vide dedie. Il ne reutilise pas ce banc, ne touche
pas les tfstates du checkout et n'effectue aucun nettoyage automatique.
Les stacks utilisent AppRole et le bootstrap du nouveau moteur. La copie
privee du depot fournit la revision exacte controlee par Flux.
Ce remplacement est couvert par des tests de securite hors cluster ; une
execution complete sans intervention sur un nouveau banc reste a prouver.

Le nouveau controleur de recette verifie les objets attendus du graphe,
leur revision et leur etat ; les erreurs API, objets absents et bases CNPG
incompletement pretes font echouer le controle :

```bash
python3 scripts/verify-platform-ready.py \
  --kubeconfig /chemin/du/banc/kubeconfig \
  --context CONTEXTE_DU_BANC --revision SHA_GIT_COMPLET
```

Les exemptions du controleur autonome servent uniquement au diagnostic,
jamais a un verdict E2E complet. Le harnais maintenu n'en accepte aucune.
Apres la readiness stricte, il exige `scripts/verify-metrics.py` avec le meme
kubeconfig et contexte : CPU/memoire frais pour tous les noeuds Ready et
metriques de pods valides non vides. L'attente est bornee et echoue si les
donnees restent indisponibles ; elle ne prouve pas les recommandations VPA.

Restent a rejouer : parcours maintenu sans intervention, endurance et
dimensionnement mémoire, détection Kubescape et noyau sur VM Talos,
migration avec données, upgrade OpenBao HA, restauration Velero, drain/PDB
et bascule VM/EM sur matériel Scaleway.

## Historique de juillet 2026

Tout ce qui se teste SANS Scaleway ni materiel, ordonne par cout et par
ce que chaque niveau prouve. Etat des lieux au 2026-07-14 (post ADR-034
hauler, ADR-038 kubescape, ADR-039 zot, mode local-docker arm64).

## Vue d'ensemble

| Niveau | Quoi | Duree | Prerequis | Etat |
|---|---|---|---|---|
| 0 | Statique (validate/render/tests unitaires) | ~3 min | rien | ✅ tout existe — a bundler en 1 cible |
| 1 | Rendu + schemas (kubeconform, HR×values) | ~22 s | brew kubeconform | ✅ `make verify-render` (2026-07-18) — 17/17 HRs aux versions du registre, kubeconform -strict + catalog datree |
| 2 | Bootstrap podman E2E (platform pod) | ~15-20 min | podman rootful | ✅ cible existante, a rejouer |
| 3 | Cluster Talos local + stacks + Flux | ~10-30 min | local-docker-up, **VM podman 24 Gi / 12 vCPU** | ✅ 3.1 valide le 2026-07-15 (voir verdict) ; 3.2-3.4 ⬜ |
| 4 | Mirror hauler → containerd Talos | ~30 min | niveaux 2+3 | ✅ mode connecte VALIDE (porte e2e, ~10 min de convergence) ; mono-segments fermes par double endpoint overridePath (2026-07-18) ; air-gap charts = phase 3 ADR-034 |
| 5 | Harnais kwok du provider karpenter | ~2-4 h build | brew kwok | ✅ VALIDE sur la branche karpenter (cycle NodeClaim complet) |

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

> **Historique (juillet 2026)** : les extensions et resultats ci-dessous
> decrivent l'ancienne repartition des proprietaires (dont Garage gere par
> OpenTofu et un inventaire de 16 HelmReleases). Ce ne sont ni le parcours
> actuel ni son verdict. Pour executer les stacks actuelles avec inventaire
> strict, revision exacte et metriques fonctionnelles, utiliser le
> [harnais E2E maintenu et isole](e2e-isolated.md).

Extensions historiques, dans l'ordre de valeur retenu a l'epoque :

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
   (zot Ready avec S3 Garage valide par la porte e2e-local — le smoke
   push/pull dedie reste optionnel.)
3. **kubescape smoke — stack VALIDEE sur le tier VM (2026-07-18)** : la
   stack complete (operator, storage, node-agent eBPF + clamav) tourne
   2/2 sur les VMs kvmlab. NUANCE : le depot d'un EICAR (2 tentatives,
   pod cree apres l'agent, fichier executable) n'a produit AUCUN
   evenement observable (logs agent, logs clamav, pas de CRD alert) —
   la detection demande un reglage du profil (periodicite du scan
   clamav, exporteurs d'alertes, periode d'apprentissage) : follow-up
   dedie avant de compter sur le pilier malware en prod. L'ancienne
   attribution de StartError au simulateur et l'allowlist ont ete invalidees
   par la recette de septembre : montage Podman injecte a corriger, aucune
   exemption dans le harnais courant. Le banc Longhorn (ADR-041) est passe sur le meme cluster :
   chart 1.11.3, PVC Bound sur la StorageClass longhorn, ecriture/
   lecture prouvee via iscsi + extensions chargees par l'upgrade OS.
4. **Golden path tofu-first** (l'ordre REEL du pipeline — leçon
   œuf-poule du run 3.1 : en Flux-first, cert-manager/openbao
   appartiennent a Flux avant que leurs preconditions tofu n'existent,
   et il faut poser a la main 7 secrets + 2 Certificates + 7 seeds KV ;
   en tofu-first tout cela est pose par les stacks, comme en prod).
   L'ancien runbook a contexte fixe n'est plus le point d'entree E2E.
   Utiliser le [parcours isole](e2e-isolated.md), qui ne reutilise ni le
   kubeconfig global ni les etats ou le Gitea d'un autre environnement.

   Valide en plus du 3.1 : l'ordre day-1, le handoff tofu→Flux
   (adoption des releases Helm), et les seeds reels (secrets.tf).

   **RESULTAT HISTORIQUE — PASS au run 12 (2026-07-18)** :
   l'ancien script combinait auto-kick, allowlist Kubescape et teardown.
   Ses assertions pouvaient accepter une erreur API ; ce verdict n'est
   pas une preuve de recette actuelle. Ces comportements ont ete retires.
   Convergence mesuree : ~10 min avec le mirror hauler (auto-detecte
   sur :5001 — `hauler store serve registry --store haul-arm64 -p 5001`).
   Usage : nightly + porte de release ADR-037 (pas de tag qa/prod sans
   E2E vert). La campagne de rodage (12 runs) a corrige 15 defauts
   reels : ghost dependsOn, image arch-locked, PDB double-owner,
   RBAC TokenRequest, chargement pki_int, set-eu/grep -c, course
   login/init OpenBao, PushSecret non-atomique (propriete perdue),
   refreshInterval 1h gelant les premieres synchros, timeouts HR
   install-only, contextes talosconfig fantomes, OOM vmagent/vlogs,
   PSA kubescape, deadline garage a froid, isolation d'etat E2E.
   Acquis du 2026-07-16 en attendant : la variante manuelle-fidele sur
   le cluster Flux-first a prouve TOUTE la chaine post-day-1 —
   issuer bootstrap Ready → Certificates emis → OpenBao Infra
   auto-init + scale HA x3 (values declaratives) → Job Flux
   bootstrap-openbao-pki Completed (pki_int, roles, auth k8s) →
   ClusterSecretStore "store validated" (auth kubernetes, role eso).

Limites structurelles du mode container : pas de vraie surface OS Talos
(upgrade kernel, machine config bas niveau), 1 seul CP (pas de quorum
etcd 3 noeuds — limite CLI talosctl, voir Dimensionnement), pas de
PN/LB. Ces limites sont levees par le tier VM ci-dessous.

### Tier VM — lab nested-KVM Lima (VALIDE 2026-07-17)

La virtualisation imbriquee est disponible sur Apple Silicon M3+ /
macOS 15+ (FEAT_NV2, expose par Virtualization.framework). Une VM Lima
`vz` avec `nestedVirtualization: true` fournit `/dev/kvm` → libvirt →
**`envs/local` tourne INCHANGE sur le Mac** (provider terraform natif).
Prouve sur M5 Max : 3 CP + 1 worker Talos v1.12.9 arm64 en VMs KVM,
**quorum etcd 3/3 membres votants**, bootstrap + kubeconfig par le
module talos-cluster.

Runbook (config Lima : scratchpad `kvmlab.yaml` — vz, nested, 10 vCPU /
32 Gi / 120 Gi, ~/workspace/st4ck monte en RO) :

1. `limactl create --name=kvmlab kvmlab.yaml && limactl start kvmlab`
   → verifier `/dev/kvm` dans la VM.
2. Dans la VM : libvirt-daemon-system + qemu-system-arm +
   qemu-efi-aarch64 + qemu-utils, opentofu (deb), talosctl arm64,
   pool dir `images`, clone du repo depuis le Gitea du bootstrap
   (auth par header Basic — le mot de passe contient des `/`).
3. `tofu apply` de envs/local avec `-var talos_arch=arm64
   -var libvirt_machine=virt
   -var libvirt_firmware=/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd`.

Pieges rencontres (tous integres au code ou ci-dessous) :
- `/bin/sh` = dash sur Ubuntu → `pipefail` KO (fixe : interpreter bash
  explicite sur les provisioners).
- `libvirt_firmware` DOIT etre un chemin liste dans
  `/usr/share/qemu/firmware/*.json` (le AAVMF_CODE.fd nu n'y est pas →
  « Unable to find 'efi' firmware »).
- Apres `virsh vol-upload` : `chown libvirt-qemu:kvm` sur les qcow2.
- AppArmor bloque le fichier de backing → `security_driver = "none"`
  dans /etc/libvirt/qemu.conf (lab jetable, assume).
- Un create rate laisse des domaines definis hors etat tofu →
  `virsh undefine --nvram` avant re-apply.

**Banc CNI + upgrades/extensions — VALIDE aussi (2026-07-17)** :
- `stacks/cni` applique (tofu, backend local, kubeconfig du lab) →
  cilium kube-proxy-free + local-path, **4/4 nodes Ready**, coredns ok.
- **Upgrade OS reel** : `talosctl upgrade --image
  factory.talos.dev/installer/<schematic>:v1.12.9 --wait` sur wrk-1
  avec un schematic incluant `iscsi-tools` + `util-linux-tools`
  (prerequis Longhorn, ADR-041) → reecriture OS, reboot, rejoin,
  post-check passed, extensions visibles via `talosctl get
  extensions`, node Ready. Schematic du banc :
  `53513e54bb39202f35694412577a6bc53d484744d35a126e5d42ef34785c0d83`.

C'est la boucle complete que ni les containers ni un cluster cloud
sans frais ne permettaient : machine config bas niveau, upgrade
kernel/OS, extensions systeme — le banc Longhorn est operationnel.

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
