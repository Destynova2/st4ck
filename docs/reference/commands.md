# Command Reference

All commands are Makefile targets. Run `make help` for the full list.

## Global Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ENV` | `scaleway` | Provider selection: `scaleway`, `local` |
| `TF` | `tofu` | Terraform binary (OpenTofu) |
| `KC_FILE` | `~/.kube/talos-$(ENV)` | Kubeconfig file path |
| `TF_HTTP_PASSWORD` | (from kms-output) | vault-backend token for state backend |

## Version Variables (vars.mk)

| Variable | Value | Description |
|----------|-------|-------------|
| `TALOS_VERSION` | v1.12.6 | Talos Linux version |
| `KUBERNETES_VERSION` | 1.35.4 | Kubernetes version |
| `CILIUM_VERSION` | 1.17.13 | Cilium CNI version |
| `IMAGER_IMAGE` | ghcr.io/siderolabs/imager:$(TALOS_VERSION) | Talos image builder |

## KMS & State Management

| Command | Description |
|---------|-------------|
| `make kms-bootstrap` | Generate PKI CA chain + start vault-backend (state storage). Requires podman. |
| `make kms-stop` | Stop the local OpenBao KMS cluster + vault-backend |
| `make state-snapshot` | Backup all OpenTofu states via Raft snapshot |
| `make state-restore SNAPSHOT=path` | Restore from a Raft snapshot file |

## Upgrade & Staging

| Command | Description |
|---------|-------------|
| `make preflight` | Pre-upgrade checks (variables, files, connectivity, TF validate) |
| `make upgrade` | Full upgrade: preflight, snapshot, bootstrap-update, provider apply, k8s-up |
| `make bootstrap-update` | Update running bootstrap pod in-place (preserves PVC data) |
| `make arbor` | Pre-stage all images, Helm charts for deployment (writes `arbor/manifest.json`) |
| `make arbor-verify` | Verify arbor staging tree (SHA256 checks on all artifacts) |

## K8s Stacks (Provider-Agnostic)

Each stack has `-init`, `-apply`, and `-destroy` targets:

| Stack | Apply Command | Dependencies |
|-------|--------------|--------------|
| CNI (Cilium) | `make k8s-cni-apply` | None (must be first) |
| Monitoring | `make k8s-monitoring-apply` | CNI |
| PKI | `make k8s-pki-apply` | CNI + kms-bootstrap |
| Identity | `make k8s-identity-apply` | PKI |
| Security | `make k8s-security-apply` | Identity |
| Storage | `make k8s-storage-apply` | Identity |
| Flux | `make flux-bootstrap-apply` | All stacks |

### Composite Targets

| Command | Description |
|---------|-------------|
| `make k8s-init` | `tofu init` all K8s stacks |
| `make k8s-up` | Deploy all 7 stacks sequentially (strict dependency order) |
| `make k8s-down` | Destroy all stacks in reverse order |

## Scaleway

| Command | Description |
|---------|-------------|
| `make scaleway-iam-init` | Init IAM stage |
| `make scaleway-iam-apply` | Create IAM apps + API keys (requires secret.tfvars) |
| `make scaleway-image-init` | Init image builder stage |
| `make scaleway-image-apply` | Build Talos image (builder VM + S3 + snapshot) |
| `make scaleway-image-destroy` | Destroy builder VM + bucket (keeps image/snapshot) |
| `make scaleway-image-clean` | Destroy ALL image resources |
| `make scaleway-init` | Init cluster stage |
| `make scaleway-plan` | Plan cluster changes |
| `make scaleway-apply` | Create cluster infrastructure |
| `make scaleway-destroy` | Destroy cluster |
| `make scaleway-wait` | Wait for K8s API server (up to 5 min) |
| `make scaleway-kubeconfig` | Export kubeconfig to ~/.kube/talos-scaleway |
| `make scaleway-up` | Full deployment: cluster + all K8s stacks |
| `make scaleway-down` | Full teardown: K8s stacks + cluster |
| `make scaleway-teardown` | Down + destroy CI (keeps IAM + image) |
| `make scaleway-nuke` | Destroy EVERYTHING (requires confirmation) |
| `make scaleway-ci-init` | Init CI VM stage |
| `make scaleway-ci-apply` | Deploy Gitea + Woodpecker CI VM |
| `make scaleway-ci-destroy` | Destroy CI VM |

## UI Access

| Command | Description |
|---------|-------------|
| `make scaleway-headlamp` | Open Headlamp UI (token in clipboard) |
| `make scaleway-grafana` | Open Grafana UI |
| `make scaleway-harbor` | Open Harbor UI (password in clipboard) |

## Local (libvirt/KVM)

| Command | Description |
|---------|-------------|
| `make local-init` | Init local environment |
| `make local-plan` | Plan local changes |
| `make local-apply` | Create local VMs |
| `make local-destroy` | Destroy local VMs |
| `make local-kubeconfig` | Export kubeconfig |
| `make local-up` | Full deployment: VMs + K8s stacks |
| `make local-down` | Full teardown |

## VMware Air-Gap

| Command | Description |
|---------|-------------|
| `make vmware-image-cache` | Build OCI image cache (requires internet) |
| `make vmware-build-ova` | Build OVA with embedded image cache |
| `make vmware-gen-configs` | Generate per-node machine configs (static IPs) |
| `make vmware-bootstrap` | Bootstrap etcd + kubeconfig (post-deployment) |

## CAPI / Kamaji / Managed Clusters

| Command | Description |
|---------|-------------|
| `make k8s-capi-init` | terraform init for CAPI stack |
| `make k8s-capi-apply` | Install CAPI + CAPS + CABPT + Kamaji CP provider |
| `make k8s-capi-destroy` | Remove CAPI providers |
| `make k8s-kamaji-apply` | Install Kamaji operator + Ænix etcd-operator |
| `make k8s-kamaji-destroy` | Remove Kamaji operator |
| `make managed-cluster-apply` | Provision a tenant cluster from the current context |
| `make managed-cluster-destroy` | Destroy the tenant cluster of the current context |
| `make kaas-up` | Bring up the full KaaS control plane on the current mgmt cluster |
| `make kaas-down` | Tear down the KaaS control plane (keeps core k8s stacks) |

## Tests

| Command | Description |
|---------|-------------|
| `make validate` | Validate all generated machine configs + tofu validate every stack |
| `make test` | Run validation + e2e tests (`validate` + e2e) |
| `make velero-test` | Run Velero backup/restore validation |

## Utilities

| Command | Description |
|---------|-------------|
| `make clean` | Remove all build artifacts |
| `make garage-chart` | Fetch Garage Helm chart v2.2.0 |
| `make lpp-chart` | Fetch local-path-provisioner Helm chart from upstream |
| `make help` | Show all targets with descriptions |

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `TF_HTTP_USERNAME` | Yes (auto-set) | AppRole role-id. Set automatically from `kms-output/approle-role-id.txt` |
| `TF_HTTP_PASSWORD` | Yes (auto-set) | AppRole secret-id. Set automatically from `kms-output/approle-secret-id.txt` |
| `SCW_ACCESS_KEY` | For Scaleway | Scaleway API access key (set per-target from IAM outputs) |
| `SCW_SECRET_KEY` | For Scaleway | Scaleway API secret key (set per-target from IAM outputs) |
| `KUBECONFIG` | For kubectl | Path to kubeconfig file |
| `PKI_ORG` | No | PKI organization name (default: "Talos Platform") |
| `PKI_ROOT_TTL` | No | Root CA TTL (default: 87600h / 10 years) |
| `PKI_INT_TTL` | No | Intermediate CA TTL (default: 43800h / 5 years) |
