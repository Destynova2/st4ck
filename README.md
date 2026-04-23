# St4ck

> Sovereign Kubernetes platform on Talos Linux — from bare metal to production in one command.

[![Talos](https://img.shields.io/badge/Talos-v1.12.6-blue)](https://www.talos.dev/)
[![K8s](https://img.shields.io/badge/Kubernetes-1.35.4-blue)](https://kubernetes.io/)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

```mermaid
graph LR
    B[Bootstrap<br/>Podman pod] -->|PKI + state backend| C[Cluster<br/>6 Talos nodes]
    C -->|7 stacks sequential| K[Platform<br/>27 Helm charts]
    K -->|day-2| F[Flux v2<br/>GitOps]

    style B fill:#4a9,stroke:#333,color:#fff
    style K fill:#36f,stroke:#333,color:#fff
    style F fill:#f90,stroke:#333,color:#fff
```

## Quickstart

```bash
# Prerequisites: opentofu, podman, kubectl
make bootstrap && make bootstrap-export   # Platform pod (OpenBao + Gitea + Woodpecker)
make scaleway-up                          # Full cluster + 7 stacks (~15 min)
make scaleway-headlamp                    # Open dashboard (token in clipboard)
```

## What you get

| Stack | Components | Deploy time |
|-------|-----------|-------------|
| **CNI** | Cilium (eBPF, replaces kube-proxy) | ~30s |
| **PKI** | OpenBao x2 + cert-manager + 3-tier CA | ~2min |
| **Monitoring** | VictoriaMetrics + VictoriaLogs + Grafana + Headlamp | ~2min |
| **Identity** | Ory Kratos + Hydra + Pomerium (OIDC/SSO) | ~1min |
| **Security** | Trivy + Tetragon + Kyverno + Cosign | ~2min |
| **Storage** | Garage S3 + Velero + Harbor + local-path | ~3min |
| **GitOps** | Flux v2 (SSH → Gitea) | ~30s |

Zero secrets in Git. All auto-generated, stored in OpenBao, synced by ESO.

## Supported environments

| Environment | Provider | Method |
|-------------|----------|--------|
| Scaleway | `scaleway/scaleway` | OpenTofu (4 stages: IAM → image → cluster → CI) |
| Local | `dmacvicar/libvirt` | OpenTofu (QEMU/KVM VMs) |
| VMware air-gap | Shell scripts | OVA + embedded image cache + static IPs |

```bash
make scaleway-up                # Cloud
make ENV=local local-up         # Local KVM
```

## Architecture

```
bootstrap (podman pod, local or remote VM)
    ├── OpenBao KMS (Raft) → state backend + PKI CA chain
    ├── vault-backend :8080 → HTTP backend for OpenTofu state
    ├── Gitea :3000 → Git server
    └── Woodpecker :8000 → CI/CD

        ↓ kms-output/ (certs + tokens)

cluster (3 CP + 3 workers, Talos Linux)
    ├── stacks/cni/         → Cilium
    ├── stacks/pki/         → OpenBao Infra + App + cert-manager + secrets generation
    ├── stacks/monitoring/  → VictoriaMetrics + VictoriaLogs + Headlamp
    ├── stacks/identity/    → Kratos + Hydra + Pomerium
    ├── stacks/security/    → Trivy + Tetragon + Kyverno + Cosign
    ├── stacks/storage/     → Garage S3 + Velero + Harbor
    └── stacks/flux-bootstrap/ → Flux v2 → clusters/management/

        ↓ day-2

Flux reconciles HelmReleases from Git (Gitea → flux-system)
ESO syncs secrets from in-cluster OpenBao → K8s Secrets
```

Each stack co-locates Terraform code, Helm values, and Flux manifests in one folder.

## Scaleway CLI setup

```bash
brew install scw                                    # macOS
scw init                                            # Interactive setup
scw iam api-key create user-id=<uid> description="talos-admin"
```

Then create `envs/scaleway/iam/secret.tfvars`:

```hcl
scw_access_key      = "<from api-key create>"
scw_secret_key      = "<from api-key create>"
scw_organization_id = "<your-org-id>"
```

## Documentation

| Need | Go to |
|------|-------|
| First deployment walkthrough | [Getting Started](docs/tutorials/getting-started.md) |
| Deploy to a specific environment | [How to Deploy](docs/how-to/deploy.md) |
| Upgrade an existing deployment | [Upgrade Guide](docs/how-to/upgrade.md) |
| Troubleshoot a problem | [Troubleshooting](docs/how-to/troubleshoot.md) |
| All Makefile targets | [Command Reference](docs/reference/commands.md) |
| Configuration parameters | [Configuration Reference](docs/reference/config.md) |
| CI/CD pipeline details | [CI/CD Reference](docs/reference/ci-cd.md) |
| Architecture deep dive | [Architecture](docs/explanation/architecture.md) |
| Bootstrap mechanics | [Bootstrap Mechanics](docs/explanation/bootstrap.md) |
| Security model | [Security Model](docs/explanation/security.md) |
| High-level design | [HLD](docs/hld-talos-platform.md) |
| Low-level designs | [LLDs](docs/lld/) |
| Component inventory | [Technology Stack](docs/techno.md) |
| Architecture decisions | [ADRs](docs/adr/) (22 ADRs) |
| AI agent context | [AGENTS.md](AGENTS.md) |

## Project structure

```
st4ck/
├── bootstrap/          # Platform pod: OpenBao + Gitea + Woodpecker
├── envs/               # Provider-specific infra (Scaleway, local, Outscale, VMware)
├── modules/            # Shared Terraform module (talos-cluster)
├── stacks/             # 1 stack = 1 folder (TF + values + flux/)
├── clusters/management # Thin kustomization → stacks/*/flux/
├── patches/            # Machine config patches (Cilium, registry mirror)
├── docs/               # Diátaxis structure (tutorials, how-to, reference, explanation)
└── scripts/            # Day-2 operations
```

## Teardown

```bash
make scaleway-down      # Destroy k8s stacks + cluster (correct order)
make bootstrap-stop     # Stop local platform pod
make scaleway-nuke      # Destroy EVERYTHING including IAM (requires confirmation)
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[Apache 2.0](LICENSE)
