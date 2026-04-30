# Talos Linux v1.12 Multi-Environment Deployment

## Project Structure

```
talos/
├── Makefile                            # Root orchestration (make help)
├── vars.mk                            # Shared version variables
│
├── bootstrap/                          # Platform pod (podman) — runs BEFORE cluster
│   ├── main.tf                         # Bootstrap Terraform module (generates pod + configmap)
│   ├── platform-pod.yaml               # Single pod: OpenBao 3-node + vault-backend + Gitea + WP
│   └── tofu/                           # Setup sidecar TF: KMS init, CI setup, repo push, secrets
│
├── contexts/                           # 1 YAML per (env, instance, region) cluster
│   ├── _defaults.yaml                  # Shared defaults (merged under every context)
│   ├── dev-alice-fr-par.yaml           # Example: Alice's dev sandbox
│   ├── dev-shared-fr-par.yaml          # Example: shared dev CI VM
│   └── README.md
│
├── envs/                               # Provider-specific infra
│   ├── local/                          # Provider: libvirt (QEMU/KVM)
│   ├── scaleway/                       # Provider: scaleway (multi-region)
│   │   ├── iam/                        # Stage 0: project + 9 IAM apps (3 envs × 3 roles)
│   │   ├── image/                      # Stage 1: Talos image (semver + schematic-sha7, per region)
│   │   ├── main.tf                     # Stage 2: cluster (consumes var.context_file)
│   │   └── ci/                         # Stage 3: CI VM (one per env/instance/region)
│   └── vmware-airgap/                  # Non-Terraform: shell scripts pipeline
│
├── modules/
│   ├── naming/                         # Enforced naming + tags (plan-time validation)
│   ├── context/                        # YAML context loader (merges _defaults.yaml + overlay)
│   └── talos-cluster/                  # Common module: secrets, machine configs
│
├── stacks/                             # 1 stack = 1 folder (TF + values + flux)
│   │  ─── Core (deployed by `make scaleway-up` / `make k8s-up`) ───
│   ├── cni/                            # Cilium CNI (eBPF, replaces kube-proxy)
│   ├── pki/                            # OpenBao + cert-manager + CA secrets
│   ├── monitoring/                     # vm-k8s-stack + VictoriaLogs + Headlamp
│   ├── identity/                       # Kratos + Hydra + Pomerium
│   ├── security/                       # Trivy + Tetragon + Kyverno
│   ├── storage/                        # local-path + Garage + Velero + Harbor
│   ├── flux-bootstrap/                 # Flux v2 + GitRepository + root Kustomization
│   ├── external-secrets/               # Flux only (ESO + ClusterSecretStore)
│   │  ─── KaaS / Phase A (deployed by `make kaas-up`) ─────────────
│   ├── capi/                           # Cluster API + CABPT + Talos infra provider
│   ├── kamaji/                         # Hosted control planes for tenant clusters
│   ├── autoscaling/                    # Karpenter + provider-cluster-api + NodePools
│   ├── gateway-api/                    # Cilium Gateway API + tenant TLSRoute
│   └── managed-cluster/                # Cozystack-style `Kubernetes` CR controller
│
├── clusters/management/                # Thin kustomization.yaml → ../../stacks/*/flux/
├── patches/                            # Machine config patches (cilium-cni,
│                                       #   registry-mirror, kubelet-nodeip-vpc, …)
├── scripts/                            # Day-2 + validation + brigade helpers
├── docs/
│   ├── adr/                            # 26 ADRs (architecture decisions)
│   ├── reviews/                        # cli-cycle audit reports per pass
│   └── …
└── tests/
```

## Architecture

- **Multi-env**: N parallel clusters identified by `(env, instance, region)`. One YAML
  in `contexts/` per cluster. See `docs/NAMING.md` + `docs/MULTI-ENV.md`.
- **Naming convention** (enforced via `modules/naming`):
  `{namespace}-{env}-{instance}-{region}-{component}[-{attr}][-{NN}]`.
  Plan-time validation on length, charset, env class. No silent drift.
- **Talos images**: `{namespace}-talos-{semver}-{schematic_sha7}` — semver + 7 chars
  of the Talos Factory schematic SHA256. Immutable: rebuild produces a new image,
  old + new coexist.
- **Single Scaleway project `st4ck`** hosts every env class (dev/staging/prod).
  9 IAM apps scoped per env class × 3 roles (image-builder/cluster/ci).
- **Terraform module `talos-cluster`**: generates machine secrets + machine configs
  via the `siderolabs/talos` provider. Each env calls this module then creates
  infra with its own provider (libvirt, scaleway).
- **K8s stacks**: provider-agnostic, use `kubeconfig_path` variable.
  Kubeconfig paths: `~/.kube/$(CTX_ID)` (e.g., `~/.kube/st4ck-dev-alice-fr-par`).
  Each stack co-locates TF code, Helm values, and Flux manifests in one folder.
  State path per stack per context: `/state/st4ck/{env}/{instance}/{region}/{stack}`.
- **State storage**: vault-backend → OpenBao KMS (podman or CI VM) KV v2. All
  states stored in OpenBao with locking + versioning. `backend.tf` is empty —
  path injected by Makefile at `tofu init` via `-backend-config`.
- **Day-2 management**: Flux reconciles all stacks after initial bootstrap.
  OpenTofu handles first deploy, then hands off to Flux via `tofu state rm`.
- **Secrets**: auto-generated via `random_id` Terraform, stored in encrypted state.
  No SOPS, no secrets in Git.
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

All cluster-scoped targets take `ENV`, `INSTANCE`, `REGION`:

```bash
# Inspect current context
make context

# Bootstrap (one-shot per org — IAM + SSH key + Scaleway project)
cp envs/scaleway/iam/secret.tfvars.example envs/scaleway/iam/secret.tfvars
$EDITOR envs/scaleway/iam/secret.tfvars
make scaleway-iam-apply

# Build Talos image (once per region)
make scaleway-image-apply REGION=fr-par

# Deploy shared dev CI VM (once per env class)
make scaleway-ci-apply ENV=dev INSTANCE=shared REGION=fr-par

# Point subsequent commands at the CI VM's vault-backend
export VB_HOST=root@<ci-public-ip>
make bootstrap-tunnel    # in another terminal

# Full deploy of one cluster (cluster + all k8s stacks)
make scaleway-up ENV=dev INSTANCE=alice REGION=fr-par

# Local libvirt (unchanged)
make local-up

# Individual stacks — scoped to the current context
make k8s-cni-apply       ENV=dev INSTANCE=alice REGION=fr-par
make k8s-monitoring-apply ENV=dev INSTANCE=alice REGION=fr-par
make k8s-pki-apply       ENV=dev INSTANCE=alice REGION=fr-par
make k8s-identity-apply  ENV=dev INSTANCE=alice REGION=fr-par
make k8s-security-apply  ENV=dev INSTANCE=alice REGION=fr-par
make k8s-storage-apply   ENV=dev INSTANCE=alice REGION=fr-par
make flux-bootstrap-apply ENV=dev INSTANCE=alice REGION=fr-par

# Upgrade workflow
make preflight ENV=dev INSTANCE=alice REGION=fr-par
make upgrade   ENV=dev INSTANCE=alice REGION=fr-par
make bootstrap-update

# Arbor (staging tree — pre-pull all artifacts)
make arbor                          # Pull images + Helm charts → arbor/manifest.json
make arbor-verify                   # Verify all artifacts present (SHA256 check)

# State management
make state-snapshot                 # Raft snapshot (backup all states)
make state-restore SNAPSHOT=f.snap  # Restore from snapshot

# Teardown (scoped to one context — doesn't touch other envs)
make scaleway-down     ENV=dev INSTANCE=alice REGION=fr-par
make scaleway-teardown ENV=dev INSTANCE=alice REGION=fr-par  # + destroys CI
make bootstrap-stop

# Nuke EVERYTHING (dangerous — affects every env/instance)
make scaleway-nuke
```

## Deployment Pipeline (sequential)

```
bootstrap (once, podman)
    │ → Platform pod: OpenBao 3-node Raft + vault-backend + Gitea + Woodpecker
    │ → PKI Root CA + Sub-CAs (kms-output/)
    │ → tfstate backend :8080 (via vault-backend → OpenBao KV v2)
    │
env-apply (scaleway/local)
    │ → kubeconfig → ~/.kube/talos-$(ENV)
    │
cni              ← Cilium + local-path-provisioner MUST be first (~30s)
    │
pki              ← OpenBao in-cluster + cert-manager + auto-init (~2min)
    │
monitoring       ← VictoriaMetrics + Headlamp (~2min)
    │
identity         ← Kratos + Hydra + Pomerium (~1min)
    │                 (all secrets: random_id Terraform)
security         ← Trivy + Tetragon + Kyverno (~2min)
    │
storage          ← Garage + Velero + Harbor (~2min)
    │
flux-bootstrap   ← Flux SSH + GitRepository (~30s)
    │
    ▼
Day-2 (optional)
├── Flux GitOps reconciliation (HelmReleases, Kustomize overlays)
└── scaleway-oidc ← Configure apiServer OIDC (Hydra → K8s)
```

Note: pipeline was initially parallel (make -j2) but race conditions
(VMSingle PVC Pending, Kyverno webhooks) imposed sequential mode.

## Stack Boundaries

| Stack | Owns | Interface |
|-------|------|-----------|
| cni | Cilium, local-path-provisioner | kube-system (CNI DaemonSet), local-path-storage namespace, default StorageClass |
| monitoring | vm-k8s-stack, VictoriaLogs, Headlamp | monitoring namespace |
| pki | OpenBao x2, cert-manager, ClusterIssuer, CA secrets | ClusterIssuer "internal-ca", secrets namespace |
| identity | Kratos, Hydra, Pomerium, OIDC registration | identity namespace |
| security | Trivy, Tetragon, Kyverno, Cosign policy | security namespace |
| storage | Garage (tofu — chart owner since 2026-04-29 #12), Velero, Harbor | storage + garage namespaces |
| flux-bootstrap | Flux v2, GitRepository, root Kustomization | flux-system namespace |
| external-secrets | ESO, ClusterSecretStore | external-secrets namespace |

## State Storage (vault-backend + OpenBao KV v2)

All OpenTofu states stored in OpenBao KMS (podman, 3-node Raft).
vault-backend provides HTTP backend with locking + KV v2 versioning.

```
OpenTofu ──HTTP──→ vault-backend (:8080) ──→ OpenBao KV v2 (:8200)
                   ├── /state/scaleway          → secret/data/tfstate/scaleway
                   ├── /state/cni               → secret/data/tfstate/cni
                   ├── /state/monitoring         → secret/data/tfstate/monitoring
                   ├── /state/pki               → secret/data/tfstate/pki
                   ├── /state/identity           → secret/data/tfstate/identity
                   ├── /state/security           → secret/data/tfstate/security
                   ├── /state/storage            → secret/data/tfstate/storage
                   └── /state/flux-bootstrap    → secret/data/tfstate/flux-bootstrap
```

- **Auth**: `TF_HTTP_PASSWORD` env var (vault-backend token from kms-output/)
- **Encryption**: Raft at-rest (native OpenBao)
- **Locking**: vault-backend creates `-lock` secrets in KV v2
- **DR**: `make state-snapshot` → Raft snapshot file (backup all states at once)
- **Platform pod does NOT auto-stop** — `make bootstrap-stop` to shut down

## Secrets Management

### Initial deploy (random_id)
All secrets are auto-generated via `random_id` Terraform resources.
Stored in encrypted tfstate (via vault-backend → OpenBao KV v2). Zero manual input.

### Day-2 (ESO + in-cluster OpenBao)
After pki deploys (auto-init Job), ESO can sync secrets from in-cluster OpenBao:
OpenBao KV v2 → ESO ClusterSecretStore → ExternalSecret → K8s Secret

| Secret | OpenBao path | K8s Secret | Namespace |
|--------|-------------|------------|-----------|
| Hydra system secret | secret/identity/hydra | hydra-secrets | identity |
| Pomerium shared/cookie/client | secret/identity/pomerium | pomerium-secrets | identity |
| Garage RPC + admin token | secret/storage/garage | garage-secrets | garage |
| Harbor admin password | secret/storage/harbor | harbor-secrets | storage |

No SOPS. No secrets in Git.

## Debugging Guide

### Symptom → Cause → Fix

| Symptom | Cause | Fix |
|---------|-------|-----|
| Pods stuck in `ContainerCreating` | Cilium CNI not ready | `make k8s-cni-apply` must complete first |
| `k8s-pki-apply` fails: file not found | `kms-output/` missing | Run `make bootstrap` (one-shot, needs podman) |
| `tofu init` fails: connection refused | vault-backend not running | `make bootstrap` or restart: `podman pod start platform` |
| Kyverno webhooks block deletions | Webhooks persist after pods gone | `make k8s-down` handles this (deletes webhooks first) |
| OpenBao returns `sealed` | Pod restarted, seal key missing | Check `openbao-seal-key` secret in secrets namespace |
| `k8s-storage-init` fails | Garage Helm chart not fetched | Auto-handled: `k8s-storage-init` depends on `garage-chart` |
| Port-forward zombie processes | Previous session not cleaned | `pkill -f 'kubectl port-forward'` (included in k8s-down) |
| Hydra TLS cert not issued | ClusterIssuer not ready | pki must be applied before identity |
| Flux not reconciling | GitRepository secret missing | Check `flux-git-credentials` in flux-system namespace |
| ESO ExternalSecret stuck | ClusterSecretStore not ready | Check openbao-infra-token secret in external-secrets namespace |

### Architecture Invariants

- Cilium MUST be deployed before any other k8s stack (it's the CNI)
- Cilium MUST be destroyed LAST (removing it breaks pod eviction)
- pki MUST be deployed before identity (ClusterIssuer dependency)
- In-cluster OpenBao uses self-init + static seal (no Job, no scripts)
- storage is self-contained (generates its own harbor_admin_password)
- Stacks are provider-agnostic: they only need a kubeconfig path
- vault-backend (podman) must be running for any tofu command
- Platform pod does NOT auto-stop — use `make bootstrap-stop`

### Checking Stack Health

```bash
# vault-backend + OpenBao KMS
curl -s http://localhost:8080/state/cni | head -c 100     # state accessible?
curl -s http://localhost:8200/v1/sys/health | jq .         # OpenBao healthy?

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
