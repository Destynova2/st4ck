# Stack Technologique — Plateforme Souveraine

> Inventaire complet des composants deployes, versions, et roles.
> Mis a jour 2026-03-10.

---

## Infrastructure

| Composant | Version | Role | Notes |
|---|---|---|---|
| Talos Linux | v1.12.4 | OS immutable Kubernetes | Pas de SSH, pas de shell, pas de systemd |
| Kubernetes | 1.35.0 | Orchestrateur conteneurs | 3 control planes + 3 workers |
| Cilium | 1.17.13 | CNI + Network Policies + Service Mesh | eBPF, remplace kube-proxy, mTLS, Hubble |
| CoreDNS | (integre K8s) | DNS cluster | Forwarding vers DNS externe |

## CI/CD & Registry

| Composant | Version | Role | Notes |
|---|---|---|---|
| Woodpecker CI | - | Pipeline CI/CD push-based | 7 stages sequentiels (validate → storage) |
| Gitea | - | Serveur Git | Deploye sur VM CI avec Woodpecker |
| Harbor | 1.16.2 | Registry conteneurs | S3 Garage backend, Trivy scan integre |

## Observabilite (stack k8s-addons)

| Composant | Chart Version | Role | Notes |
|---|---|---|---|
| VictoriaMetrics | 0.32.0 | Stockage metriques (PromQL) | Single-node, scrape via Alloy |
| Loki | 6.53.0 | Agregation logs | Single-binary, filesystem, gateway nginx |
| Alertmanager | 1.33.1 | Routage alertes | Prometheus-community chart |
| Grafana | 10.5.15 | Dashboards & visualisation | Datasources auto-configurees (uid stables) |
| Alloy | 1.6.1 | Collecteur unifie metriques + logs | DaemonSet, 9 cibles scrape, logs file-based |
| kube-state-metrics | 5.30.1 | Metriques Kubernetes (kube_*) | Pod counts, deployments, resource requests |
| node-exporter | 4.52.0 | Metriques host (node_*) | DaemonSet, hostNetwork+hostPID, compatible Talos |
| Headlamp | 0.40.0 | UI Kubernetes | kubernetes-sigs, auto-open au deploy |

### Alloy — Detail pipeline

```
Metriques (9 cibles scrape) :
├── Pods annotes (prometheus.io/scrape=true)
├── kubelet (API proxy /nodes/$node/proxy/metrics)
├── cadvisor (API proxy /nodes/$node/proxy/metrics/cadvisor)
├── node-exporter (endpoints discovery)
├── kube-state-metrics (service discovery)
├── Cilium agent (port 9962)
├── Hubble (port 9965)
├── Cilium operator (port 9963)
└── Hubble relay (port 9966)

Relabeling :
├── cluster=talos (global, via prometheus.relabel avant remote_write)
└── instance=node name (node-exporter, kubelet, cadvisor)

Logs :
├── local.file_match /var/log/pods/*/*/*.log (hostPath /var/log)
├── loki.process : regex extraction namespace/pod/container/stream
├── CRI format parsing (timestamp stream flags content)
└── Static labels : cluster=talos, job=pod-logs
```

### Grafana — Dashboards

| Dashboard | Source | Folder | Datasource |
|---|---|---|---|
| K8s Global | grafana.com #15757 | Kubernetes | Prometheus |
| K8s Nodes | grafana.com #15759 | Kubernetes | Prometheus |
| K8s Pods | grafana.com #15760 | Kubernetes | Prometheus |
| Loki Logs | grafana.com #13639 | Logs | Loki |
| Container Log | grafana.com #16966 | Logs | Loki |
| Node Exporter Full | grafana.com #1860 | System | Prometheus |
| cAdvisor | grafana.com #14282 | System | Prometheus |
| K8s Resources Cluster | grafana.com #7249 | System | Prometheus |
| Platform Overview | ConfigMap (custom) | default | Prometheus |
| Hubble / Cilium | Chart Cilium (natifs) | - | Prometheus |

### Grafana — Datasources

| Nom | Type | UID | URL interne |
|---|---|---|---|
| Prometheus | prometheus | `prometheus` | victoria-metrics-single-server.monitoring:8428 |
| Loki | loki | `loki` | loki.monitoring:3100 |
| Alertmanager | alertmanager | `alertmanager` | alertmanager.monitoring:9093 |

## Secrets & Identite (stack k8s-secrets)

| Composant | Chart Version | Role | Notes |
|---|---|---|---|
| OpenBao (infra) | 0.25.6 | PKI intermediaire, secrets infra | Instance separee |
| OpenBao (app) | 0.25.6 | Secrets applicatifs | Instance separee |
| cert-manager | v1.19.4 | Gestion certificats TLS | ClusterIssuer internal-ca |
| Kratos | 0.60.1 | Gestion identite | Ory Stack |
| Hydra | 0.60.1 | Serveur OIDC/OAuth2 | TLS public, client K8s auto-enregistre |
| Pomerium | 34.0.1 | Proxy authentifiant zero-trust | SSO tous composants |

### PKI

```
Root CA (Terraform TLS provider, auto-genere)
└── Intermediate CA (signe par Root, injecte dans cert-manager)
    └── ClusterIssuer "internal-ca"
        └── Certificats workloads (Hydra TLS, etc.)
```

### Secrets

Tous auto-generes via `random_id` Terraform :
- `.hex` (64 chars) : tokens OpenBao, admin passwords
- `.b64_std` (base64, 32 bytes) : Pomerium shared/cookie secrets
- Stockes dans state Terraform (chiffre), jamais en clair sur disque

## Securite (stack k8s-security)

| Composant | Chart Version | Role | Notes |
|---|---|---|---|
| Trivy Operator | 0.32.0 | Scan vulnerabilites images + SBOM | Mode Standalone, node-collector desactive (Talos) |
| Tetragon | 1.6.0 | Detection menaces runtime (eBPF) | Requiert hostMount /sys/kernel/tracing (Talos) |
| Kyverno | 3.7.1 | Policy engine admission/mutation | failurePolicy: Ignore, verifyImages Cosign |

### Policies Kyverno

- Cosign verifyImages ClusterPolicy (mode audit, pret pour enforce)
- Pod Security Standards (baseline/restricted)

## Stockage & Backup (stack k8s-storage)

| Composant | Chart Version | Role | Notes |
|---|---|---|---|
| local-path-provisioner | 0.0.35 | StorageClass par defaut | PVCs sur disque local |
| Garage | v2.2.0 (app) | Stockage objet S3 | 3 pods StatefulSet, replication factor 3, ~300 MB RAM |
| Velero | 11.4.0 | Backup/restore | Target: Garage S3, BSL Available |
| Harbor | 1.16.2 | Registry conteneurs | S3 Garage backend, Trivy scan integre |

## RBAC supplementaire (Terraform)

| ClusterRole | Permissions | ServiceAccount | Raison |
|---|---|---|---|
| alloy-kubelet-access | nodes/proxy, nodes/metrics (get) | alloy (monitoring) | Scrape kubelet/cadvisor via API proxy |
| alloy-kubelet-access | nodes, pods, services, endpoints (get/list/watch) | alloy (monitoring) | Discovery Kubernetes |
| alloy-kubelet-access | pods/log (get/list/watch) | alloy (monitoring) | Collecte logs via API |

## Deploiement Terraform

```
terraform/stacks/
├── k8s-addons/     # Cilium, monitoring, observabilite (9 helm releases + RBAC)
├── k8s-secrets/    # PKI, OpenBao x2, cert-manager, Ory Stack (8 helm releases)
├── k8s-security/   # Trivy, Tetragon, Kyverno (3 helm releases + policy)
└── k8s-storage/    # local-path, Garage, Velero, Harbor (4 helm releases + setup)
```

## Environnements

| Env | Provider | Statut | Notes |
|---|---|---|---|
| Scaleway (fr-par) | scaleway | Actif (demo/dev) | 3 CP (DEV1-S) + 3 W (DEV1-M), LB API |
| Local (libvirt) | libvirt/QEMU | Disponible | Dev local KVM |
| Outscale (FCU) | outscale | Disponible | Cloud souverain FR |
| VMware air-gap | Scripts (pas Terraform) | Preparation | OVA + image cache + static IPs |

---

*Total : ~26 composants Helm, 4 stacks Terraform, 3 environnements cloud + 1 air-gap*
