# Roadmap d'implementation — Plateforme Souveraine Air-Gapped

> CaaS Kubernetes souverain air-gapped
> 3 Gates, 9 mois, ~60 composants

---

## GATE 1 — Fondations (M0-M2)

> Objectif : management cluster operationnel, pipeline GitOps, observabilite, securite de base.
> ~200 images conteneurs.

### Phase 1.1 — Bootstrap (S1-S2)

**Pre-requis** : acces vSphere API, plan IP, DNS interne (AD)

```
1. Talos Image Factory
   └── Build image OVA Talos air-gapped (extensions, image cache)

2. Management Cluster (3 CP + 3 workers Talos)
   ├── etcd (integre a Talos)
   ├── Kubernetes v1.35.4
   └── Cilium CNI 1.17 + Hubble
       ├── eBPF (remplace kube-proxy)
       ├── Network Policies L3/L4/L7
       └── mTLS inter-workloads

3. CoreDNS
   └── Forwarding vers AD interne
```

**Livrable** : cluster 6 noeuds fonctionnel, reseau securise, DNS operationnel.

- [x] Talos v1.12.6 + Kubernetes v1.35.4 (Scaleway)
- [x] Cilium 1.17.13 + Hubble relay
- [x] Talos Factory schematic avec extension DRBD

### Phase 1.2 — CI/CD & Registry (S2-S3)

**Depends** : Phase 1.1

```
4. Harbor
   ├── Registry conteneurs (miroir ~200 images)
   └── Proxy cache
       └── Backend S3 : Garage (deploye en phase 1.6)

5. Gitea
   └── Serveur Git air-gapped

6. Woodpecker CI
   ├── Pipeline CI/CD (push-based)
   ├── Build images → Harbor
   ├── Scan Trivy → Sign Cosign
   └── Deploy via OpenTofu (7 stages sequentiels)
```

**Decision** : FluxCD et SeaweedFS retires. Voir ADR-004 et ADR-003.
- FluxCD : chicken-and-egg (Flux a besoin de Cilium pour tourner, Cilium doit etre deploye avant Flux).
  Woodpecker + OpenTofu couvre deja le CD avec ordering strict. Ajouter Flux = 2 systemes de deploiement.
- SeaweedFS : Garage (phase 1.6) remplit le meme role (S3-compatible). Pas besoin de 2 object stores.

**Livrable** : pipeline CI/CD operationnel, registry air-gapped.

- [x] Gitea (deploye sur CI VM avec Woodpecker)
- [x] Woodpecker CI (pipeline complet : validate → image → cluster → wait-api → addons → secrets → security → storage)
- [x] Harbor 1.16.2 (registry S3 Garage backend, Helm, Trivy scan integre)

### Phase 1.3 — Secrets & Identite (S3-S4)

**Depends** : Phase 1.2

```
7. OpenBao (2 instances separees)
   ├── openbao-infra : PKI intermediaire, secrets infrastructure
   └── openbao-app : secrets applicatifs

8. PKI Terraform (Root CA + Intermediate CA)
   └── Pure TLS provider — aucun service externe requis

9. cert-manager
   ├── ClusterIssuer : intermediate CA issue par OpenBao-infra
   └── Rotation automatique certificats

10. Ory Stack (Kratos + Hydra + Pomerium)
    ├── Kratos : gestion identite
    ├── Hydra : serveur OIDC/OAuth2
    ├── Pomerium : proxy authentifiant zero-trust
    └── SSO tous composants
```

**Decision** : Secrets auto-generes via `random_id` Terraform. Voir ADR-008.
- Plus de `secret.tfvars` manuels — chaque deploy genere des secrets uniques
- `random_id.*.hex` (64 chars) pour tokens/secrets generiques
- `random_id.*.b64_std` (base64, 32 raw bytes) pour Pomerium shared/cookie secrets
- Secrets injectes via `templatefile()` dans les Helm values
- Stockes dans le state Terraform (chiffre), jamais en clair sur disque

**Livrable** : zero secret en clair, authentification centralisee, PKI automatisee, secrets auto-generes.

- [x] OpenBao infra + app (2 instances Helm separees)
- [x] PKI Terraform (Root CA + Intermediate CA, pure TLS provider)
- [x] cert-manager v1.19.4 + ClusterIssuer internal-ca
- [x] Ory Kratos + Hydra (TLS public, OIDC kubernetes client auto-enregistre) + Pomerium
- [x] Secrets auto-generes (`random_id` Terraform, zero intervention manuelle)
- [x] OIDC K8s (Hydra → apiServer, `make scaleway-oidc` pour appliquer le patch talosctl)

### Phase 1.4 — Observabilite & Dashboard (S4-S5)

**Depends** : Phase 1.3 (secrets pour credentials)

```
10. victoria-metrics-k8s-stack (chart consolide)
    ├── VMSingle (stockage metriques, retention 30d)
    ├── VMAgent (scrape Cilium, kubelet, cadvisor, pods, etc.)
    ├── VMAlert + Alertmanager
    ├── Grafana (datasources auto, dashboards grafana.com)
    ├── kube-state-metrics
    └── node-exporter (compatible Talos)

11. VictoriaLogs (remplace Loki)
    ├── victoria-logs-single (stockage logs, retention 30d)
    └── victoria-logs-collector (DaemonSet, collecte logs)

12. Headlamp
    ├── UI Kubernetes (kubernetes-sigs)
    ├── S'ouvre automatiquement apres deploy monitoring (token auto-copie)
    └── Permet de suivre le deploiement des stacks restants en live

13. Platform Overview dashboard (ConfigMap sidecar Grafana)
```

**Decision** : victoria-metrics-k8s-stack consolide metriques + alertes + dashboards en un seul chart. Voir ADR-010.
- Inclut : VMSingle, VMAgent, VMAlert, Alertmanager, Grafana, kube-state-metrics, node-exporter
- VictoriaLogs remplace Loki pour les logs (victoria-logs-single + victoria-logs-collector)
- Label `cluster=talos` injecte globalement (requis par dashboards grafana.com)

**Livrable** : observabilite complete (metriques, logs, alertes, dashboards, UI live).

- [x] victoria-metrics-k8s-stack 0.72.4 (VMSingle + VMAgent + VMAlert + Alertmanager + Grafana + kube-state-metrics + node-exporter)
- [x] VictoriaLogs single 0.14.3 + collector 0.14.3 (remplace Loki + Alloy)
- [x] Headlamp 0.40.0 (auto-open dans `make scaleway-up`)
- [x] Platform Overview dashboard (ConfigMap sidecar)

### Phase 1.5 — Securite & Scanning (S5-S6)

**Depends** : Phase 1.4 (alertes pour notifications scan)

```
15. Trivy Operator
    ├── Scan vulnerabilites images
    └── Generation SBOM

16. Cosign (Sigstore)
    ├── Signature images conteneurs
    └── Verification admission (via policy)

17. Tetragon
    ├── Detection menaces runtime (eBPF)
    └── Process + network observability
    └── Note: Talos v1.12+ requiert extraHostPathMounts /sys/kernel/tracing

18. Kyverno
    ├── Pod Security Standards (enforce baseline/restricted)
    └── Admission policies

19. RBAC
    └── Roles alignes OIDC
```

**Livrable** : supply chain securisee, detection runtime, policies appliquees.

- [x] Trivy Operator 0.32.0 (node-collector desactive — ADR-011 : `scanNodeCollectorLimit: 0`)
- [x] Tetragon 1.6.0 (avec fix Talos tracefs)
- [x] Kyverno 3.7.1
- [x] Cosign verifyImages policy (Kyverno ClusterPolicy, mode audit, pret pour enforce)

### Phase 1.6 — Stockage & Backup (S6-S7)

**Depends** : Phase 1.5

```
20. local-path provisioner
    └── StorageClass par defaut

21. Garage
    ├── Stockage objet S3-compatible (Rust, leger)
    ├── 3 pods StatefulSet, PVCs sur local-path
    ├── replication_factor = 3 (replication applicative)
    └── ~100 MB RAM par pod

22. Velero
    ├── Backup application-aware
    └── Target: Garage S3
```

**Decision** : Garage seul (sans Longhorn) retenu. Voir ADR-002 et ADR-003.
- Rook-Ceph : bug parse_env Squid 19.2.3, ~30 pods, complexe
- Piraeus/LINSTOR : module kernel DRBD, ~17 pods, performant mais plus lourd
- Longhorn + Garage : ~30 pods total, ~2-3 GB RAM overhead, inutile car Garage replique deja
- Garage seul : ~3 pods, ~300 MB RAM, replication S3 native, zero dependance bloc

**Livrable** : stockage objet S3 + backups automatises.

- [x] local-path-provisioner 0.0.35 (StorageClass defaut)
- [x] Garage v2.2.0 (3 pods, S3-compatible, PVCs local-path, cluster layout configure)
- [x] Velero 11.4.0 (backup → Garage S3, BackupStorageLocation available, backup/restore teste)
- [x] Harbor 1.16.2 (registry conteneurs, S3 Garage backend, Trivy scan integre)

### Phase 1.7 — Workload Clusters via CAPI (S7-S8)

**Depends** : toutes phases precedentes

```
23. CAPI (Cluster API)
    ├── CAPS (Scaleway provider) — demo/dev
    │   └── Creation instances Scaleway a la demande
    ├── CAPV (vSphere provider) — production air-gapped
    │   └── Creation VMs, DHCP + MAC reservations
    └── CAPT (Talos provider)
        └── Configuration OS Talos (commun aux 2 providers)
```

**Livrable** : capacite de creer/detruire des workload clusters a la demande.

- [x] CAPI + CAPT + CAPS (demo Scaleway) — clusterctl init + workload-cluster.yaml
- [ ] CAPI + CAPT + CAPV (production vSphere — requiert acces API)

### Gate 1 — Criteres de passage

- [x] Management cluster 6 noeuds Talos stable (3 CP + 3 workers)
- [x] Pipeline CI/CD complet (Woodpecker + OpenTofu, 8 core stacks + 5 KaaS)
- [x] Harbor registry (S3 Garage backend, Trivy scan integre)
- [x] Observabilite complete (metriques + logs + alertes)
- [x] Secrets & PKI (OpenBao infra/app + cert-manager + Root/Intermediate CA)
- [x] Securite runtime (Trivy + Tetragon + Kyverno + Cosign policy)
- [x] Stockage S3 + backup (Garage + Velero, BSL Available)
- [x] OIDC K8s fonctionnel (Hydra TLS + client auto-enregistre + patch talosctl)
- [x] Cosign (Kyverno verifyImages ClusterPolicy, mode audit)
- [x] Velero backup/restore teste (`make velero-test` — backup + restore namespace)
- [x] 1 workload cluster cree/detruit via CAPI (demo Scaleway: `make capi-init && make capi-create && make capi-delete`)


---

## GATE 2 — Services & IA legere (M3-M5)

> Objectif : bases de donnees, IA CPU-only, CMS, ~350 images.

### Phase 2.1 — Bases de donnees (S9-S10)

**Depends** : Gate 1, Garage (stockage)

```
25. CloudNativePG
    └── Operateur PostgreSQL K8s

26. PostgreSQL
    ├── HA (3 replicas via CloudNativePG)
    ├── Backup → Garage S3 (via Velero ou barman)
    └── Secrets via OpenBao
```

**Livrable** : PostgreSQL production-ready, HA, backups automatises.

### Phase 2.2 — IA legere CPU (S10-S12)

**Depends** : Phase 2.1 (PostgreSQL pour metadata)

```
27. Ollama
    └── Inference LLM locale CPU

28. Mistral 7B (quantise)
    └── LLM souverain FR, embarque dans Harbor

29. Phi-4
    └── Classification / embedding

30. Open WebUI
    ├── Interface chat
    └── Backend: Ollama
```

**Livrable** : assistant IA interne fonctionnel, 100% air-gapped, CPU-only.

### Phase 2.3 — CMS & contenu (S12-S13)

**Depends** : Phase 1.2 (Gitea)

```
31. DecapCMS
    ├── CMS WYSIWYG GitOps
    └── Backend: Gitea
```

**Livrable** : edition de contenu pour non-developpeurs.

### Gate 2 — Criteres de passage

- [ ] PostgreSQL HA operationnel (3 replicas, backup teste)
- [ ] Ollama + Mistral 7B repond aux requetes
- [ ] Open WebUI accessible via SSO
- [ ] ~350 images dans Harbor, toutes scannees

---

## GATE 3 — Production & IA GPU (M6-M9)

> Objectif : stockage production, IA GPU, analytics, self-service. ~500+ images.

### Phase 3.1 — Stockage production (S14-S16)

**Depends** : Gate 2

```
32. Garage (renforce)
    ├── Tuning production (compression, quotas)
    ├── Backup Velero → Garage S3
    └── DR inter-sites via replication Garage multi-site
```

**Option** :
```
    Rook-Ceph (si besoin bloc distribue / CephFS ReadWriteMany)
    └── CephFS pour ReadWriteMany
```

**Livrable** : stockage production avec DR inter-sites.

### Phase 3.2 — IA GPU (S16-S20)

**Depends** : Phase 3.1 (stockage pour modeles), GPU disponibles

```
33. vLLM
    └── Inference GPU (PagedAttention)

34. KubeAI
    ├── Orchestration multi-modele K8s
    ├── LoRA adapters
    └── Backend: vLLM

35. Mixtral 8x22B
    └── MoE 141B, production — souverain FR

36. Falcon 3
    └── Alternative Tier 2 (TII, Apache 2.0)
```

**Livrable** : inference LLM GPU production, multi-modele.

### Phase 3.3 — Pipeline RAG (S20-S24)

**Depends** : Phase 3.2 (vLLM), Phase 2.1 (PostgreSQL)

```
37. Tika
    └── Extraction texte documents

38. bge-m3 (ou e5-mistral)
    └── Embeddings multilingues

39. Qdrant
    └── Base vectorielle

Pipeline complet :
    Documents → Tika → Chunking → bge-m3 → Qdrant → vLLM → Reponse
```

**Livrable** : RAG operationnel sur documents internes.

### Phase 3.4 — Analytics & Event streaming (S22-S26)

**Depends** : Phase 3.1 (stockage)

```
40. ClickHouse (operateur Altinity)
    └── OLAP analytics

41. Valkey
    └── Cache in-memory (fork Redis, BSD)

42. Kafka (Strimzi)
    └── Event streaming
```

**Livrable** : pipeline analytics temps reel.

### Phase 3.5 — Plateforme self-service (S26-S30)

**Depends** : Phases 3.1-3.4

```
43. Cozystack
    ├── PaaS/DBaaS self-service
    ├── PostgreSQL (via CloudNativePG)
    ├── Valkey
    ├── Kafka (via Strimzi)
    └── S3 (via Garage)
```

**Livrable** : equipes metier creent leurs propres services en self-service.

### Phase 3.6 — DR & resilience finale (S28-S32)

**Depends** : Phase 3.1 (Garage)

```
44. Garage DR
    └── Replication multi-site cross-cluster

45. Velero (renforce)
    ├── Backup multi-cluster
    └── Strategie 3-2-1 complete (Garage S3 backend)
```

**Livrable** : DR operationnel, RPO/RTO valides.

### Gate 3 — Criteres de passage

- [ ] Garage production avec DR multi-site
- [ ] vLLM + KubeAI + Mixtral operationnel sur GPU
- [ ] Pipeline RAG fonctionnel (Tika → Qdrant → vLLM)
- [ ] ClickHouse + Kafka operationnels
- [ ] Cozystack self-service valide par equipes metier
- [ ] ~500+ images dans Harbor
- [ ] Conformite complete (audit securite interne)

---

## Graphe de dependances global

```
Phase 1.1 Bootstrap (Talos + Cilium + CoreDNS)                    [DONE]
    │
Phase 1.2 CI/CD & Registry (Gitea + Woodpecker + Harbor)          [DONE]
    │
    ├── Phase 1.3 Secrets & Identite (OpenBao x2 + PKI + Ory)     [DONE]
    │       │
    │       Phase 1.4 Observabilite (VictoriaMetrics + VictoriaLogs + Headlamp)  [DONE]
    │           │
    │           Phase 1.5 Securite (Trivy + Tetragon + Kyverno)    [DONE]
    │               │
    │               Phase 1.6 Stockage (local-path+Garage+Velero)  [DONE]
    │                   │
    │                   Phase 1.7 CAPI (requiert vSphere)
    │                       │
    │                       ══════════ GATE 1 ══════════
    │                       │
    │               Phase 2.1 PostgreSQL (CloudNativePG)
    │                   │
    │                   ├── Phase 2.2 IA legere (Ollama + Mistral 7B + Open WebUI)
    │                   │
    │                   Phase 2.3 CMS (DecapCMS)
    │                       │
    │                       ══════════ GATE 2 ══════════
    │                       │
    │               Phase 3.1 Stockage prod (Garage renforce)
    │                   │
    │                   ├── Phase 3.2 IA GPU (vLLM + KubeAI + Mixtral)
    │                   │       │
    │                   │       Phase 3.3 RAG (Tika + Qdrant + bge-m3)
    │                   │
    │                   ├── Phase 3.4 Analytics (ClickHouse + Valkey + Kafka)
    │                   │
    │                   Phase 3.5 Self-service (Cozystack)
    │                   │
    │                   Phase 3.6 DR (Garage DR + Velero renforce)
    │                       │
    │                       ══════════ GATE 3 ══════════
```

---

## Phase D/E/F — Hardening architectural (Postmortem 2026-04-30)

Issues remontees pendant le test rebuild 0→100 (~22 fixes architecturaux deja
landed dans `git log 02f2ad7..HEAD`). 3 ameliorations structurelles a
prioriser pour des rebuilds rapides + resilients.

### Phase D — VPC Private Network partage (en cours, ~1h)

**Probleme** : CI VM et cluster crees dans des PNs Scaleway differents
(L2-isoles), traffic inter-PN timeout. CI stack lookup conditionnel du PN
cluster vide a la creation (chicken/egg de l'ordre bootstrap).

**Solution** : CI stack OWN le PN partage, cluster stack le reference via
data source. Nouvel ordre : `scaleway-ci-apply → scaleway-up`.

→ Bug #31 — Agent #6 en cours. ADR-029 a creer.

### Phase E — Mirror registry sur CI VM (~1 jour, gain 5-10x rebuild)

**Probleme** : chaque rebuild pull ~25 images container + ~15 charts Helm
depuis registries publics (docker.io, ghcr.io, quay.io, artifacthub).
Rebuild = 80% network, 20% compute (~30-45min). Sujet aux rate limits
et outages public.

**Solution** : deplacer Harbor + Garage du cluster (`stacks/storage/`) vers
la CI VM (bootstrap layer) :
- Harbor mirror : registries publics → CI VM (intra-VPC)
- Garage S3 : Helm charts + binaries Talos pre-buildes
- Talos `registry-mirror` patch redirige sur CI VM Harbor
- Cron Arbor (`make arbor`) sync upstream periodique

→ Rebuild ~5-10min au lieu de 30-45min. Air-gap ready. ADR-029bis a creer.

### Phase F — Consolidation image VM dans CI VM (~4h)

**Probleme** : 2 VMs Scaleway distinctes pour platform (CI VM persistante)
et builder Talos image (image VM ephemere ~15min). Duplication infra,
maintenance, cout.

**Solution** : merger build Talos image dans CI VM (a la demande, via cron
ou make target). CI VM type plus gros (DEV1-XL ou GP1-S) couvre les 2
besoins.

→ -1 VM permanente, simplification Makefile (`scaleway-image-*` devient
`make ci-build-image`). ADR-030 a creer.

### Sequencement recommande

```
Phase D (now)     → debloque rebuild 100/100 valide (ne change pas archi)
Phase E (gate 3) → mirror registry pour AIR-GAP (perf gain marginal ~30s — corrige hypothese)
Phase F (after)  → -1 VM, simplification ops
Phase F-bis (NEW) → refactor scripts terraform_data (VRAI gain perf, ~-7min PKI)
Phase G (R&D)    → multi-tier scheduling VM/BM/GPU cost-optimised (decision matrix)
Phase H (apres D) → rebase + merge feat/kamaji-karpenter, deploy KaaS layer
```

**Correction post-mesure 2026-04-30** : Phase E (mirror registry) initialement sold
comme "5-10x rebuild speedup" est en realite **gain marginal** car Talos OVA
pre-cache deja toutes les images. Mesures runtime PKI :
- "quay.io/openbao/openbao:2.5.1" → 0s pull (already present)
- "busybox:latest" → 0s pull (already present)
- Pod scheduled → Ready : 7-18s par pod
- TOTAL pulls PKI : ~30-60s

Le bottleneck reel des 10min PKI = **scripts terraform_data avec `sleep 5` × 90
iterations** + scale 1→3 sequentiel + Bug #32 recovery loops. Phase F-bis cible
ca directement.

### Phase G — Multi-tier scheduling VM/BM/GPU (decision matrix, ~3 mois)

**Probleme** : workloads heterogenes (HTTP burst, training sustained, GPU AI)
mappent mal sur un seul type de node. Sur Scaleway :
- VM Pro2-S (8 vCPU partages, 32GB) : ~€0.10/h facture seconde
- **Elastic Metal EM-A610R** (6C/12T DEDIES, 32GB) : **€0.11/h facture heure**
- VM 64GB : ~€0.50/h
- **Elastic Metal EM-B220E** (8C/16T DEDIES, 64GB) : **€0.333/h** (-33%)

→ Le bare metal Scaleway est **HOURLY-billed sans engagement**, pas
mensuel. Break-even bare metal vs VM est ~2-4 cores DES LA 1ere heure
(pas le seuil "1h30 runtime" initial). Le vrai trigger est **taille du
workload**, pas duree.

**Solution productisee** : **vCluster Auto Nodes** (sortie sept 2025) fait
exactement ce pattern :
- Karpenter par tenant cluster
- Multi-provider NodePool (KubeVirt + Terraform + custom Scaleway)
- Cross-provider workload migration runtime (cost-aware)
- Auto-reclaim idle nodes
- KubeVirt wrapper pour stateful (live-migration)

**Probleme** : ta branche `feat/kamaji-karpenter` reimplemente ce pattern
manuellement avec Kamaji + custom Karpenter glue. Kamaji ne supporte PAS
Karpenter natif (que Cluster Autoscaler via CAPI). vCluster Auto Nodes
a productise la solution avant qu'on ait fini.

#### Decision matrix (ADR-031 a creer)

| Option | Effort | Vendor lock | Maturite | Pour qui |
|---|---|---|---|---|
| **A — Continuer Kamaji + Karpenter glue** | 2-3 mois R&D | Aucun (OSS) | Construit | Sovereign 100%, accepter R&D |
| **B — Pivot vCluster Auto Nodes** | 2 sem refactor | Loft Labs (vCluster Pro commercial pour full features) | Production-ready | Time-to-market |
| **C — Hybride : Kamaji + pattern Auto Nodes (Karpenter-per-tenant + multi-provider)** | 1-2 mois | Aucun | Mid | Stack-coherent, modulaire |

#### Bare metal layer pour Option A/C

| Option | OS support | CAPI | Pour qui |
|---|---|---|---|
| **Sidero Metal** | Talos natif | CAPS officiel | st4ck (Talos-aligned, declaratif K8s) |
| Tinkerbell | Tous | CAPT community | Multi-OS, workflows complexes |
| Matchbox | Talos via PXE | Aucun | Lab minimaliste 6 noeuds |

→ Reco st4ck : **Sidero Metal** pour BM layer (Talos-native, GitOps-friendly).
Phase G integre Sidero comme NodeProvider dans Karpenter.

#### Sequencement Phase G

```
G.1 (1 mois) — POC : 2 NodePool Karpenter (Pro2-S VM + EM-A610R BM)
              labels workload-class={short,sustained}, mesure cost
G.2 (1 mois) — Sidero Metal integre comme NodeProvider Karpenter
              tenant clusters Kamaji peuvent burster sur BM
G.3 (decision) — Option A vs B vs C selon retours POC + maturite vCluster
```

**ADR-031** a creer : "Multi-tier autoscaling — Kamaji+Karpenter glue vs vCluster Auto Nodes vs hybride".

### Phase F-bis — Refactor scripts terraform_data bootstrap (~3h, gain ~-7min rebuild)

**Probleme** : les `terraform_data` provisioners de bootstrap utilisent un
pattern "polling slow with safety margin" qui domine le temps de rebuild :

```hcl
for i in $(seq 1 90); do
  CHECK=$(...)
  [ "$CHECK" = "expected" ] && break
  sleep 5
done
```

Cumule sur stacks/{pki,storage,identity}/main.tf, ces loops representent
~7-10 min de sleep accumule par rebuild. Mesure runtime PKI 2026-04-30 :
script openbao_infra_scale_to_ha tourne 4-5min de loop, openbao_app idem,
seed_openbao_secrets ajoute 1-2min.

**Solution** : 3 patterns de fix en cascade :

1. **Polling rapide + early exit** : `sleep 1` au lieu de `sleep 5`,
   verification toutes les 1s, break des qu'OK. Gain ~70% sur loops.

2. **Scale 1→3 supprime, replicas: 3 + retry_join natif Helm** :
   au lieu de scale orchestre par script, deployer Helm avec
   `ha.replicas: 3` + `setNodeId: true` + `retry_join` blocks d'emblee.
   Le chart OpenBao supporte ca nativement. Supprime les
   `terraform_data.openbao_*_scale_to_ha` (Fix #5 + #11) et leurs
   recovery loops fragiles (Fix #32).

3. **Parallelisation des waits** : storage stack a 3 etapes
   sequentielles (garage_wait, garage_layout, garage_buckets_keys)
   chacune avec son propre polling. Fusionner en 1 script qui poll
   plusieurs conditions en parallele.

**Impact estime** :
- PKI : 10min → 2-3min (cible CLAUDE.md atteinte)
- Storage : 5min → 2min
- Identity : 2-3min → 1min
- TOTAL gain : ~-7-10min sur rebuild end-to-end

**Effort** : ~3h
- Refactor stacks/pki/main.tf provisioners (1h, depend Bug #32 fixe d'abord)
- Refactor stacks/storage/main.tf provisioners (1h)
- Refactor stacks/identity/main.tf provisioners (1h)

**ADR-032** a creer : "Polling pattern + helm-native HA pour terraform_data
provisioners — abandon scale orchestre".

**Sequencement** : Phase F-bis APRES Phase D (besoin Bug #32 fixe + cluster
sain pour valider que les nouveaux scripts marchent).

### Phase H — Rebase + merge feat/kamaji-karpenter + deploy KaaS layer (~1h30-2h, apres Phase D)

**Probleme** : la branche `feat/kamaji-karpenter` (92 fichiers, +2469/-105 LOC, 10+ commits)
porte le wiring Flux pour les stacks `capi/`, `kamaji/`, `autoscaling/`, `gateway-api/`,
`managed-cluster/`. MAIS un de ses commits (`6ece223` "vendor Garage + local-path-provisioner
charts") **contradit Fix #4 et Fix #12** (qui movent ces 2 charts de Flux → tofu cni/storage
stacks). Merger sans rebase = regressions Phase D.

**Plan** :
1. Wait Phase D termine + valide 100/100 sur main
2. Rebase `feat/kamaji-karpenter` sur main :
   - Drop le commit `6ece223` (vendor Garage + local-path)
   - Conserver Kamaji + Karpenter wiring + ESO fixes (af9741a, 0db4230, ef71622)
   - Re-tester ESO PushSecret pattern (interagit potentiellement avec Fix #7+#15)
3. Merge `feat/kamaji-karpenter` → main
4. Lancer `make kaas-up` qui apply :
   - `stacks/capi/` (Cluster API + CABPT + Talos infra provider)
   - `stacks/kamaji/` (Hosted Control Planes operator)
   - `stacks/autoscaling/` (Karpenter + provider-cluster-api + KEDA + VPA + prometheus-adapter)
   - `stacks/gateway-api/` (Cilium Gateway + tenant TLSRoute)
5. Valider tenant cluster bootstrap end-to-end (CAPI Cluster CR → Talos CP via Kamaji + workers via Karpenter)

**Effort estime** : ~1h30-2h
- Wait Phase D : ~25min
- Rebase + resolution conflits : 30-60min
- Merge + push : 5min
- `make kaas-up` apply : 10-15min
- Validation tenant cluster : 10min

**Lien avec Phase G** : Phase H deploie l'infra Karpenter + CAPI necessaire pour POC G.1
(2 NodePool VM + BM). Sequencement : H avant G.1.

---

## Decisions architecturales

| Composant | Choix initial | Choix final | Raison |
|---|---|---|---|
| CNI | Flannel | Cilium (ADR-001) | eBPF, kubeProxyReplacement, NetworkPolicy L7, Hubble, mTLS, support Talos |
| Stockage bloc distribue | Rook-Ceph, Piraeus/LINSTOR, Longhorn | Aucun — local-path (ADR-002) | Trop lourd pour 6 noeuds. Garage replique nativement (factor=3) |
| Stockage objet | Longhorn + SeaweedFS + Garage | Garage seul (ADR-003) | Longhorn inutile (~20 pods), SeaweedFS redondant. Garage replique deja |
| GitOps/CD | FluxCD | Woodpecker + OpenTofu (ADR-004) | Flux = chicken-and-egg avec Cilium, 2 systemes de deploiement |
| VM CI runtime | Docker Compose | Podman Quadlet (ADR-005) | systemd natif, daemonless, un seul runtime |
| Flux auth Gitea | HTTPS basic auth | SSH ed25519 (ADR-006) | SSH CA OpenBao pret mais go-git incompatible certs |
| Secrets manager | Vault BSL | OpenBao (ADR-007) | Apache 2.0, Linux Foundation, ESO et step-ca retires |
| Gestion secrets | `secret.tfvars` manuels | `random_id` Terraform (ADR-008) | Zero intervention manuelle, secrets dans state chiffre |
| State backend | Local tfstate | HTTP -> OpenBao KV v2 (ADR-009) | Chiffre Transit, locking, zero dependance cloud |
| Observabilite | Prometheus + Loki + Alloy | vm-k8s-stack + VictoriaLogs (ADR-010) | Chart consolide, collecteurs natifs VM |
| Trivy node-collector | Active | Desactive (ADR-011) | Incompatible Talos (no shell, no systemd). Talos durci par design |
| Garage post-deploy | local-exec script | K8s Job (ADR-012) | In-cluster, idempotent, RBAC least-privilege |
| Service mesh | Kuma | Differe (ADR-013) | Cilium mTLS + L7 couvre le besoin actuel |
| IDP | Backstage | Differe (ADR-014) | Headlamp + Pomerium suffisent, Backstage Gate 3+ |
| Tunnels chiffres | WireGuard IPv6 | Differe (ADR-015) | Pertinent multi-site Gate 3 |
| DLP egress | Envoy ext_proc | Differe (ADR-016) | Pertinent quand IA deployee Gate 2+ |
| PaaS self-service | — | Cozystack (ADR-017) | Planifie Gate 3, Phase 3.5 |
| Runtime security | Falco | Tetragon (ADR-018) | eBPF natif Cilium, un seul plan eBPF, enforcement temps reel, fix Talos tracefs simple |
| Provisioning bare metal | Scripts manuels | Matchbox (ADR-019) | PXE zero-touch, scale >10 noeuds, VM degradees sans API vSphere |
| KaaS multi-tenant | — | Kamaji (ADR-020) | Control planes mutualises, overhead ~0, alternative legere a Cozystack |
| Identity/SSO | Keycloak | Ory Stack (Kratos+Hydra+Pomerium) | Plus leger, cloud-native, modulaire |
| Policy engine | Pod Security Standards | Kyverno | Plus flexible, CRD-based, admission + mutation |

## Risques et mitigations

| Risque | Impact | Mitigation |
|---|---|---|
| Acces vSphere API refuse | Bloquant Gate 1 | Valider avec Morpheus/client en amont |
| GPU non disponible a temps | Retarde Gate 3 IA | IA CPU (Gate 2) couvre les besoins de base |
| Images conteneurs manquantes air-gap | Bloquant | Harbor mirror + audit exhaustif pre-transfer |
| Besoin stockage bloc distribue futur | Performance | Rook-Ceph ou LINSTOR en fallback si besoin |
| AGPL Grafana/Loki en contexte defense | Juridique | Souscrire Grafana Enterprise (~25K/an) |

---

## Automatisation deploiement

```
make k8s-up (~15 minutes end-to-end, sequentiel strict)
│
├── 1. k8s-cni-apply        (~30s)  — Cilium CNI
├── 2. k8s-pki-apply        (~1 min) — PKI + OpenBao x2 + cert-manager
├── 3. k8s-monitoring-apply (~2 min) — vm-k8s-stack + VictoriaLogs + Headlamp
├── 4. k8s-identity-apply   (~1 min) — Kratos + Hydra + Pomerium
│       └── Secrets auto-generes via random_id (zero tfvars)
├── 5. k8s-security-apply   (~2 min) — Trivy + Tetragon + Kyverno + Cosign
├── 6. k8s-storage-apply    (~2 min) — local-path + Garage + Velero + Harbor
└── 7. flux-bootstrap-apply (~30s)   — Flux SSH + GitRepository

Post-deploy (optionnel) :
├── make scaleway-oidc       — Configure apiServer OIDC (Hydra, talosctl patch)
├── make velero-test         — Valide backup/restore end-to-end
├── make scaleway-harbor     — Ouvre Harbor UI (password dans clipboard)
└── make scaleway-grafana    — Ouvre Grafana UI
```

Note : le pipeline etait initialement parallele (make -j2 pour pki+monitoring et
security+storage) mais les race conditions (VMSingle PVC Pending sans StorageClass,
Kyverno webhooks bloquant des pods en cours de creation) rendaient le deploy fragile.
Le mode sequentiel ajoute ~3 minutes mais garantit un deploy fiable a chaque run.

*Document de reference — Mis a jour 2026-03-11 — Gate 1 : 10/12 criteres valides*
