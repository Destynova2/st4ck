# Harbor arm64 + OpenClarity replacements — research report

**Date d'observation : 2026-07-13.** Toutes les données d'architecture ont été vérifiées par
inspection directe des manifests (Docker Hub / ghcr.io / quay.io) et via l'API GitHub, pas
seulement à partir de prose.

---

# Q1 — Harbor sur arm64 (as of 2026-07)

## Verdict : arm64 est mergé dans `main` mais **n'est dans aucune release GA**. Toutes les images publiées jusqu'à v2.15.2 incluse sont amd64-only.

### Preuve dure (inspection Docker Hub, 2026-07-13)

| Tag | Publié | Architectures |
|---|---|---|
| `goharbor/harbor-core:v2.15.2` (dernière GA) | 2026-07-02 | **amd64 seulement** |
| `goharbor/harbor-core:v2.15.1` / `v2.15.0` / `v2.14.0` | 2026-05 / 2026-03 / 2025 | **amd64 seulement** |
| `harbor-portal`, `harbor-db`, `harbor-jobservice`, `registry-photon`, `trivy-adapter-photon`, `harbor-registryctl`, `harbor-exporter`, `nginx-photon` @ v2.15.2 | 2026-07-02 | **amd64 seulement** |
| `goharbor/harbor-core:dev` + `dev-arm64` | **2026-07-13** | **amd64 + arm64** ✅ |

### Ce qui a changé en 2026

- [PR #22311 « Full Multi-Architecture Enablement for Harbor (amd64 + arm64) »](https://github.com/goharbor/harbor/pull/22311)
  **mergée le 2026-05-12** (matrice CI amd64/arm64 sur runners `ubuntu-24.04-arm`, tooling, release plumbing).
- [PR #23282 « build valkey from source to support arm64 »](https://github.com/goharbor/harbor/pull/23282) mergée le 2026-06-02.
- [`.github/workflows/publish_release.yml`](https://github.com/goharbor/harbor/blob/main/.github/workflows/publish_release.yml)
  sur `main` boucle désormais `for arch in amd64 arm64`, crée des **manifests multi-arch**
  et publie `harbor-offline-installer-*-arm64.tgz` / `harbor-online-installer-*-arm64.tgz`.
  `build-package.yml` builde `platforms: linux/amd64,linux/arm64`.
- **La branche `release-2.15.0` ne contient rien de tout ça** → pas d'arm64 dans les patchs 2.15.x.

**Conclusion : l'arm64 GA devrait arriver avec la prochaine mineure (2.16.x, coupée depuis `main`).
Aucune date engagée as of 2026-07.** Cadence Harbor ≈ trimestrielle (2.15.0 = 2026-03-20).

Historique des tentatives avortées (fermées par le stale-bot, sans réponse mainteneur) :
[#22229](https://github.com/goharbor/harbor/pull/22229) (fermée 2025-12-01 après 30 j d'inactivité,
15+ 👍 sur « pourquoi ça n'avance pas ? »), [#21982](https://github.com/goharbor/harbor/pull/21982),
[#21825](https://github.com/goharbor/harbor/pull/21825) ;
[issue #21125](https://github.com/goharbor/harbor/issues/21125) fermée *not planned* ;
[#22491](https://github.com/goharbor/harbor/issues/22491) (demande arm64 pour v2.14, oct. 2025) fermée sans réponse.
[#12935 « ARM64 offline package »](https://github.com/goharbor/harbor/issues/12935) toujours ouverte.

### Builds arm64 tiers

| Source | Statut 2026-07 | arm64 ? | Utilisable ? |
|---|---|---|---|
| [`goharbor/harbor-arm`](https://github.com/goharbor/harbor-arm) | **Mort** — dernier commit 2022-03, dernier push 2023-09, 30 issues ouvertes, 0 release | n/a | ❌ |
| [`hzliangbin/harbor-arm64`](https://github.com/hzliangbin/harbor-arm64) | Fork de Harbor **v1.9.3** | oui | ❌ préhistorique |
| [`octohelm/harbor`](https://github.com/octohelm/harbor) | Dernier push 2025-10-17, 72★, 1 mainteneur. `ghcr.io/octohelm/harbor/harbor-core:v2.14.0` vérifié **linux/amd64 + linux/arm64** | ✅ | ⚠️ keyman risk, retard sur upstream |
| **Bitnami** `bitnami/harbor-*` | **Retirées du namespace gratuit** (liste de tags vide ; dernier push 2025-08-14). Copies gelées dans `bitnamilegacy/harbor-core:2.13.2-debian-12-r3` (2025-08-19, amd64+arm64, **plus aucun correctif CVE**). Le chart [`bitnami/charts/bitnami/harbor`](https://github.com/bitnami/charts/tree/main/bitnami/harbor) s'arrête en 27.0.2 (2025-08-13) et pointe encore vers `docker.io/bitnami/harbor-core:2.13.2` **qui n'existe plus** → chart cassé pour les utilisateurs gratuits. arm64 seulement via Bitnami Secure Images (payant) | (avant : ✅) | ❌ |
| [`goharbor/harbor-helm`](https://github.com/goharbor/harbor-helm) v1.19.1 (2026-05-27) | Agnostique de l'arch — référence simplement les images `goharbor/*` | — | ✅ (bloqué par les images) |

### Alternatives registry arm64-native

| | **zot** | **Quay** (projectquay) | **distribution/registry 3.x** | Harbor (référence) |
|---|---|---|---|---|
| arm64 | ✅ `ghcr.io/project-zot/zot:v2.1.18` = linux/amd64 + **linux/arm64** (+ freebsd) | ✅ `quay.io/projectquay/quay:3.15.0` = amd64/**arm64**/ppc64le/s390x | ✅ | ❌ (GA) |
| Gouvernance | **CNCF Sandbox** (depuis 2022-12-13 ; [#2117](https://github.com/project-zot/zot/issues/2117) demande le passage incubating) — 2,4 k★ | Red Hat | CNCF Distribution | CNCF Graduated |
| Dernière version | v2.1.18 (2026-06-24), cadence 3–4 semaines | 3.15.x | 3.x | v2.15.2 |
| Scan de vulns | ✅ **Trivy embarqué** (`go.mod` : `aquasecurity/trivy v0.72.0` + `trivy-db` 2026-06-29) — recherche CVE via API/UI | ✅ Clair | ❌ | ✅ adapter Trivy |
| Signatures | ✅ `extensions.trust` — vérif **cosign + notation** | ✅ cosign | ❌ | ✅ |
| Stockage | filesystem + **S3**, cache blob/meta redis ou dynamodb, dedup, GC en ligne, retention policies | S3/GCS/Swift + Postgres + Redis | filesystem/S3 | filesystem/S3 |
| Scale-out | ✅ réplicas stateless sur S3 partagé, routage par hash ([doc](https://zotregistry.dev/v2.1.0/articles/scaleout/)) — *pas self-healing* si un réplica tombe | ✅ | ✅ | ✅ |
| AuthN/Z | htpasswd, LDAP, **OIDC** (github/gitlab/google/générique), bearer, API keys ; **RBAC par identité/groupe sur chemin de repo** | RBAC org/team, robots | aucun | RBAC projet, robots |
| Webhooks | ✅ `extensions.events` — sinks **HTTP (CloudEvents) + NATS** | ✅ | ❌ | ✅ |
| Mirror / proxy-cache | ✅ `extensions.sync` — miroir périodique **+ pull-through à la demande** | ✅ mirroring | pull-through seul | ✅ |
| UI | ✅ zui | ✅ | ❌ | ✅ |
| Chart Helm | ✅ [project-zot/helm-charts](https://github.com/project-zot/helm-charts) (actif) | Operator | ✅ | ✅ |
| Poids | 1 binaire Go | Postgres + Redis + Clair + Quay (lourd) | minuscule | 8–9 conteneurs |

**Fonctionnalités Harbor réellement perdues avec zot :** projets + **quotas** par projet,
**robot accounts**, **replication push vers registries étrangers** (adapters ECR/ACR/GCR/DockerHub —
le `sync` de zot est *pull-only* depuis des registries dist-spec), **règles d'immutabilité de tags**,
**CVE allowlists / blocage de pull si vulnérable**, P2P preheat (Dragonfly), UI d'audit log.

Nuance importante pour notre stack : **Kyverno + cosign font déjà l'enforcement à l'admission** et
**trivy-operator scanne déjà in-cluster** → la perte « bloquer les images vulnérables/non signées »
est largement théorique.

> ### Recommandation Q1
> **Déployer zot maintenant** — arm64-natif, CNCF, binaire unique, backend S3 qui peut pointer
> directement sur **Garage**, Trivy embarqué, cosign/notation, webhooks HTTP, cache pull-through.
> Réévaluer Harbor à la **v2.16.0** (première release attendue avec arm64) seulement si on a besoin
> de projets/quotas/robot accounts/replication push.

---

# Q2 — OpenClarity est mort. Par quoi le remplacer.

## Verdict : **archivé le 2026-05-29** (dépôt read-only ; l'org GitHub a été archivée vers le 2026-06-01). Dernière release **v1.1.3, 2025-02-05** ; dernier commit 2026-02-10. Site de doc et canaux Slack dépréciés. **Aucun successeur annoncé.**

Signal révélateur : un commit de décembre 2025 s'intitule *« Change Postgresql repository to
bitnamilegacy »* — le projet ne faisait plus que colmater ses dépendances mourantes.

Périmètre de scanners qu'OpenClarity agrégeait (agentless, multi-assets) :
**syft / trivy / cyclonedx-gomod** (SBOM) · **grype / trivy** (vulns) · **gitleaks** (secrets) ·
**ClamAV + YARA** (malware) · **chkrootkit** (rootkits) · **Go exploit-db** (exploits) ·
**Lynis / Dockle / KICS** (misconfig).

### Couverture des capacités sur k8s (arm64 vérifié)

| Capacité OpenClarity | **trivy-operator** (déjà déployé) | **Kubescape 4.0** | **NeuVector 5.5** | Tetragon + Kyverno (déjà déployés) |
|---|---|---|---|---|
| SBOM | ✅ `SbomReport` | ✅ (kubevuln) | ⚠️ partiel | ❌ |
| Vulnérabilités | ✅ `VulnerabilityReport` (+ nodes / control-plane) | ✅ kubevuln | ✅ scanner | ❌ |
| Secrets dans les images | ✅ `ExposedSecretReport` | ⚠️ | ⚠️ | ❌ |
| Misconfig / posture / compliance | ✅ ConfigAudit + RBAC + Infra + NSA/CIS/PSS | ✅ NSA/MITRE/CIS/SOC2 (le plus complet) | ✅ CIS/PCI | Kyverno (policy, pas reporting) |
| **Malware (ClamAV)** | ❌ | ✅ **node-agent, moteur ClamAV** (trojans, cryptominers, webshells, ransomware ; base virale = sous-ensemble ClamAV adapté k8s) | ❌ (règles comportementales, pas de moteur AV) | ❌ |
| **Rootkits (chkrootkit)** | ❌ | ❌ | ❌ | ❌ **(aucun remplaçant maintenu nulle part)** |
| Exploit-DB matching | ❌ | ❌ | ❌ | ❌ |
| FIM (intégrité fichiers) | ❌ | ✅ fanotify | ✅ | ⚠️ (Tetragon peut le faire) |
| Détection runtime | ❌ | ✅ eBPF, GA en 4.0, ~1–2 % CPU | ✅ DPI/L7 | ✅ **Tetragon** |
| Gouvernance | Aqua OSS, v0.32.0 (2026-07-08) | **CNCF Incubating** (depuis 2025-01-13), 11,5 k★, v4.0.10 (2026-06-30) | SUSE, non-CNCF, 1,3 k★, 5.5 GA / 5.6.0-rc4 | CNCF |
| **arm64** | ✅ `aquasec/trivy-operator:0.32.0` amd64+arm64 | ✅ **tous** les composants vérifiés multi-arch : `quay.io/kubescape/{kubescape:v4.0.8, operator:v0.2.149, kubevuln:v0.3.142, storage:v0.0.274, node-agent:v0.3.119}` = amd64+arm64 | ✅ `neuvector/{controller,enforcer,manager,scanner}` amd64+arm64 (depuis 5.3) | ✅ |
| Poids | 1 deployment + jobs | operator + storage + kubevuln + node-agent (DaemonSet) | controller ×3 + enforcer DS + manager + scanner (**le plus lourd**) | — |

### Autres pistes malware

- [`mittwald/kube-av`](https://github.com/mittwald/kube-av) : **mort** (dernier push 2021-10, 26★).
- Image officielle `clamav/clamav` : **multi-arch** (amd64/arm64/ppc64le, tag `latest-debian13-slim`
  rafraîchi le 2026-07-13) → un DaemonSet ClamAV maison reste viable.
- **Kubescape node-agent est le seul chemin ClamAV-sur-k8s maintenu en 2026.**

### Analyse de redondance vis-à-vis de la stack existante

- **NeuVector** duplique Tetragon (runtime), Kyverno (admission) et trivy-operator (scan d'images) —
  trois fois le même travail, pour l'équivalent de 4 workloads de RAM. **Non.**
- **Kubescape** : `kubevuln` + le moteur de posture doublonnent trivy-operator.
- Seules deux choses sont réellement **additives** : le **scan malware ClamAV** et le **FIM**,
  tous deux hébergés dans `node-agent`.

> ### Recommandation Q2
> **Garder trivy-operator** comme remplaçant d'OpenClarity pour SBOM / vulns / secrets / config /
> RBAC / compliance (il couvre 5 des 7 piliers d'OpenClarity). **Écarter NeuVector** — redondance pure
> avec Tetragon + Kyverno + Trivy, pour 3–4× le coût en ressources.
> Si la détection de malware est un vrai besoin : déployer **uniquement le `node-agent` de Kubescape**
> (`capabilities.malwareDetection`, arm64 ✅) en laissant `kubevuln` / posture désactivés pour éviter
> le double scan — en assumant le recouvrement avec la couche eBPF de Tetragon.
> **Rootkits et exploit-DB n'ont aucun successeur k8s maintenu en 2026** → assumer le trou, ou
> chkrootkit dans un DaemonSet maison.

---

## Sources

- [goharbor/harbor PR #22311 (multi-arch, mergée 2026-05-12)](https://github.com/goharbor/harbor/pull/22311)
- [goharbor/harbor PR #23282 (valkey arm64, mergée 2026-06-02)](https://github.com/goharbor/harbor/pull/23282)
- [goharbor/harbor PR #22229 (fermée par stale-bot)](https://github.com/goharbor/harbor/pull/22229)
- [goharbor/harbor issue #22491 (demande arm64 v2.14)](https://github.com/goharbor/harbor/issues/22491)
- [goharbor/harbor issue #21125 (« not planned »)](https://github.com/goharbor/harbor/issues/21125)
- [goharbor/harbor issue #12935 (ARM64 offline package, ouverte)](https://github.com/goharbor/harbor/issues/12935)
- [harbor publish_release.yml (main)](https://github.com/goharbor/harbor/blob/main/.github/workflows/publish_release.yml)
- [goharbor/harbor-arm (mort)](https://github.com/goharbor/harbor-arm)
- [hzliangbin/harbor-arm64](https://github.com/hzliangbin/harbor-arm64)
- [octohelm/harbor (fork multi-arch)](https://github.com/octohelm/harbor)
- [bitnami/charts — chart harbor](https://github.com/bitnami/charts/tree/main/bitnami/harbor)
- [goharbor/harbor-helm](https://github.com/goharbor/harbor-helm)
- [project-zot/zot](https://github.com/project-zot/zot) · [features](https://zotregistry.dev/v2.1.0/general/features/) · [admin config](https://zotregistry.dev/v2.1.0/admin-guide/admin-configuration/) · [scale-out](https://zotregistry.dev/v2.1.0/articles/scaleout/) · [zot sur cncf.io](https://www.cncf.io/projects/zot/)
- [openclarity/openclarity (archivé 2026-05-29)](https://github.com/openclarity/openclarity)
- [aquasecurity/trivy-operator](https://github.com/aquasecurity/trivy-operator)
- [Kubescape devient CNCF Incubating (2025-01-13)](https://www.cncf.io/blog/2025/02/26/kubescape-becomes-a-cncf-incubating-project/)
- [Annonce Kubescape 4.0 (2026-03)](https://www.cncf.io/blog/2026/03/26/announcing-kubescape-4-0-enterprise-stability-meets-the-ai-era/)
- [kubescape/node-agent](https://github.com/kubescape/node-agent) · [Runtime Threat Detection](https://kubescape.io/docs/operator/runtime-threat-detection/)
- [neuvector/neuvector](https://github.com/neuvector/neuvector)
- [mittwald/kube-av (mort)](https://github.com/mittwald/kube-av)
