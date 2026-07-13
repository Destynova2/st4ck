# Command Reference

All commands are Makefile targets. Run `make help` for the full list.

## Global Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ENV` | `dev` | Environment class: `dev`, `staging`, `prod` |
| `INSTANCE` | `shared` | Context instance name; use `mgmt` for the target management cluster examples |
| `REGION` | `fr-par` | Scaleway/local region identifier |
| `PROVIDER` | `scaleway` | Provider implementation: `scaleway`, `local` |
| `TF` | `tofu` | Terraform binary (OpenTofu) |
| `KC_FILE` | `~/.kube/$(NAMESPACE)-$(ENV)-$(INSTANCE)-$(REGION)` | Context-scoped kubeconfig file path |
| `TF_HTTP_PASSWORD` | (from kms-output) | vault-backend token for state backend |

## Version Pins

All chart/provider pins: `clusters/management/versions-configmap.yaml`
(single source — tofu + Flux + hauler). Talos/K8s machine versions:
`contexts/_defaults.yaml`. `vars.mk` holds only `OUT_DIR`.

## KMS & State Management

| Command | Description |
|---------|-------------|
| `make bootstrap` | Start the platform pod: OpenBao KMS, vault-backend, Gitea, Woodpecker. Requires podman. |
| `make bootstrap-export` | Export AppRole credentials, tokens, and CA material to `kms-output/`. |
| `make kms-bootstrap` | Compatibility alias for `make bootstrap`. |
| `make kms-stop` | Compatibility alias for `make bootstrap-stop`. |
| `make state-snapshot` | Backup all OpenTofu states via Raft snapshot |
| `make state-restore SNAPSHOT=path` | Restore from a Raft snapshot file |

## Upgrade & Staging

| Command | Description |
|---------|-------------|
| `make preflight` | Pre-upgrade checks (variables, files, connectivity, TF validate) |
| `make upgrade` | Full upgrade: preflight, snapshot, bootstrap-update, provider apply, k8s-up |
| `make bootstrap-update` | Update running bootstrap pod in-place (preserves PVC data) |
| `make arbor` | Pre-stage all images, Helm charts for deployment (writes `arbor/manifest.json`) — superseded by Hauler (ADR-034) |
| `make arbor-verify` | Verify arbor staging tree (SHA256 checks on all artifacts) |
| `make hauler-manifest` | Regenerate `hauler-manifest.yaml` from repo sources of truth (ADR-034) |
| `make hauler-sync` | Pull all artifacts (images, charts, files) into the local `haul/` store |
| `make hauler-verify` | List store contents (digest-addressed OCI layout) |
| `make hauler-save` | Export store to chunked tarball for air-gap transfer |
| `make hauler-serve` | Serve store as OCI registry on :5000 (registry-mirror endpoint candidate) |
| `make local-docker-up` | Disposable Talos-in-containers cluster + Cilium, native arch (rootful podman) |
| `make local-docker-down` | Destroy the local docker-mode cluster |

## K8s Stacks (Provider-Agnostic)

Each stack has `-init`, `-apply`, and `-destroy` targets:

| Stack | Apply Command | Dependencies |
|-------|--------------|--------------|
| CNI (Cilium) | `make k8s-cni-apply` | None (must be first) |
| Monitoring | `make k8s-monitoring-apply` | CNI |
| PKI | `make k8s-pki-apply` | CNI + bootstrap/kms-output |
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
| `make scaleway-kubeconfig` | Export kubeconfig to the context path (`$(KC_FILE)`) |
| `make scaleway-bootstrap-vm` | Deploy the shared CI VM/private network required before cluster creation |
| `make scaleway-up` | Full deployment for the current context: cluster + K8s stacks |
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
| `make scaleway-zot` | Open zot UI (admin password in clipboard) |

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

## VMware Air-Gap (legacy/manual)

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
| `make test` | Run validation + OpenTofu tests (`validate` + `scaleway-test`) |
| `make velero-test` | Run Velero backup/restore E2E validation (requires running cluster) |

## Utilities

| Command | Description |
|---------|-------------|
| `make clean` | Remove all build artifacts |
| `make garage-chart` | Fetch Garage Helm chart v2.3.0 |
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
