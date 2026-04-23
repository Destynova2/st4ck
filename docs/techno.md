# Stack Technologique — Plateforme Souveraine

> Inventaire complet des composants deployes, versions, et roles.
> Mis a jour 2026-03-11.

---

## Infrastructure

| Composant | Version | Role | Notes |
|---|---|---|---|
| Talos Linux | v1.12.6 | OS immutable Kubernetes | Pas de SSH, pas de shell, pas de systemd |
| Kubernetes | 1.35.4 | Orchestrateur conteneurs | 3 control planes + 3 workers |
| Cilium | 1.17.13 | CNI + Network Policies + Service Mesh | eBPF, remplace kube-proxy, mTLS, Hubble |
| CoreDNS | (integre K8s) | DNS cluster | Forwarding vers DNS externe |

## CI/CD & Registry

| Composant | Version | Role | Notes |
|---|---|---|---|
| Woodpecker CI | v3 | Pipeline CI/CD push-based | 13 stages sequentiels (validate -> image -> bootstrap -> cluster -> wait-api -> stacks) |
| Gitea | 1.x | Serveur Git | VM CI Scaleway, Podman Quadlet + systemd |
| Harbor | 1.16.2 | Registry conteneurs | S3 Garage backend, Trivy scan integre |

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

## Observabilite (stack k8s-monitoring)

| Composant | Chart Version | Role | Notes |
|---|---|---|---|
| victoria-metrics-k8s-stack | 0.72.4 | Metriques + alertes + dashboards (chart consolide) | VMSingle, VMAgent, VMAlert, Alertmanager, Grafana, kube-state-metrics, node-exporter |
| victoria-logs-single | 0.11.28 | Stockage logs (remplace Loki) | Retention 30d |
| victoria-logs-collector | 0.2.11 | Collecte logs (DaemonSet) | Remplace Alloy |
| Headlamp | 0.40.0 | UI Kubernetes | kubernetes-sigs, healthmap cluster |

## PKI & Secrets (stack k8s-pki)

| Composant | Chart Version | Role | Notes |
|---|---|---|---|
| OpenBao (infra) | 0.25.6 | PKI intermediaire, secrets infra, Transit engine, SSH CA | Agent Injector active |
| OpenBao (app) | 0.25.6 | Secrets applicatifs | Instance separee |
| cert-manager | v1.19.4 | Gestion certificats TLS | ClusterIssuer internal-ca |

### OpenBao Infra — Engines & Auth

```
Secret Engines :
├── transit/              — Chiffrement state OpenTofu (cle aes256-gcm96 "state-encryption")
├── ssh-client-signer/    — SSH CA pour signature certs (role "flux", TTL 2h, max 24h)
└── cubbyhole/            — Per-token storage

Auth Methods :
├── kubernetes/           — Auth pods via ServiceAccount
│   └── role "flux-ssh"   — bound SA flux2-source-controller/flux-system, policy "flux-ssh"
└── token/                — Auth par token

Policies :
├── flux-ssh              — create/update sur ssh-client-signer/sign/flux
└── default/root
```

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
- Stockes dans state Terraform (chiffre via Transit OpenBao), jamais en clair sur disque

### State Backend

```
OpenBao KMS local (3 noeuds Raft, Podman)
└── vault-backend (HTTP proxy → OpenBao KV v2)
    └── http://localhost:8080/state/{stack-name}
        └── TF_HTTP_PASSWORD = token vault-backend
```

## Identite (stack k8s-identity)

| Composant | Chart Version | Role | Notes |
|---|---|---|---|
| Kratos | 0.60.1 | Gestion identite | Ory Stack |
| Hydra | 0.60.1 | Serveur OIDC/OAuth2 | TLS public, client K8s auto-enregistre |
| Pomerium | 34.0.1 | Proxy authentifiant zero-trust | SSO tous composants |

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

### Garage Post-Deploy (K8s Job)

```
kubernetes_job_v1.garage_setup :
├── Wait Garage admin API
├── Configure layout (5 GB/node, zone dc1)
├── Create buckets (velero-backups, harbor-registry)
├── Create API keys (velero-key, harbor-key)
└── Create K8s secrets (velero-s3-credentials, harbor-s3-credentials)
    └── RBAC: ServiceAccount garage-setup, Role/RoleBinding storage ns
```

## GitOps (stack flux-bootstrap)

| Composant | Chart Version | Role | Notes |
|---|---|---|---|
| Flux v2 | 2.14.1 | GitOps controller | source, kustomize, helm, image, notification controllers |

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
├── cni/            # Cilium (1 helm release + values + flux/)
├── monitoring/     # vm-k8s-stack, VictoriaLogs, Headlamp (4 helm releases + dashboard + flux/)
├── pki/            # PKI, OpenBao x2, cert-manager (4 helm releases + secrets + ClusterIssuer + flux/)
├── identity/       # Kratos, Hydra, Pomerium (3 helm releases + OIDC client + flux/)
├── security/       # Trivy, Tetragon, Kyverno (3 helm releases + policy + flux/)
├── storage/        # local-path, Garage, Velero, Harbor (4 helm releases + K8s Job setup + flux/)
├── flux-bootstrap/ # Flux v2, SSH key, GitRepository, Kustomization
└── external-secrets/ # ESO + ClusterSecretStore (flux only)

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

*Total : ~27 composants Helm, 7 stacks Terraform, 2 environnements cloud + 1 air-gap, 1 VM CI Podman Quadlet*
