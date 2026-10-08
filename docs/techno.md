# Stack Technologique — Plateforme Souveraine

> Inventaire complet des composants deployes, versions, et roles.
> Mis a jour 2026-03-11.

---

## Infrastructure

| Composant | Version | Role | Notes |
|---|---|---|---|
| Talos Linux | v1.12.9 | OS immutable Kubernetes | Pas de SSH, pas de shell, pas de systemd |
| Kubernetes | 1.35.6 | Orchestrateur conteneurs | 3 control planes + 3 workers |
| Cilium | 1.17.13 | CNI + Network Policies + Service Mesh | eBPF, remplace kube-proxy, mTLS, Hubble |
| CoreDNS | (integre K8s) | DNS cluster | Forwarding vers DNS externe |

## CI/CD & Registry

| Composant | Version | Role | Notes |
|---|---|---|---|
| Woodpecker CI | v3 | Pipeline CI/CD push-based | 13 stages sequentiels (validate -> image -> bootstrap -> cluster -> wait-api -> stacks) |
| Gitea | 1.x | Serveur Git | VM CI Scaleway, Podman Quadlet + systemd |
| zot | chart 0.1.122 (app v2.1.18) | Registry OCI | CNCF, arm64, S3 Garage backend, Trivy integre, cosign/notation (ADR-039) |

### VM CI (Scaleway DEV1-M)

```
/etc/containers/systemd/ci.kube  →  Quadlet unit
    └── /opt/woodpecker/ci-pod.yaml  →  Pod manifest (podman play kube)
        ├── gitea        :3000 (UI) :2222 (SSH)
        ├── woodpecker-server  :8000 (UI) :9000 (gRPC)
        └── woodpecker-agent   (monte /run/podman/podman.sock)

systemctl enable --now ci
systemctl status ci
journalctl -u ci
```

Cloud-init : installe podman, clone le repo, cree admin Gitea, OAuth Woodpecker, push mirror, injecte secrets Scaleway.

## CNI (stack k8s-cni)

| Composant | Chart Version | Role | Notes |
|---|---|---|---|
| Cilium | 1.17.13 | CNI + Network Policies + Service Mesh | eBPF, remplace kube-proxy, mTLS, Hubble |
| local-path-provisioner | 0.0.37 | StorageClass par defaut | Chart containeroo, namespace local-path-storage |

## Observabilite (stack k8s-monitoring)

| Composant | Chart Version | Role | Notes |
|---|---|---|---|
| victoria-metrics-k8s-stack | 0.86.0 | Metriques + alertes + dashboards (chart consolide) | VMSingle, VMAgent, VMAlert, Alertmanager, Grafana, kube-state-metrics, node-exporter |
| victoria-logs-single | 0.13.8 | Stockage logs (remplace Loki) | Retention 30d |
| victoria-logs-collector | 0.3.6 | Collecte logs (DaemonSet) | Remplace Alloy |
| Headlamp | 0.43.0 | UI Kubernetes | kubernetes-sigs, healthmap cluster |

## PKI & Secrets (stack k8s-pki)

| Composant | Chart Version | Role | Notes |
|---|---|---|---|
| OpenBao KMS bootstrap | 2.5.1 | State backend + racine PKI | Podman hors cluster, single-node Raft |
| OpenBao (infra) | 0.28.4 | PKI intermediaire, secrets infra, source ESO, SSH CA | In-cluster, Helm, HA Raft apres bootstrap |
| OpenBao (app) | 0.28.4 | Frontiere secrets applicatifs | In-cluster, reserve tant qu'aucun ClusterSecretStore app n'est cable |
| cert-manager | v1.21.0 | Gestion certificats TLS | ClusterIssuer internal-ca |

### OpenBao KMS / Infra / App — roles

```
Bootstrap KMS (Podman) :
├── secret/               — KV v2 pour tfstate via vault-backend
├── PKI root/sub-CAs      — exportees dans kms-output/
└── AppRole               — auth vault-backend

OpenBao Infra (cluster) :
├── secret/               — KV v2 source ESO (identity, storage, security, monitoring)
├── pki_int/              — backend PKI pour cert-manager
├── transit/              — chiffrement et primitives infra
├── ssh-client-signer/    — SSH CA pour signature certs (role "flux", TTL 2h, max 24h)
└── auth/kubernetes       — auth ESO/cert-manager/pods via ServiceAccount

OpenBao App (cluster) :
└── secret/               — reserve aux secrets applicatifs, futur ClusterSecretStore openbao-app
```

### PKI

```
Root CA (Terraform TLS provider, auto-genere)
└── Intermediate CA (signe par Root, injecte dans cert-manager)
    └── ClusterIssuer "internal-ca"
        └── Certificats workloads (Hydra TLS, etc.)
```

### Secrets

Tous auto-generes via Terraform :
- `random_password` : mots de passe et client secrets
- `random_bytes` : secrets binaires stricts (Pomerium, Garage RPC, seal keys)
- `tls_private_key` : cles CA, Flux SSH, Cosign
- Stockes dans le state chiffre via OpenBao KMS, puis seedes dans OpenBao Infra pour ESO

### State Backend

```
OpenBao KMS bootstrap (single-node Raft, Podman)
└── vault-backend (HTTP proxy → OpenBao KV v2)
    └── http://localhost:8080/state/{stack-name}
        └── TF_HTTP_PASSWORD = token vault-backend
```

## Identite (stack k8s-identity)

| Composant | Chart Version | Role | Notes |
|---|---|---|---|
| Kratos | 0.62.1 | Gestion identite | Ory Stack |
| Hydra | 0.62.1 | Serveur OIDC/OAuth2 | TLS public, client K8s auto-enregistre |
| Pomerium | 34.0.1 | Proxy authentifiant zero-trust | SSO tous composants |

## Securite (stack k8s-security)

| Composant | Chart Version | Role | Notes |
|---|---|---|---|
| Trivy Operator | 0.34.0 | Scan vulnerabilites images + SBOM | Mode Standalone, node-collector desactive (Talos) |
| Tetragon | 1.7.0 | Detection menaces runtime (eBPF) | Requiert hostMount /sys/kernel/tracing (Talos) |
| Kyverno | 3.8.2 | Policy engine admission/mutation | failurePolicy: Ignore, verifyImages Cosign |

### Policies Kyverno

- Cosign verifyImages ClusterPolicy (mode audit, pret pour enforce)
- Pod Security Standards (baseline/restricted)

## Stockage & Backup (stack k8s-storage)

| Composant | Chart Version | Role | Notes |
|---|---|---|---|
| Garage | v2.3.0 (app) | Stockage objet S3 | 3 pods StatefulSet, replication factor 3, ~300 MB RAM |
| Velero | 11.4.0 | Backup/restore | Target: Garage S3, BSL Available |
| zot | chart 0.1.122 (app v2.1.18) | Registry OCI | CNCF, arm64, S3 Garage backend, Trivy integre, cosign/notation (ADR-039) |

### Garage Post-Deploy (K8s Job)

```
kubernetes_job_v1.garage_setup :
├── Wait Garage admin API
├── Configure layout (5 GB/node, zone dc1)
├── Create buckets (velero-backups, zot-registry)
├── Create API keys (velero-key, zot-key)
└── Create K8s secrets (velero-s3-credentials, zot-s3-credentials)
    └── RBAC: ServiceAccount garage-setup, Role/RoleBinding storage ns
```

## GitOps (stack flux-bootstrap)

| Composant | Chart Version | Role | Notes |
|---|---|---|---|
| Flux v2 | 2.18.4 | GitOps controller | source, kustomize, helm, image, notification controllers |

### Flux → Gitea (SSH)

```
tls_private_key.flux_ssh (ed25519)
└── K8s secret "flux-ssh-identity" (identity + identity.pub + known_hosts)
    └── GitRepository "management" (ssh://git@gitea.ci.internal:22/infra/talos.git)
        └── Kustomization "management" (path: ./clusters/management)

Deploy key : tofu output flux_ssh_public_key → Gitea Settings → Deploy Keys
```

## Deploiement Terraform

```
stacks/
├── cni/            # Cilium + local-path (2 helm releases + values + flux/)
├── monitoring/     # vm-k8s-stack, VictoriaLogs, Headlamp (4 helm releases + dashboard + flux/)
├── pki/            # PKI, OpenBao x2, cert-manager (4 helm releases + secrets + ClusterIssuer + flux/)
├── identity/       # Kratos, Hydra, Pomerium (3 helm releases + OIDC client + flux/)
├── security/       # Trivy, Tetragon, Kyverno, Kubescape node-agent (flux/)
├── storage/        # Garage, Velero, zot (flux/ + flux-zot*/)
├── flux-bootstrap/ # Flux v2, SSH key, GitRepository, Kustomization
└── external-secrets/ # ESO + ClusterSecretStore (chart ESO tofu-owned dans stacks/pki (ADR-033) ; le dossier external-secrets ne porte que le ClusterSecretStore)

envs/scaleway/
├── iam/            # Projet, API keys (image-builder, cluster, ci), buckets
├── ci/             # VM CI (Gitea + Woodpecker, Podman Quadlet)
└── main.tf         # Cluster Talos (6 noeuds, LB, VPC)
```

## Environnements

| Env | Provider | Statut | Notes |
|---|---|---|---|
| Scaleway (fr-par) | scaleway | Actif (demo/dev) | 3 CP (DEV1-S) + 3 W (DEV1-M), LB API |
| Local (libvirt) | libvirt/QEMU | Disponible | Dev local KVM |
| VMware air-gap | Scripts (pas Terraform) | Preparation | OVA + image cache + static IPs |

---

*Total : ~27 composants Helm, 13 stacks Terraform (8 core + 5 KaaS Phase A), 2 environnements cloud + 1 air-gap, 1 VM CI Podman Quadlet*
