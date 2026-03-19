# Architecture

## Vue d'ensemble

La plateforme suit un **modele de deploiement en deux phases** :

1. **Phase 1 — OpenTofu** : Bootstrap l'infrastructure et toutes les stacks K8s en ordre strict de dependances. C'est le chemin "day-1" qui part d'un environnement vierge vers une plateforme operationnelle.

2. **Phase 2 — Flux v2** : Prend le relais pour la reconciliation day-2 via GitOps. HelmReleases et Kustomize overlays assurent la detection de drift et le self-healing.

```mermaid
graph LR
    D1[Day 1<br/>OpenTofu] -->|deploie 7 stacks| K8S[Cluster K8s]
    K8S --> FLUX[Flux v2]
    FLUX -->|reconciliation| K8S
    GIT[Gitea] -->|webhook| FLUX

    style D1 fill:#4a9,stroke:#333,color:#fff
    style FLUX fill:#36f,stroke:#333,color:#fff
```

## Pipeline de deploiement

```mermaid
graph TB
    subgraph "Phase 0 — Local"
        KMS[kms-bootstrap<br/>OpenBao Podman]
    end

    subgraph "Phase 1 — Infrastructure"
        IAM[scaleway-iam] --> IMG[scaleway-image]
        IAM --> CI_VM[scaleway-ci<br/>Gitea + Woodpecker]
        IMG --> CLUSTER[scaleway-apply<br/>6 noeuds Talos]
    end

    subgraph "Phase 2 — Stacks K8s (sequentiel)"
        CNI[1. k8s-cni<br/>Cilium ~30s]
        PKI[2. k8s-pki<br/>OpenBao + cert-manager ~1min]
        MON[3. k8s-monitoring<br/>VictoriaMetrics ~2min]
        IDN[4. k8s-identity<br/>Kratos + Hydra ~1min]
        SEC[5. k8s-security<br/>Trivy + Tetragon + Kyverno ~2min]
        STO[6. k8s-storage<br/>Garage + Velero + Harbor ~2min]
        FLUXB[7. flux-bootstrap<br/>Flux SSH ~30s]

        CNI --> PKI --> MON --> IDN --> SEC --> STO --> FLUXB
    end

    KMS -.->|state backend + CAs| CNI
    CLUSTER --> CNI
```

### Pourquoi cet ordre ?

- **Cilium en premier** : c'est le CNI. Sans lui, aucun pod ne peut etre schedule.
- **PKI avant monitoring** : cert-manager doit etre pret pour les certificats TLS.
- **Identity apres PKI** : Hydra a besoin de certificats TLS signes par cert-manager.
- **Security avant storage** : Kyverno doit etre pret avant de deployer les workloads stateful.
- **Storage apres security** : evite les race conditions (Kyverno webhooks bloquant des pods).
- **Flux en dernier** : il a besoin de toutes les stacks presentes pour les reconcilier.

> **Note** : le pipeline etait initialement parallele (`make -j2`) pour pki+monitoring
> et security+storage, mais les race conditions (VMSingle PVC Pending, Kyverno webhooks)
> ont impose le mode sequentiel. +3 min mais 100% fiable.

## Stockage du state

```mermaid
graph LR
    TF[OpenTofu] -->|HTTP backend| VB[vault-backend<br/>:8080]
    VB -->|KV v2| BAO[OpenBao<br/>:8200]
    VB -->|Transit| BAO

    subgraph "Paths KV v2"
        S1[state/k8s-cni]
        S2[state/k8s-pki]
        S3[state/k8s-monitoring]
        S4[state/...]
    end

    BAO --> S1
    BAO --> S2
    BAO --> S3
    BAO --> S4
```

- **Authentification** : `TF_HTTP_PASSWORD` (token depuis kms-output/)
- **Chiffrement** : Transit engine (aes256-gcm96) + Raft at-rest
- **Locking** : vault-backend cree des cles `-lock` dans KV v2
- **Backup** : `make state-snapshot` cree un snapshot Raft

## Gestion des secrets

Les secrets ne passent jamais par Git.

```mermaid
graph LR
    TF[OpenTofu<br/>random_id] -->|genere| SEC[Secrets]
    SEC -->|stockes dans| STATE[State chiffre<br/>OpenBao KV v2]
    SEC -->|injectes via| TPL[templatefile]
    TPL --> HELM[Helm values]
    HELM --> K8S[K8s Secrets]

    style SEC fill:#f90,stroke:#333,color:#fff
```

- `random_id.*.hex` (64 chars) : tokens, passwords, RPC secrets
- `random_id.*.b64_std` (base64) : Pomerium shared/cookie secrets (strict 32 bytes)
- Jamais en clair sur disque — uniquement dans le state Terraform chiffre

## Architecture PKI

```mermaid
graph TB
    ROOT[Root CA<br/>EC P-256, 10 ans<br/>offline kms-output/]
    ROOT --> INFRA[Sub-CA infra<br/>5 ans]
    ROOT --> APP[Sub-CA app<br/>5 ans]

    INFRA --> CM[cert-manager<br/>ClusterIssuer internal-ca]
    CM --> HYDRA_TLS[Hydra TLS]
    CM --> SVC_TLS[Services internes TLS]

    INFRA --> SSH_CA[SSH CA<br/>OpenBao ssh-client-signer]
    SSH_CA --> WP_SSH[Woodpecker CI SSH]
    SSH_CA --> OPS_SSH[Operateurs SSH]

    APP --> APP_SEC[Secrets applicatifs<br/>Gate 2+]

    style ROOT fill:#c33,stroke:#333,color:#fff
    style INFRA fill:#36f,stroke:#333,color:#fff
    style APP fill:#36f,stroke:#333,color:#fff
```

La cle privee du Root CA n'existe que dans `kms-output/` (local, gitignore).
Les Sub-CAs sont injectees dans le cluster via `kubernetes_secret`.

## Strategie multi-environnement

```mermaid
graph TB
    MOD[modules/talos-cluster<br/>machine secrets + configs]

    MOD --> SCW[Scaleway<br/>4 stages IAM/image/cluster/CI]
    MOD --> LOCAL[Local<br/>libvirt/KVM]
    MOD --> VMW[VMware<br/>scripts airgap]

    SCW --> K8S_STACKS[7 stacks K8s<br/>provider-agnostic]
    LOCAL --> K8S_STACKS
    VMW --> K8S_STACKS
```

| Environnement | Provider | Specificites |
|---|---|---|
| Scaleway | scaleway/scaleway | 4 stages (IAM, image, cluster, CI), Load Balancer, Private Network |
| Local | libvirt | QEMU/KVM VMs, bridge networking |
| VMware | Scripts shell | Pas de Terraform (pas d'API vSphere), OVA + image cache, IPs statiques |

Toutes les stacks K8s sont provider-agnostiques — elles recoivent uniquement un `kubeconfig_path`.

## Limites des stacks

| Stack | Composants | Namespace |
|---|---|---|
| k8s-cni | Cilium + Hubble | kube-system |
| k8s-pki | OpenBao x2, cert-manager, CA secrets | secrets |
| k8s-monitoring | VictoriaMetrics, VictoriaLogs, Grafana, Headlamp | monitoring |
| k8s-identity | Kratos, Hydra, Pomerium | identity |
| k8s-security | Trivy, Tetragon, Kyverno, Cosign policy | security |
| k8s-storage | local-path, Garage, Velero, Harbor | garage, storage |
| flux-bootstrap | Flux v2, GitRepository, root Kustomization | flux-system |

## Cluster K8s — vue composants

```mermaid
graph TB
    subgraph "Control Plane x3"
        ETCD[etcd Raft]
        API[kube-apiserver<br/>OIDC Hydra]
    end

    subgraph "CNI"
        CIL[Cilium eBPF<br/>kube-proxy replacement]
        HUB[Hubble<br/>network observability]
    end

    subgraph "Securite"
        TET[Tetragon<br/>runtime eBPF]
        KYV[Kyverno<br/>admission policies]
        TRV[Trivy<br/>image scan + SBOM]
    end

    subgraph "Observabilite"
        VM[VMSingle<br/>metriques 30d]
        VMA[VMAgent<br/>scrape]
        VL[VictoriaLogs<br/>logs 30d]
        GF[Grafana<br/>dashboards]
    end

    subgraph "Stockage"
        LP[local-path-provisioner]
        GAR[Garage S3 x3<br/>replication factor 3]
        VEL[Velero<br/>backup → Garage]
        HAR[Harbor<br/>registry → Garage]
    end

    subgraph "Identite"
        KRA[Kratos<br/>identite]
        HYD[Hydra<br/>OIDC/OAuth2]
        POM[Pomerium<br/>proxy zero-trust]
    end

    CIL --> TET
    LP --> GAR
    GAR --> VEL
    GAR --> HAR
    API --> HYD
```

## GitOps (Day-2)

Apres le deploiement initial, Flux reconcilie depuis `clusters/management/` :

```
clusters/management/
    kustomization.yaml          # Root : reference toutes les stacks
    k8s-cni/                    # HelmRelease Cilium
    k8s-monitoring/             # HelmReleases monitoring
    k8s-pki/                    # HelmReleases PKI
    k8s-identity/               # HelmReleases identity
    k8s-security/               # HelmReleases security
    k8s-storage/                # HelmReleases storage
```

## Workload Clusters (CAPI)

```mermaid
graph LR
    MGMT[Management Cluster] --> CAPI[Cluster API]
    CAPI --> CAPS[CAPS<br/>Scaleway]
    CAPI --> CAPV[CAPV<br/>vSphere]
    CAPI --> CAPT[CAPT<br/>Talos OS]

    CAPS --> WL1[Workload CPU<br/>DEV1-S]
    CAPS --> WL2[Workload GPU<br/>L4-1-24G]
```

Le management cluster provisionne des workload clusters via Cluster API :
- **CAPS** (Scaleway) : instances CPU et GPU a la demande
- **CAPV** (vSphere) : VMs avec DHCP + MAC reservations (planifie)
- **CAPT** (Talos) : configure Talos OS sur les machines provisionnees
