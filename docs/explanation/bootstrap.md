# Bootstrap : resoudre les problemes oeuf et poule

Ce document explique les dependances circulaires rencontrees lors du bootstrap
de la plateforme et comment chacune est resolue.

## Vue d'ensemble

```mermaid
graph TB
    subgraph "Phase 0 — Local (poste operateur)"
        KMS[make kms-bootstrap<br/>OpenBao local Podman]
        KMS --> CA[Root CA + 2 Sub-CAs<br/>infra + app]
        KMS --> VB[vault-backend<br/>:8080]
        KMS --> TRANSIT[Transit engine<br/>aes256-gcm96]
    end

    subgraph "Phase 1 — Cloud (Scaleway/vSphere)"
        IAM[make scaleway-iam-apply<br/>3 API keys scoped]
        IMG[make scaleway-image-apply<br/>Talos OVA/snapshot]
        CLUSTER[make scaleway-apply<br/>6 noeuds Talos]
        CI[make scaleway-ci-apply<br/>Gitea + Woodpecker]
    end

    subgraph "Phase 2 — K8s stacks (sequentiel)"
        CNI[k8s-cni<br/>Cilium]
        PKI[k8s-pki<br/>OpenBao + cert-manager]
        MON[k8s-monitoring<br/>VictoriaMetrics]
        INIT[openbao-init<br/>Transit + SSH CA]
        IDN[k8s-identity<br/>Kratos + Hydra]
        SEC[k8s-security<br/>Trivy + Tetragon + Kyverno]
        STO[k8s-storage<br/>Garage + Velero + Harbor]
        FLUX[flux-bootstrap<br/>Flux SSH]
    end

    KMS --> CLUSTER
    IAM --> IMG --> CLUSTER
    IAM --> CI
    CLUSTER --> CNI --> PKI --> MON --> INIT --> IDN --> SEC --> STO --> FLUX
    CA -.->|inject sub-CAs| PKI
    VB -.->|state backend| CNI
```

## Les 5 problemes oeuf/poule

### 1. CNI avant tout (mais Flux ne peut pas deployer Cilium)

```mermaid
graph LR
    FLUX[Flux] -->|deploie| CILIUM[Cilium CNI]
    CILIUM -->|necessite pour| PODS[Pods fonctionnels]
    PODS -->|necessite pour| FLUX

    style FLUX fill:#f66,stroke:#333
    style CILIUM fill:#f66,stroke:#333
    style PODS fill:#f66,stroke:#333
```

**Probleme** : Flux a besoin du reseau (Cilium) pour tourner.
Mais Cilium est le premier composant a deployer. Sans CNI, aucun pod ne peut
etre schedule — y compris Flux lui-meme.

**Solution** : OpenTofu deploie Cilium directement via `helm_release`,
sans passer par Flux. Flux est deploye en dernier pour le drift detection.

```mermaid
graph LR
    TF[OpenTofu] -->|helm_release| CILIUM[Cilium]
    CILIUM --> PODS[Pods OK]
    PODS --> FLUX[Flux deploye en dernier]
    FLUX -.->|drift detection| ALL[Toutes les stacks]

    style TF fill:#6c6,stroke:#333
    style CILIUM fill:#6c6,stroke:#333
```

### 2. State backend avant le state (mais le backend a besoin d'infra)

```mermaid
graph LR
    TF[OpenTofu] -->|stocke state dans| S3[Garage S3]
    S3 -->|deploye par| TF

    style TF fill:#f66,stroke:#333
    style S3 fill:#f66,stroke:#333
```

**Probleme** : OpenTofu a besoin d'un backend pour stocker le state.
Le backend naturel serait Garage S3, mais Garage n'existe pas encore
(il est deploye par OpenTofu a l'etape 7).

**Solution** : Un backend HTTP local (vault-backend) qui stocke le state
dans OpenBao KV v2, tournant en Podman sur le poste operateur.

```mermaid
graph LR
    KMS[make kms-bootstrap] --> BAO[OpenBao local<br/>Podman 3 noeuds Raft]
    BAO --> KV[KV v2<br/>state/stack-name]
    BAO --> TR[Transit<br/>chiffrement state]
    KMS --> VB[vault-backend<br/>:8080]

    TF[OpenTofu] -->|HTTP backend| VB
    VB -->|read/write| KV
    VB -->|encrypt/decrypt| TR

    style KMS fill:#6c6,stroke:#333
```

### 3. PKI avant les secrets (mais les CAs doivent exister avant le cluster)

```mermaid
graph LR
    CM[cert-manager] -->|signe avec| CA[Sub-CA]
    CA -->|generee par| BAO[OpenBao cluster]
    BAO -->|deploye dans| K8S[Cluster K8s]
    K8S -->|bootstrap par| TF[OpenTofu]
    TF -->|a besoin de| CA

    style CM fill:#f66,stroke:#333
    style CA fill:#f66,stroke:#333
```

**Probleme** : cert-manager a besoin des CAs pour signer des certificats.
Les CAs doivent etre generees avant le cluster. Mais OpenBao (qui gere les CAs)
tourne dans le cluster.

**Solution** : PKI en deux phases. Le KMS local genere la chaine de confiance
(Root CA + 2 Sub-CAs). Les Sub-CAs sont injectees dans le cluster via
Terraform `kubernetes_secret`.

```mermaid
graph TB
    subgraph "Local (kms-bootstrap)"
        ROOT[Root CA<br/>EC P-256, 10 ans]
        ROOT --> INFRA[Sub-CA infra<br/>5 ans]
        ROOT --> APP[Sub-CA app<br/>5 ans]
    end

    subgraph "Cluster K8s"
        INFRA -.->|kubernetes_secret| OBINFRA[OpenBao infra<br/>Transit + SSH CA]
        APP -.->|kubernetes_secret| OBAPP[OpenBao app<br/>secrets applicatifs]
        OBINFRA --> CERTM[cert-manager<br/>ClusterIssuer internal-ca]
    end

    style ROOT fill:#6c6,stroke:#333
```

### 4. Gitea avant le pipeline (mais Gitea est deploye par le pipeline)

```mermaid
graph LR
    WP[Woodpecker] -->|clone depuis| GITEA[Gitea]
    GITEA -->|deploye par| WP

    style WP fill:#f66,stroke:#333
    style GITEA fill:#f66,stroke:#333
```

**Probleme** : Woodpecker CI a besoin de Gitea pour cloner le repo.
Mais Gitea est provisionne par l'infra qu'on deploie.

**Solution** : Gitea et Woodpecker tournent sur une VM CI separee (hors cluster),
deployee par OpenTofu via cloud-init. Cette VM est independante du cluster K8s.

```mermaid
graph TB
    subgraph "VM CI (Podman Quadlet)"
        GITEA[Gitea :3000/:2222]
        WP_S[Woodpecker Server :8000]
        WP_A[Woodpecker Agent]
        GITEA <--> WP_S
        WP_S <--> WP_A
    end

    subgraph "Cluster K8s (6 noeuds)"
        CNI[Cilium] --> STACKS[8 stacks...]
    end

    TF[make scaleway-ci-apply] -->|cloud-init| GITEA
    WP_A -->|tofu apply via kubeconfig| STACKS

    style TF fill:#6c6,stroke:#333
```

### 5. Flux SSH key avant Gitea (mais la known_hosts depend de Gitea)

```mermaid
graph LR
    FLUX[Flux] -->|SSH| GITEA[Gitea]
    FLUX -->|known_hosts ?| GITEA
    GITEA -->|pas encore deploye| NOPE[???]

    style FLUX fill:#f66,stroke:#333
    style NOPE fill:#f66,stroke:#333
```

**Probleme** : Flux a besoin de la cle SSH de Gitea pour le `known_hosts`.
Mais Gitea n'est pas encore deploye quand on configure Flux.

**Solution** : Terraform genere une cle ed25519 statique (`tls_private_key`).
Le `known_hosts` contient un placeholder, mis a jour apres le premier deploy
de la VM CI.

```mermaid
graph LR
    TF[Terraform] -->|tls_private_key| KEY[ed25519 key]
    KEY -->|K8s Secret| FLUX[Flux source-controller]
    FLUX -->|SSH avec cle statique| GITEA[Gitea]
    GITEA -->|deploy key = pub| KEY

    style TF fill:#6c6,stroke:#333
```

## Sequence complete de bootstrap

```mermaid
sequenceDiagram
    participant OP as Operateur
    participant KMS as KMS Local (Podman)
    participant SCW as Scaleway API
    participant K8S as Cluster K8s
    participant CI as VM CI

    Note over OP: Phase 0 — Prerequisites locaux
    OP->>KMS: make kms-bootstrap
    KMS-->>KMS: OpenBao Raft (3 noeuds)
    KMS-->>KMS: Root CA + 2 Sub-CAs
    KMS-->>KMS: vault-backend :8080

    Note over OP: Phase 1 — Infrastructure cloud
    OP->>SCW: make scaleway-iam-apply
    SCW-->>OP: 3 API keys scoped
    OP->>SCW: make scaleway-image-apply
    SCW-->>OP: Talos snapshot
    OP->>SCW: make scaleway-apply
    SCW-->>K8S: 6 VMs Talos (3 CP + 3 W)
    OP->>SCW: make scaleway-ci-apply
    SCW-->>CI: VM Gitea + Woodpecker

    Note over OP: Phase 2 — K8s stacks (sequentiel)
    OP->>K8S: k8s-cni (Cilium)
    OP->>K8S: k8s-pki (OpenBao + cert-manager + CAs)
    OP->>K8S: k8s-monitoring (VictoriaMetrics)
    OP->>K8S: openbao-init (Transit + SSH CA)
    OP->>K8S: k8s-identity (Kratos + Hydra + Pomerium)
    OP->>K8S: k8s-security (Trivy + Tetragon + Kyverno)
    OP->>K8S: k8s-storage (Garage + Velero + Harbor)
    OP->>K8S: flux-bootstrap (Flux SSH → Gitea)

    Note over CI: Phase 3 — GitOps autonome
    CI->>K8S: Woodpecker pipeline (push-triggered)
    K8S-->>K8S: Flux drift detection
```

## Resume des solutions

| Probleme oeuf/poule | Solution |
|---|---|
| CNI avant Flux | OpenTofu deploie Cilium directement, Flux en dernier |
| State backend avant S3 | vault-backend local (Podman) → OpenBao KV v2 |
| CAs avant cluster | KMS local genere Root + Sub-CAs, injectees via K8s secrets |
| Gitea avant pipeline | VM CI separee (cloud-init), hors du cluster |
| Flux SSH avant Gitea | Cle statique ed25519 + placeholder known_hosts |
