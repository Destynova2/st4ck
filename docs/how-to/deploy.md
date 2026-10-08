# How to Deploy

## Deploy to Scaleway

Scaleway deployment is staged. The shared CI VM owns the canonical private
network consumed by cluster stacks, so it must exist before `scaleway-up`.

### Full first-run sequence

This sequence is for a **new deployment with no existing remote states**.
Run it from an administration machine with the repository, OpenTofu, GNU Make,
SSH tools, jq and Scaleway administrator credentials in the ignored
`envs/scaleway/iam/secret.tfvars`. The SSH key expected by the CI stack is
`~/.ssh/talos_scaleway` (public key alongside it).

SSH fetch/tunnel helpers keep host keys in `~/.ssh/st4ck/known_hosts`
(`CI_KNOWN_HOSTS` override), never erase personal known-host entries, and
reject changed keys. The default first connection is trust-on-first-use;
pre-provision verified host keys for stronger identity verification.
The tunnel uses a context-specific SSH control socket, not a stored PID.
After a legitimate VM replacement, verify the new fingerprint before updating
this dedicated file. Credential exports are private (`0700` directory,
`0600` files).

```bash
# Stage 0: temporary LOCAL state, before the remote backend exists
make scaleway-iam-apply LOCAL_BACKEND=1

# Stage 1: CI VM + private network + remote platform services
# Fetches credentials, opens the tunnel, migrates IAM + CI state.
make scaleway-bootstrap-vm ENV=dev INSTANCE=shared REGION=fr-par

# Stage 2: Talos image, now using the remote backend
make scaleway-image-apply REGION=fr-par

# Stage 3: management cluster, Tofu bootstrap, then Flux platform services
make scaleway-up ENV=dev INSTANCE=mgmt REGION=fr-par
```

No local `make bootstrap` is needed for this remote-first path. Its local
services would occupy the ports required by the remote tunnel. Preserve the
temporary state files and seal-key backups until migration is verified.
Do not use `LOCAL_BACKEND=1` on an existing remote deployment: it is not a
recovery or backend-migration shortcut.

### Teardown safety

Cluster start/stop targets run sequentially, including with parallel Make.
An error in workload teardown stops before CNI or VM destruction.
The composite CI teardown requires `BACKUP=/private/bundle`, verified before
mutation, and migrates IAM/CI state locally before stopping the backend.
The operator must confirm that this fresh bundle belongs to the CI KMS and
retains the other states hosted there, notably images, and inventory all shared
consumers. Integrity checks alone do not establish backup freshness or ownership
of the selected VM. Protected seal keys can still refuse the final destroy;
do not bypass that protection without a reviewed key-retention/recovery plan.
The old `scaleway-nuke` shortcut is disabled, not an automatic inventory or
multi-environment teardown. See [disaster recovery](disaster-recovery.md).

### Run administration from the CI VM

**Yes: the provisioned VM can also bootstrap and manage the Kubernetes
cluster.** It already hosts OpenBao KMS, vault-backend, Gitea and Woodpecker.
The initial VM and its IAM must still be created from another administration
machine; the VM cannot provision itself before it exists.

The VM image currently installs only ca-certificates, curl, git, jq and Podman.
The upload to `/opt/talos/repo` contains only `bootstrap/`, not a full checkout.
Before running deployment commands on the VM:

1. Install the administration tools: GNU Make, OpenTofu, kubectl, Helm,
   talosctl, Flux CLI, Python 3 with PyYAML, OpenSSH and the Scaleway CLI for
   targets that use it. Match the repository's pinned versions where specified.
2. Put a full checkout of the reviewed revision in a separate directory,
   for example `/opt/talos/admin`. Do not replace `/opt/talos/repo/bootstrap`,
   which is mounted by the running platform pod.
3. In that new checkout, link `kms-output` to `/opt/talos/kms-output`. Do this
   only when `kms-output` does not already exist; never overwrite existing keys.
   Several stacks use this repository-relative path, so changing only the
   Make variable `KMS_OUTPUT` is insufficient.
4. Provide the required SSH keys securely, restrict checkout/secret permissions
   to the administration account, and verify access to the cloud APIs, image
   registries, Git and the cluster endpoints. Do not publish the backend or
   secret services to the internet.

After `scaleway-bootstrap-vm` has completed and migrated the states, from
the prepared checkout **on the VM**:

```bash
make scaleway-iam-init
make scaleway-image-apply ENV=dev REGION=fr-par
make scaleway-up ENV=dev INSTANCE=mgmt REGION=fr-par
```

The backend is reached directly on `localhost:8080`; no SSH tunnel is needed
on the VM. Do not launch another platform pod with `make bootstrap`, nor rerun
`scaleway-bootstrap-vm` from inside the VM it manages. Rebuilding that VM
remains an external-administration operation. This is a supported code path
with explicit preparation, not a remotely validated turnkey admin image.

### Staged deployment

After the remote backend is already available, stages can be managed
independently. On a fresh machine, use the remote-first sequence above:

```bash
# IAM
make scaleway-iam-init
make scaleway-iam-apply

# Talos image
make scaleway-image-init REGION=fr-par
make scaleway-image-apply REGION=fr-par

# CI/shared private network must come before the cluster
make scaleway-ci-init ENV=dev INSTANCE=shared REGION=fr-par
make scaleway-ci-apply ENV=dev INSTANCE=shared REGION=fr-par

# Cluster for the chosen context
make scaleway-init ENV=dev INSTANCE=mgmt REGION=fr-par
make scaleway-apply ENV=dev INSTANCE=mgmt REGION=fr-par
make scaleway-wait ENV=dev INSTANCE=mgmt REGION=fr-par
make scaleway-kubeconfig ENV=dev INSTANCE=mgmt REGION=fr-par

# K8s stacks (after cluster is ready)
make k8s-up ENV=dev INSTANCE=mgmt REGION=fr-par
```

### Dashboards

After deployment, open dashboards explicitly:

```bash
make scaleway-headlamp ENV=dev INSTANCE=mgmt REGION=fr-par
```

## Deploy locally (libvirt/KVM)

Local deployments require Linux with libvirt/KVM.

```bash
make bootstrap && make bootstrap-export  # Once
make local-init
make local-up
```

## VMware air-gap legacy/manual path

The VMware air-gap path is not part of the current tested golden path and does
not use Terraform. It remains a manual/deferred workflow for OVA + static-IP
experiments. Prefer Scaleway or local libvirt for the maintained deployment
flows.

```bash
# Build (requires internet)
make vmware-image-cache         # Download all container images
make vmware-build-ova           # Build OVA with embedded cache

# Transfer OVA to air-gapped environment, then:
make vmware-gen-configs         # Generate per-node configs (static IPs)
make vmware-bootstrap           # Bootstrap etcd + kubeconfig
```

Edit `envs/vmware-airgap/vars.env` for IP plan and versions before generating configs.

## Deploy individual K8s stacks

Tofu owns bootstrap prerequisites. Flux owns platform services from day 1:

```bash
make k8s-cni-apply              # Must be first
make k8s-pki-apply              # Needs CNI + bootstrap/kms-output
make k8s-monitoring-apply       # Prepare secrets, relinquish old Helm state
make k8s-identity-apply         # Relinquish old identity state
make k8s-security-apply         # Relinquish old security state
make k8s-storage-apply          # Relinquish old storage state
make k8s-autoscaling-apply      # Relinquish old autoscaling state
make flux-bootstrap-apply      # Flux installs/reconciles platform services
```

Prefer `make k8s-up`, which enforces this order. Existing clusters must follow
[the ownership handoff](../adr/043-flux-platform-ownership.md) before publishing
the revision watched by Flux.

## Create tenant/KaaS control plane components

After the management cluster is running:

```bash
make kaas-up                    # CAPI + Kamaji + autoscaling + Gateway API
make managed-cluster-apply      # Provision tenant cluster from current context
make managed-cluster-destroy    # Destroy tenant cluster from current context
make kaas-down                  # Remove KaaS control-plane components
```

For lower-level control, use the namespaced targets from `make help`, such as
`k8s-capi-apply`, `k8s-kamaji-apply`, `k8s-autoscaling-apply`, and
`k8s-gateway-api-apply`.
