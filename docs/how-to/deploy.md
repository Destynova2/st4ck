# How to Deploy

## Deploy to Scaleway

Scaleway deployment is staged. The shared CI VM owns the canonical private
network consumed by cluster stacks, so it must exist before `scaleway-up`.

### Full first-run sequence

```bash
# Once: local OpenBao KMS + platform pod
make bootstrap
make bootstrap-export

# Stage 0: IAM (admin credentials required)
make scaleway-iam-init
make scaleway-iam-apply

# Stage 1: Talos image
make scaleway-image-init
make scaleway-image-apply REGION=fr-par

# Stage 2: shared CI VM + private network + remote platform services
make scaleway-bootstrap-vm ENV=dev INSTANCE=shared REGION=fr-par

# Stage 3: target management cluster + day-1 K8s stacks
make scaleway-up ENV=dev INSTANCE=mgmt REGION=fr-par
```

### Staged deployment

If you need more control, deploy each stage independently:

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

Each stack can be deployed independently (respecting dependencies):

```bash
make k8s-cni-apply              # Must be first
make k8s-pki-apply              # Needs CNI + bootstrap/kms-output
make k8s-monitoring-apply       # Needs CNI
make k8s-identity-apply         # Needs k8s-pki
make k8s-security-apply         # Needs k8s-identity
make k8s-storage-apply          # Needs k8s-identity
make flux-bootstrap-apply       # After all stacks
```

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
