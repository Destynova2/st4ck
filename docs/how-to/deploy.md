# How to Deploy

## Deploy to Scaleway

### Full deployment (recommended)

```bash
make kms-bootstrap          # Once: local KMS + PKI
make scaleway-bootstrap     # Once: IAM + CI VM
make scaleway-up            # Cluster + all K8s stacks
```

### Staged deployment

If you need more control, deploy each stage independently:

```bash
# Stage 0: IAM (admin credentials required)
make scaleway-iam-init && make scaleway-iam-apply

# Stage 1: Talos image
make scaleway-image-init && make scaleway-image-apply

# Stage 2: Cluster
make scaleway-init && make scaleway-apply && make scaleway-wait

# Stage 3: CI VM (Gitea + Woodpecker)
make scaleway-ci-init && make scaleway-ci-apply

# K8s stacks (after cluster is ready)
make scaleway-kubeconfig
make k8s-up
```

### Demo mode

Deploys cluster with live dashboards that open automatically:

```bash
make scaleway-demo
```

## Deploy locally (libvirt/KVM)

```bash
make kms-bootstrap              # Once
make local-init && make local-up
```

## Deploy to Outscale

```bash
make kms-bootstrap              # Once
make outscale-init && make outscale-up
```

## Deploy to VMware (air-gapped)

The VMware path does not use Terraform. It builds an OVA with embedded container images:

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

Each stack can be deployed independently (respecting dependencies):

```bash
make k8s-cni-apply              # Must be first
make k8s-pki-apply              # Needs CNI + kms-bootstrap
make k8s-monitoring-apply       # Needs CNI
make k8s-identity-apply         # Needs k8s-pki
make k8s-security-apply         # Needs k8s-identity
make k8s-storage-apply          # Needs k8s-identity
make flux-bootstrap-apply       # After all stacks
```

## Create workload clusters (CAPI)

After the management cluster is running:

```bash
make capi-init                  # Install CAPI providers
make capi-create-cpu            # CPU workload cluster
make capi-create-gpu            # GPU workload cluster
make capi-status                # Check cluster status
make capi-kubeconfig CLUSTER=x  # Get workload kubeconfig
make capi-delete CLUSTER=x      # Delete workload cluster
```
