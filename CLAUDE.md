# Talos Linux v1.12 Multi-Environment Deployment

## Project Structure

```
talos/
├── Makefile                            # Root orchestration (make help)
├── vars.mk                             # Shared version variables
│
├── terraform/
│   ├── modules/
│   │   └── talos-cluster/              # Common module: secrets, machine configs
│   ├── envs/
│   │   ├── local/                      # Provider: libvirt (QEMU/KVM)
│   │   ├── outscale/                   # Provider: outscale (FCU)
│   │   └── scaleway/                   # Provider: scaleway (fr-par)
│   │       ├── iam/                    # Stage 0: scoped IAM apps
│   │       ├── image/                  # Stage 1: Talos image builder
│   │       ├── main.tf                 # Stage 2: cluster infra
│   │       └── ci/                     # Stage 3: Gitea + Woodpecker
│   └── stacks/                         # K8s application layer (provider-agnostic)
│       ├── k8s-cni/                    # Cilium CNI (fast, ~30s, MUST be first)
│       ├── k8s-monitoring/             # vm-k8s-stack + VictoriaLogs + Headlamp
│       ├── k8s-pki/                    # OpenBao + cert-manager + CA secrets
│       ├── k8s-identity/               # Kratos + Hydra + Pomerium
│       ├── k8s-security/               # Trivy + Tetragon + Kyverno
│       ├── k8s-storage/                # local-path + Garage + Velero + Harbor
│       └── flux-bootstrap/             # Flux v2 + GitRepository + root Kustomization
│
├── clusters/management/                # Flux GitOps manifests (day-2 reconciliation)
│   ├── kustomization.yaml              # Root: references all stacks
│   ├── external-secrets/               # ESO + ClusterSecretStore (OpenBao)
│   ├── k8s-cni/                        # HelmRelease Cilium
│   ├── k8s-monitoring/                 # HelmReleases vm-k8s-stack, VictoriaLogs, Headlamp
│   ├── k8s-pki/                        # HelmReleases OpenBao, cert-manager, ClusterIssuer
│   ├── k8s-identity/                   # HelmReleases Ory + ExternalSecrets
│   ├── k8s-security/                   # HelmReleases Trivy, Tetragon, Kyverno, Cosign
│   └── k8s-storage/                    # HelmReleases Garage, Velero, Harbor + ExternalSecrets
│
├── configs/                            # Helm values + patches per component
├── scripts/                            # Shared scripts (bootstrap, setup, validation)
├── envs/vmware-airgap/                 # Non-Terraform: shell scripts pipeline
└── docs/
```

## Architecture

- **Terraform module `talos-cluster`**: generates machine secrets + machine configs
  via the `siderolabs/talos` provider. Each env calls this module then creates
  infra with its own provider (libvirt, outscale, scaleway).
- **K8s stacks**: provider-agnostic, use `kubeconfig_path` variable.
  All stacks read from `~/.kube/talos-$(ENV)`.
- **State storage**: vault-backend → OpenBao KMS (podman) KV v2. All states stored
  in OpenBao with locking + versioning. No local tfstate files.
- **Day-2 management**: Flux reconciles all stacks after initial bootstrap.
  OpenTofu handles first deploy, then hands off to Flux via `tofu state rm`.
- **Secrets**: ESO (External Secrets Operator) syncs secrets from OpenBao KV v2
  to K8s Secrets. No SOPS, no secrets in Git.
- **VMware airgap**: no Terraform. Shell scripts build OVA + generate per-node configs.

## Key Conventions

- Talos v1.12, Kubernetes 1.35, Cilium 1.17
- CNI: `cni: none` + `proxy: disabled` (Cilium replaces kube-proxy in eBPF mode)
- Topology: 3 control planes + 3 workers
- Sensitive outputs (talosconfig, kubeconfig) are marked `sensitive` in Terraform
- All k8s stacks use `kubeconfig_path` (not raw k8s credentials)
- `ENV` variable selects provider: `make ENV=local k8s-up`
- State backend: `backend "http"` → vault-backend (:8080) → OpenBao KV v2

## Common Commands

```bash
# Prerequisites (one-shot)
make kms-bootstrap                  # PKI CA chain + vault-backend + KV v2

# Full deploy (any provider)
make scaleway-up                    # Scaleway: infra + all k8s stacks + Flux
make ENV=local local-up             # Local: VMs + all k8s stacks + Flux

# Individual stacks
make k8s-cni-apply                  # Cilium CNI (must be first)
make k8s-monitoring-apply           # vm-k8s-stack + VictoriaLogs
make k8s-pki-apply                  # OpenBao + cert-manager
make k8s-identity-apply             # Kratos + Hydra + Pomerium
make k8s-security-apply             # Trivy + Tetragon + Kyverno
make k8s-storage-apply              # Garage + Velero + Harbor
make flux-bootstrap-apply           # Flux v2 (GitOps day-2)

# State management
make state-snapshot                 # Raft snapshot (backup all states)
make state-restore SNAPSHOT=f.snap  # Restore from snapshot

# Teardown
make scaleway-down                  # Destroy all (correct order)
make kms-stop                       # Stop OpenBao KMS + vault-backend
```

## Deployment Pipeline

```
kms-bootstrap (once, podman)
    │ → OpenBao KMS 3-node Raft
    │ → vault-backend :8080 (state storage)
    │ → PKI Root CA + Sub-CAs
    │
env-apply (scaleway/local/outscale)
    │ → kubeconfig → ~/.kube/talos-$(ENV)
    │
k8s-cni         ← Cilium MUST be first (~30s)
    │
    ├──── parallel (make -j2) ────┐
    │                             │
k8s-pki                       k8s-monitoring
    │                             │
openbao-init                      │
    │                             │
k8s-identity                      │
    │                             │
    ├──── parallel (make -j2) ────┤
    │                             │
k8s-security                  k8s-storage
    │                             │
    └──── flux-bootstrap ─────────┘
              │
              ▼
         Flux day-2 (GitOps reconciliation)
         ├── ESO → OpenBao secrets → K8s Secrets
         ├── HelmReleases (drift detection, self-healing)
         └── Kustomize overlays (per-environment)
```

## Stack Boundaries

| Stack | Owns | Interface |
|-------|------|-----------|
| k8s-cni | Cilium | kube-system (CNI DaemonSet) |
| k8s-monitoring | vm-k8s-stack, VictoriaLogs, Headlamp | monitoring namespace |
| k8s-pki | OpenBao x2, cert-manager, ClusterIssuer, CA secrets | ClusterIssuer "internal-ca", secrets namespace |
| k8s-identity | Kratos, Hydra, Pomerium, OIDC registration | identity namespace |
| k8s-security | Trivy, Tetragon, Kyverno, Cosign policy | security namespace |
| k8s-storage | local-path, Garage, Velero, Harbor | storage namespace |
| flux-bootstrap | Flux v2, GitRepository, root Kustomization | flux-system namespace |
| external-secrets | ESO, ClusterSecretStore | external-secrets namespace |

## State Storage (vault-backend + OpenBao KV v2)

All OpenTofu states stored in OpenBao KMS (podman, 3-node Raft).
vault-backend provides HTTP backend with locking + KV v2 versioning.

```
OpenTofu ──HTTP──→ vault-backend (:8080) ──→ OpenBao KV v2 (:8200)
                   ├── /state/scaleway          → secret/data/tfstate/scaleway
                   ├── /state/k8s-cni           → secret/data/tfstate/k8s-cni
                   ├── /state/k8s-monitoring    → secret/data/tfstate/k8s-monitoring
                   ├── /state/k8s-pki           → secret/data/tfstate/k8s-pki
                   ├── /state/k8s-identity      → secret/data/tfstate/k8s-identity
                   ├── /state/k8s-security      → secret/data/tfstate/k8s-security
                   ├── /state/k8s-storage       → secret/data/tfstate/k8s-storage
                   └── /state/flux-bootstrap    → secret/data/tfstate/flux-bootstrap
```

- **Auth**: `TF_HTTP_PASSWORD` env var (vault-backend token from kms-output/)
- **Encryption**: Raft at-rest (native OpenBao)
- **Locking**: vault-backend creates `-lock` secrets in KV v2
- **DR**: `make state-snapshot` → Raft snapshot file (backup all states at once)
- **Bootstrap OpenBao does NOT stop automatically** — `make kms-stop` to shut down

## Secrets Management (ESO + OpenBao)

Secrets flow: OpenBao KV v2 → ESO ClusterSecretStore → ExternalSecret → K8s Secret

| Secret | OpenBao path | K8s Secret | Namespace |
|--------|-------------|------------|-----------|
| Hydra system secret | secret/identity/hydra | hydra-secrets | identity |
| Pomerium shared/cookie/client | secret/identity/pomerium | pomerium-secrets | identity |
| Garage RPC + admin token | secret/storage/garage | garage-secrets | garage |
| Harbor admin password | secret/storage/harbor | harbor-secrets | storage |

No SOPS. No secrets in Git. ESO refreshes every 1h from OpenBao.

## Debugging Guide

### Symptom → Cause → Fix

| Symptom | Cause | Fix |
|---------|-------|-----|
| Pods stuck in `ContainerCreating` | Cilium CNI not ready | `make k8s-cni-apply` must complete first |
| `k8s-pki-apply` fails: file not found | `kms-output/` missing | Run `make kms-bootstrap` (one-shot, needs podman) |
| `tofu init` fails: connection refused | vault-backend not running | `make kms-bootstrap` or restart: `podman pod start openbao-kms` |
| Kyverno webhooks block deletions | Webhooks persist after pods gone | `make k8s-down` handles this (deletes webhooks first) |
| OpenBao returns `sealed` | Standalone mode, not initialized | `make openbao-init` (after k8s-pki-apply) |
| `k8s-storage-init` fails | Garage Helm chart not fetched | Auto-handled: `k8s-storage-init` depends on `garage-chart` |
| Port-forward zombie processes | Previous session not cleaned | `pkill -f 'kubectl port-forward'` (included in k8s-down) |
| Hydra TLS cert not issued | ClusterIssuer not ready | k8s-pki must be applied before k8s-identity |
| Flux not reconciling | GitRepository secret missing | Check `flux-git-credentials` in flux-system namespace |
| ESO ExternalSecret stuck | ClusterSecretStore not ready | Check openbao-infra-token secret in external-secrets namespace |

### Architecture Invariants

- Cilium MUST be deployed before any other k8s stack (it's the CNI)
- Cilium MUST be destroyed LAST (removing it breaks pod eviction)
- k8s-pki MUST be deployed before k8s-identity (ClusterIssuer dependency)
- openbao-init MUST run after k8s-pki deploy (pods must be running)
- k8s-storage is self-contained (generates its own harbor_admin_password)
- Stacks are provider-agnostic: they only need a kubeconfig path
- vault-backend (podman) must be running for any tofu command
- Bootstrap OpenBao does NOT auto-stop — use `make kms-stop`

### Checking Stack Health

```bash
# vault-backend + OpenBao KMS
curl -s http://localhost:8080/state/k8s-cni | head -c 100  # state accessible?
curl -s http://localhost:8200/v1/sys/health | jq .          # OpenBao healthy?

# Cilium
kubectl -n kube-system get pods -l app.kubernetes.io/name=cilium-agent

# OpenBao (in-cluster)
kubectl -n secrets exec openbao-infra-0 -- bao status
kubectl -n secrets exec openbao-app-0 -- bao status

# Flux
kubectl -n flux-system get kustomizations
kubectl -n flux-system get helmreleases -A

# ESO
kubectl get externalsecrets -A
kubectl get clustersecretstores

# Garage
kubectl -n garage exec garage-0 -- /garage status

# All stacks
kubectl get pods -A | grep -v Running | grep -v Completed

# Raft snapshot (DR backup)
make state-snapshot
```
