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
│   └── envs/
│       ├── local/                      # Provider: libvirt (QEMU/KVM)
│       ├── outscale/                   # Provider: outscale (FCU)
│       └── scaleway/                   # Provider: scaleway (fr-par)
│
├── envs/
│   └── vmware-airgap/                  # NOT Terraform — scripts pipeline
│       ├── scripts/                    # build-image-cache, build-ova, gen-configs
│       ├── patches/                    # Generated per-node static IP patches
│       └── vars.env                    # IP plan, versions
│
├── configs/
│   ├── cilium/                         # Helm values + manifest generator
│   └── patches/                        # Common Talos patches (cilium-cni.yaml)
│
├── scripts/                            # Shared validation
└── docs/                               # VMware deployment instructions (FR)
```

## Architecture

- **Terraform module `talos-cluster`**: generates machine secrets + machine configs
  via the `siderolabs/talos` provider. Each env calls this module then creates
  infra with its own provider (libvirt, outscale, scaleway).
- **VMware airgap**: no Terraform (no vSphere API access). Shell scripts build
  an OVA with embedded image cache + generate per-node YAML configs with static IPs.

## Key Conventions

- Talos v1.12, Kubernetes 1.35, Cilium 1.17
- CNI: `cni: none` + `proxy: disabled` (Cilium replaces kube-proxy in eBPF mode)
- Topology: 3 control planes + N workers
- Sensitive outputs (talosconfig, kubeconfig) are marked `sensitive` in Terraform

## Common Commands

```bash
# Local (libvirt/KVM)
make local-init && make local-apply

# Cloud
make outscale-init && make outscale-apply
make scaleway-init && make scaleway-apply

# VMware airgap
make vmware-image-cache
make vmware-build-ova
make vmware-gen-configs

# Utilities
make cilium-manifests   # Helm template → static YAML
make validate           # Validate all machine configs
```
