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
- **Secrets**: OpenBao (2 instances: infra + app) + ESO (External Secrets Operator)
- **PKI**: Root CA + 2 intermediate CAs (infra + app), cert-manager ClusterIssuer
- **Identity**: Ory Kratos + Hydra + Pomerium (zero-trust proxy, OIDC)
- **Monitoring**: victoria-metrics-k8s-stack + VictoriaLogs + Headlamp + Grafana
- **Security**: Trivy + Tetragon + Kyverno + Cosign policy
- **Storage**: local-path-provisioner + Garage S3 + Velero + Harbor

## Architecture

The platform uses a two-phase deployment model. Phase 1 (OpenTofu) bootstraps infrastructure and all Kubernetes stacks in strict dependency order. Phase 2 (Flux) takes over day-2 reconciliation via GitOps.

A shared Terraform module (`terraform/modules/talos-cluster`) generates machine secrets and configs via the siderolabs/talos provider. Each environment (Scaleway, local, Outscale, VMware) calls this module and adds its own cloud resources. All Kubernetes stacks are provider-agnostic -- they only need a kubeconfig path.

State is stored in OpenBao KV v2 via vault-backend (HTTP backend with locking), running in a local podman pod. This avoids any cloud dependency for state storage. Secrets flow from OpenBao through ESO into Kubernetes Secrets, with zero secrets in Git.

The VMware airgap path is entirely script-based (no Terraform) due to lack of vSphere API access -- it builds OVA images with embedded container image caches.

## Domain Concepts

- **KMS bootstrap**: Local podman pod running 3-node OpenBao Raft cluster. Generates PKI CA chain, Transit auto-unseal keys, and vault-backend token. Must run once before any cloud deployment.
- **Stack**: A self-contained Terraform root module in `terraform/stacks/` that deploys one logical layer (CNI, monitoring, PKI, identity, security, storage, flux).
- **Environment (env)**: A cloud provider configuration in `terraform/envs/` (Scaleway has 4 stages: IAM, image, cluster, CI).
- **vault-backend**: HTTP proxy that translates Terraform HTTP backend protocol to OpenBao KV v2 API. Runs on port 8080.
- **openbao-init**: Post-deploy step that initializes and unseals the in-cluster OpenBao instances (separate from the bootstrap KMS).
- **CAPI**: Cluster API -- creates workload clusters on demand from the management cluster.

## Key Patterns

- All Makefile targets follow `<provider>-<action>` (e.g., `scaleway-apply`) or `k8s-<stack>-<action>` (e.g., `k8s-cni-apply`).
- Composite targets enforce ordering: `k8s-up` deploys all stacks with correct dependencies and parallelism (`make -j2`).
- Destroy order is the reverse of create order. Cilium must be destroyed last (it is the CNI). Kyverno webhooks must be deleted before other resources.
- Secrets are auto-generated via `random_id` Terraform resources -- no manual `secret.tfvars` for application secrets.
- Scaleway credentials flow through IAM stage outputs (`tofu -chdir=iam output -raw ...`).
- All Helm values live in `configs/<component>/values.yaml`. Terraform references them via `file()`.
- ADRs are numbered sequentially in `docs/adr/` and written in French.

## Commands

```bash
# Prerequisites (once)
make kms-bootstrap              # PKI CA chain + vault-backend (needs podman)

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
make kms-stop                   # Stop local KMS pod

# State management
make state-snapshot             # Raft snapshot backup
make state-restore SNAPSHOT=f   # Restore from snapshot

# Tests
make scaleway-test              # All Scaleway tofu tests
make velero-test                # Backup/restore validation

# UI access
make scaleway-headlamp          # Headlamp UI (token in clipboard)
make scaleway-grafana           # Grafana UI
make scaleway-harbor            # Harbor UI (password in clipboard)

# CAPI workload clusters
make capi-init                  # Install CAPI providers
make capi-create-cpu            # Create CPU workload cluster
make capi-create-gpu            # Create GPU workload cluster
```

## Gotchas

- **vault-backend must be running** for any `tofu` command. If `tofu init` fails with "connection refused", run `make kms-bootstrap` or restart: `podman pod start openbao-kms`.
- **Cilium must deploy before anything else**. Without CNI, no pods can schedule. The `k8s-up` target handles this automatically.
- **openbao-init is a separate step** from kms-bootstrap. The former initializes in-cluster OpenBao instances; the latter bootstraps the local KMS. Both are needed.
- **Scaleway uses 4 stages**: IAM (admin creds) -> image (builder VM) -> cluster (VMs + LB) -> CI (Gitea + Woodpecker). Credentials chain between stages.
- **No README.md exists** -- this file and CLAUDE.md are the primary documentation.
- **ADRs are in French** -- 17 ADRs in `docs/adr/` covering all major architectural decisions.
- **Talos has no shell access** -- you cannot SSH into nodes. Use `talosctl` for node operations.
- **Kyverno webhooks block deletion** -- `k8s-down` deletes webhooks first to prevent cascading failures.
- **Harbor admin password** is auto-generated by `random_id` in the k8s-storage stack state. Use `make scaleway-harbor` to access.
- **Port-forward zombies** -- previous `kubectl port-forward` processes may linger. `k8s-down` kills them.
