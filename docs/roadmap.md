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
   ├── Kubernetes v1.35.0
   └── Cilium CNI 1.17 + Hubble
       ├── eBPF (remplace kube-proxy)
       ├── Network Policies L3/L4/L7
       └── mTLS inter-workloads

3. CoreDNS
   └── Forwarding vers AD interne
```

**Livrable** : cluster 6 noeuds fonctionnel, reseau securise, DNS operationnel.

- [x] Talos v1.12.4 + Kubernetes v1.35.0 (Scaleway)
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

**Decision** : FluxCD et SeaweedFS retires. Voir ADR-002 et ADR-003.
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

**Decision** : Secrets auto-generes via `random_id` Terraform. Voir ADR-005.
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
10. VictoriaMetrics
    └── Stockage metriques (PromQL)

11. Loki
    └── Agregation logs (single-binary)

12. Alertmanager
    └── Routage alertes

13. Alloy (DaemonSet)
    ├── Scrape metriques → VictoriaMetrics
    │   ├── kubelet / cadvisor
    │   ├── Cilium agent (port 9962)
    │   ├── Hubble (port 9965)
    │   └── Cilium operator (port 9963)
    └── Collecte logs → Loki

14. Grafana
    ├── Datasources: VictoriaMetrics, Loki, Alertmanager
    ├── Dashboards: Hubble (natifs Cilium), K8s Global/Nodes/Pods
    └── Platform Overview dashboard (C-level, auto-refresh 30s)

15. Headlamp
    ├── UI Kubernetes (kubernetes-sigs)
    ├── S'ouvre automatiquement apres deploy addons (token auto-copie)
    └── Permet de suivre le deploiement des stacks restants en live
```

**Livrable** : observabilite complete (metriques, logs, alertes, dashboards, UI live).

- [x] VictoriaMetrics 0.32.0
- [x] Loki 6.53.0
- [x] Alertmanager 1.33.1
- [x] Alloy 1.6.1
- [x] Grafana 10.5.15 + Platform Overview dashboard
- [x] Headlamp 0.40.0 (auto-open dans `make scaleway-up`)

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

- [x] Trivy Operator 0.32.0 (node-collector desactive — ADR-004 : `scanNodeCollectorLimit: 0`)
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

**Decision** : Garage seul (sans Longhorn) retenu. Voir ADR-001.
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

- [ ] CAPI + CAPT + CAPS (demo Scaleway)
- [ ] CAPI + CAPT + CAPV (production vSphere — requiert acces API)

### Gate 1 — Criteres de passage

- [x] Management cluster 6 noeuds Talos stable (3 CP + 3 workers)
- [x] Pipeline CI/CD complet (Woodpecker + OpenTofu, 7 stages)
- [x] Harbor registry (S3 Garage backend, Trivy scan integre)
- [x] Observabilite complete (metriques + logs + alertes)
- [x] Secrets & PKI (OpenBao infra/app + cert-manager + Root/Intermediate CA)
- [x] Securite runtime (Trivy + Tetragon + Kyverno + Cosign policy)
- [x] Stockage S3 + backup (Garage + Velero, BSL Available)
- [x] OIDC K8s fonctionnel (Hydra TLS + client auto-enregistre + patch talosctl)
- [x] Cosign (Kyverno verifyImages ClusterPolicy, mode audit)
- [x] Velero backup/restore teste (`make velero-test` — backup + restore namespace)
- [ ] 1 workload cluster cree/detruit via CAPI (demo Scaleway, puis vSphere en prod)
- [ ] Conformite ANSSI Guide K8s 2024 validee

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
- [ ] Conformite complete IGI 1300 / SecNumCloud 3.2

---

## Graphe de dependances global

```
Phase 1.1 Bootstrap (Talos + Cilium + CoreDNS)                    [DONE]
    │
Phase 1.2 CI/CD & Registry (Gitea + Woodpecker + Harbor)          [DONE]
    │
    ├── Phase 1.3 Secrets & Identite (OpenBao x2 + PKI + Ory)     [DONE]
    │       │
    │       Phase 1.4 Observabilite (VM + Loki + Alloy + Grafana)  [DONE]
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

## Decisions architecturales

| Composant | Choix initial | Choix final | Raison |
|---|---|---|---|
| Stockage distribue | Rook-Ceph → Piraeus/LINSTOR → Longhorn | Garage seul (ADR-001) | Longhorn inutile : Garage replique nativement (factor=3), ~20 pods et ~1.5 GB RAM economises |
| Runtime security | Falco | Tetragon | eBPF natif Cilium, mieux integre, fix Talos tracefs simple |
| Identity/SSO | Keycloak | Ory Stack (Kratos+Hydra+Pomerium) | Plus leger, cloud-native, modulaire |
| Policy engine | Pod Security Standards | Kyverno | Plus flexible, CRD-based, admission + mutation |
| GitOps/CD | FluxCD | Woodpecker + OpenTofu (ADR-002) | Flux = chicken-and-egg avec Cilium, 2 systemes de deploiement. Woodpecker + tofu couvre le CD |
| Object store S3 | SeaweedFS | Garage (ADR-003) | Garage deja deploye (phase 1.6), pas besoin de 2 object stores |
| Trivy node-collector | Active (CIS benchmark nodes) | Desactive (ADR-004) | Incompatible Talos : filesystem read-only, pas de systemd/shell. Fix final : `operator.scanNodeCollectorLimit: 0` + `compliance.specs: []` (seul moyen effectif dans chart v0.32). Talos est durci par design (plus strict que CIS). Trivy continue scan images, configs K8s, RBAC, SBOM |
| Gestion secrets | `secret.tfvars` manuels | `random_id` Terraform (ADR-005) | Zero intervention manuelle. Chaque deploy genere des secrets uniques via `random_id`. `.hex` pour tokens, `.b64_std` pour Pomerium (strict 32 bytes). Injectes via `templatefile()`, stockes dans state Terraform |

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
make scaleway-up (~12 minutes end-to-end)
│
├── 1. scaleway-apply      (~5 min) — Cluster Talos 3CP + 3W
├── 2. wait-api             (~1 min) — Attente Kubernetes API ready
├── 3. k8s-addons-apply     (~2 min) — Cilium, monitoring, Headlamp
│       └── Headlamp s'ouvre automatiquement (token copie dans clipboard)
│           └── L'utilisateur peut suivre les stacks restants en live
├── 4. k8s-secrets-apply    (~1 min) — PKI + OpenBao x2 + Ory + cert-manager
│       └── Secrets auto-generes via random_id (zero tfvars)
├── 5. k8s-security-apply   (~2 min) — Trivy + Tetragon + Kyverno + Cosign policy
└── 6. k8s-storage-apply    (~2 min) — local-path + Garage + Velero + Harbor
        └── Secrets Garage + Harbor auto-generes via random_id

Post-deploy (optionnel) :
├── make scaleway-oidc       — Configure apiServer OIDC (Hydra, talosctl patch)
├── make velero-test         — Valide backup/restore end-to-end
├── make scaleway-harbor     — Ouvre Harbor UI (password dans clipboard)
└── make scaleway-grafana    — Ouvre Grafana UI
```

*Document de reference — Mis a jour 2026-03-09 — Gate 1 : 10/12 criteres valides*
