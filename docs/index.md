# Talos Linux Multi-Environment Deployment Platform

A sovereign, air-gap-capable Kubernetes platform built on [Talos Linux](https://www.talos.dev/) v1.12. It deploys a production-grade management cluster with full observability, PKI, zero-trust identity, runtime security, S3-compatible storage, and GitOps -- all orchestrated by a single Makefile.

## What problem does it solve?

Deploying a hardened Kubernetes platform in defense/sovereign contexts requires dozens of components with strict dependency ordering, certificate chains, secrets management, and air-gap compatibility. OpenTofu bootstraps the cluster and its trust foundation; Flux installs and reconciles the management services.

## Who is it for?

- **Platform engineers** deploying Kubernetes in regulated or air-gapped environments
- **DevOps teams** needing a reproducible, multi-cloud Kubernetes foundation
- **Security teams** requiring hardened, sovereign infrastructure

## How it works

```mermaid
graph LR
    KMS[bootstrap<br/>OpenBao KMS + PKI + state backend] --> INFRA[Infrastructure<br/>cluster 6 noeuds]
    INFRA --> BASE[CNI + PKI + ESO<br/>OpenTofu]
    BASE --> FLUX[Flux<br/>install and reconcile services]
```

## Supported environments

| Environment | Provider | Method |
|------------|----------|--------|
| Scaleway | scaleway/scaleway | OpenTofu (4 stages: IAM, image, cluster, CI) |
| Local dev | libvirt/KVM | OpenTofu (QEMU VMs) |
| VMware airgap | vSphere (no API) | Shell scripts (OVA + static IPs) |

## Quick start

Existing clusters require the [ownership migration](adr/043-flux-platform-ownership.md)
before the new revision is published to the reference watched by Flux.

```bash
# 1. Bootstrap local KMS (once, needs podman)
make bootstrap
make bootstrap-export

# 2. Deploy a cluster (pick your provider)
make scaleway-up        # Cloud
make PROVIDER=local local-up # Local VMs

# 3. Access dashboards
make scaleway-headlamp  # Kubernetes UI
make scaleway-grafana   # Metrics & logs
```

See [Getting Started](tutorials/getting-started.md) for a detailed walkthrough.

## Documentation map

| Need | Go to |
|------|-------|
| First deployment, step by step | [Getting Started](tutorials/getting-started.md) |
| Deploy to a specific environment | [How to Deploy](how-to/deploy.md) |
| Understand the architecture | [Architecture](explanation/architecture.md) |
| Bootstrap chicken-and-egg | [Bootstrap Mechanics](explanation/bootstrap.md) |
| Full deployment order, laptop to baremetal | [Deploy Order](explanation/deploy-order.md) |
| Security model and threat assumptions | [Security Model](explanation/security.md) |
| All Makefile targets and config options | [Command Reference](reference/commands.md) |
| All configurable parameters | [Configuration Reference](reference/config.md) |
| CI/CD pipeline details | [CI/CD Reference](reference/ci-cd.md) |
| Upgrade an existing deployment | [Upgrade Guide](how-to/upgrade.md) |
| Troubleshoot a problem | [Troubleshooting](how-to/troubleshoot.md) |
| Why a specific technology was chosen | [ADRs](adr/) |
| Flux ownership and existing-cluster migration | [ADR-043](adr/043-flux-platform-ownership.md) |
| VM / Elastic Metal transition rules | [ADR-044](adr/044-scaleway-vm-metal-rules.md) |
| Native autoscaling lab activation | [Scaleway autoscaling](how-to/scaleway-autoscaling.md) |
| Current audit and validation limits | [Adversarial review](reviews/2026-09-27-adversarial-closure.md) |
| Version inventory and compatibility | [Dependency audit](reviews/2026-09-27-versions-audit.md) |
| Renovate configuration and operating evidence | [Renovate audit](reviews/2026-09-27-renovate-audit.md) |
| Schema coverage and CI replay | [Schema validation](reviews/2026-09-27-schema-ci.md) |
| Kubescape fix and clean local rebuild | [Local platform validation](reviews/2026-09-26-kubescape-clean-bootstrap.md) |
| Full component inventory | [Technology Stack](techno.md) |
| High-level system design | [HLD](hld-talos-platform.md) |
| Implementation timeline | [Roadmap](roadmap.md) |
| How to contribute | [CONTRIBUTING.md](../CONTRIBUTING.md) |
