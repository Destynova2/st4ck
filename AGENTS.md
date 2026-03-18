# Talos Linux Multi-Environment Deployment Platform

Sovereign air-gapped Kubernetes platform built on Talos Linux v1.12, deploying a full management cluster with CNI, PKI, identity, monitoring, security, storage, and GitOps stacks across Scaleway, libvirt/KVM, Outscale, and VMware environments.

## Stack

- **OS**: Talos Linux v1.12.4 (immutable, no SSH, no shell, no systemd)
- **Kubernetes**: v1.35.0 (3 control planes + 3 workers)
- **IaC**: OpenTofu (Terraform fork), HCL, Makefile orchestration
- **CNI**: Cilium 1.17.13 (eBPF, replaces kube-proxy)
- **State backend**: vault-backend -> OpenBao KV v2 (podman, 3-node Raft)
- **CI/CD**: Woodpecker CI + Gitea (Podman Quadlet on Scaleway VM)
- **GitOps day-2**: Flux v2 (HelmReleases + Kustomize)
- **Secrets**: OpenBao (2 instances: infra + app), auto-generated via `random_id` Terraform
- **PKI**: Root CA + intermediate CA (Terraform TLS provider), cert-manager ClusterIssuer
- **Identity**: Ory Kratos + Hydra + Pomerium (zero-trust proxy, OIDC)
- **Monitoring**: victoria-metrics-k8s-stack + VictoriaLogs + Headlamp + Grafana
- **Security**: Trivy + Tetragon + Kyverno + Cosign policy
- **Storage**: local-path-provisioner + Garage S3 + Velero + Harbor

## Architecture

The platform uses a two-phase deployment model. Phase 1 (OpenTofu) bootstraps infrastructure and all Kubernetes stacks in strict dependency order. Phase 2 (Flux) takes over day-2 reconciliation via GitOps.

A shared Terraform module (`modules/talos-cluster`) generates machine secrets and configs via the siderolabs/talos provider. Each environment (Scaleway, local, Outscale, VMware) calls this module and adds its own cloud resources. All Kubernetes stacks are provider-agnostic -- they only need a kubeconfig path.

State is stored in OpenBao KV v2 via vault-backend (HTTP backend with locking), running in a local podman pod. Secrets are auto-generated via `random_id` Terraform, stored in encrypted state, zero secrets in Git.

Bootstrap uses a single Terraform module (`bootstrap/`) that generates a podman pod manifest with 6 containers: 3 OpenBao nodes (Raft), vault-backend, Gitea, and a tofu-setup sidecar that auto-initializes everything.

## Domain Concepts

- **Platform pod**: Local podman pod running 3-node OpenBao Raft cluster + vault-backend + Gitea + Woodpecker. Single Terraform module in `bootstrap/`. Must run once before any cloud deployment.
- **Stack**: A self-contained folder in `stacks/` co-locating TF code, Helm values, and Flux manifests for one logical layer (CNI, monitoring, PKI, identity, security, storage, flux).
- **Environment (env)**: A cloud provider configuration in `envs/` (Scaleway has 4 stages: IAM, image, cluster, CI).
- **vault-backend**: HTTP proxy that translates Terraform HTTP backend protocol to OpenBao KV v2 API. Runs on port 8080.
- **kms-output/**: Directory containing tokens and certs exported from the platform pod. Gitignored. Required for all tofu commands.

## Key Patterns

- All Makefile targets follow `<provider>-<action>` (e.g., `scaleway-apply`) or `k8s-<stack>-<action>` (e.g., `k8s-cni-apply`).
- Composite targets enforce ordering: `k8s-up` deploys all stacks sequentially (parallel was removed due to race conditions).
- Destroy order is the reverse of create order. Cilium must be destroyed last (it is the CNI). Kyverno webhooks must be deleted before other resources.
- Secrets are auto-generated via `random_id` Terraform resources -- no manual `secret.tfvars` for application secrets.
- Scaleway credentials flow through IAM stage outputs (`tofu -chdir=iam output -raw ...`).
- Helm values are co-located in each stack folder (e.g., `stacks/cni/values.yaml`). Terraform references them via `file("${path.module}/...")`.
- ADRs are numbered sequentially in `docs/adr/` and written in French.
- Bootstrap is a single TF module (`bootstrap/main.tf`) that works for both local and remote (CI VM) deployments.

## Commands

```bash
# Prerequisites (once)
make bootstrap                  # Platform pod: OpenBao + Gitea + Woodpecker (needs podman)
make bootstrap-export           # Copy tokens/certs to kms-output/

# Full deployment
make scaleway-up                # Scaleway: infra + all k8s stacks + Flux
make ENV=local local-up         # Local: libvirt VMs + all k8s stacks

# Individual stacks
make k8s-cni-apply              # Cilium (must be first)
make k8s-pki-apply              # OpenBao + cert-manager + PKI secrets
make k8s-monitoring-apply       # VictoriaMetrics + VictoriaLogs + Headlamp
make k8s-identity-apply         # Kratos + Hydra + Pomerium
make k8s-security-apply         # Trivy + Tetragon + Kyverno
make k8s-storage-apply          # local-path + Garage + Velero + Harbor
make flux-bootstrap-apply       # Flux v2 GitOps

# Teardown (correct order)
make scaleway-down              # All k8s stacks + cluster
make bootstrap-stop             # Stop local platform pod

# State management
make state-snapshot             # Raft snapshot backup
make state-restore SNAPSHOT=f   # Restore from snapshot

# Tests
make validate                   # Validate all Terraform stacks
make scaleway-test              # All Scaleway tofu tests
make velero-test                # Backup/restore validation

# UI access
make scaleway-headlamp          # Headlamp UI (token in clipboard)
make scaleway-grafana           # Grafana UI
make scaleway-harbor            # Harbor UI (password in clipboard)
```

## Gotchas

- **vault-backend must be running** for any `tofu` command. If `tofu init` fails with "connection refused", run `make bootstrap` or restart: `podman pod start platform`.
- **Cilium must deploy before anything else**. Without CNI, no pods can schedule. The `k8s-up` target handles this automatically.
- **Scaleway uses 4 stages**: IAM (admin creds) -> image (builder VM) -> cluster (VMs + LB) -> CI (Gitea + Woodpecker). Credentials chain between stages.
- **ADRs are in French** -- 20 ADRs in `docs/adr/` covering all major architectural decisions.
- **Bootstrap has 5 chicken-and-egg problems** resolved by design -- see `docs/explanation/bootstrap.md`.
- **Talos has no shell access** -- you cannot SSH into nodes. Use `talosctl` for node operations.
- **Kyverno webhooks block deletion** -- `k8s-down` deletes webhooks first to prevent cascading failures.
- **Harbor admin password** is auto-generated by `random_id` in the k8s-storage stack state. Use `make scaleway-harbor` to access.
- **Port-forward zombies** -- previous `kubectl port-forward` processes may linger. `k8s-down` kills them.
- **Bootstrap is now a single TF module** (`bootstrap/`) -- old references to `scripts/openbao-kms-bootstrap.sh` or `configs/openbao/` are stale.
