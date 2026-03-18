# CI/CD Pipeline Reference

## Overview

The CI/CD pipeline uses **Woodpecker CI** with **Gitea** as the Git server, running on a dedicated Scaleway VM (DEV1-M) via Podman Quadlet.

## Pipeline Triggers

```yaml
when:
  - event: [push, pull_request]
    branch: main
```

- **Pull requests**: validate step only (no secrets needed)
- **Push to main**: full pipeline (validate + build + deploy)

## Pipeline Stages

| Stage | Image | Secrets | Depends On | Description |
|-------|-------|---------|------------|-------------|
| validate | opentofu:1.9 | none | -- | `tofu init -backend=false && tofu validate` for all stacks |
| start-builder | opentofu:1.9 | scw_project_id, tf_http_password, scw_image_* | validate | Start Talos image builder VM |
| wait-image-upload | opentofu:1.9 | scw_project_id, scw_image_* | start-builder | Poll S3 for upload completion (~15 min) |
| build-image | opentofu:1.9 | scw_project_id, tf_http_password, scw_image_* | wait-image-upload | Import snapshots, create bootable images |
| deploy-cluster | opentofu:1.9 | scw_project_id, tf_http_password, scw_cluster_* | build-image | Create 6 Talos VMs + LB |
| wait-api | opentofu:1.9 | tf_http_password | deploy-cluster | Wait for K8s API server (up to 5 min) |
| deploy-cni | opentofu:1.9 | tf_http_password | wait-api | Deploy Cilium CNI |
| deploy-pki | opentofu:1.9 | tf_http_password | deploy-cni | Deploy OpenBao + cert-manager |
| deploy-monitoring | opentofu:1.9 | tf_http_password | deploy-pki | Deploy VictoriaMetrics + Headlamp |
| deploy-identity | opentofu:1.9 | tf_http_password, vault_token | deploy-monitoring | Deploy Kratos + Hydra + Pomerium |
| deploy-security | opentofu:1.9 | tf_http_password | deploy-identity | Deploy Trivy + Tetragon + Kyverno |
| deploy-storage | opentofu:1.9 | tf_http_password, vault_token | deploy-security | Deploy Garage + Velero + Harbor |
| deploy-flux | opentofu:1.9 | tf_http_password | deploy-storage | Deploy Flux v2 GitOps |

## Required Secrets

Configure these in Woodpecker CI settings (Settings > Secrets):

| Secret Name | Description | Source |
|-------------|-------------|--------|
| `tf_http_password` | vault-backend token | kms-output/vault-backend-token.txt |
| `vault_token` | OpenBao cluster secrets token | kms-output/cluster-secrets-token.txt |
| `scw_project_id` | Scaleway project ID | `tofu -chdir=envs/scaleway/iam output -raw project_id` |
| `scw_image_access_key` | Image builder API key | IAM stage output |
| `scw_image_secret_key` | Image builder API secret | IAM stage output |
| `scw_cluster_access_key` | Cluster API key | IAM stage output |
| `scw_cluster_secret_key` | Cluster API secret | IAM stage output |

## State Backend in CI

The CI pipeline accesses vault-backend via the host network:

```
VB=http://host.containers.internal:8080
```

Each stack initializes with dynamic backend config:

```bash
tofu init -input=false \
  -backend-config="address=$VB/state/$STACK" \
  -backend-config="lock_address=$VB/state/$STACK" \
  -backend-config="unlock_address=$VB/state/$STACK"
```

## CI VM Architecture

```
Scaleway DEV1-M VM
  /etc/containers/systemd/ci.kube     Quadlet unit (systemd)
    /opt/woodpecker/ci-pod.yaml       Pod manifest (podman play kube)
      gitea        :3000 (UI) :2222 (SSH)
      woodpecker-server  :8000 (UI) :9000 (gRPC)
      woodpecker-agent   (mounts /run/podman/podman.sock)
```

Cloud-init handles: podman install, repo clone, Gitea admin creation, OAuth app for Woodpecker, repo push, Scaleway secrets injection.

## Validated Stacks

The validate step checks these directories (no backend needed):

```
envs/scaleway/image
envs/scaleway
envs/scaleway/ci
stacks/cni
stacks/monitoring
stacks/pki
stacks/identity
stacks/security
stacks/storage
stacks/flux-bootstrap
```

## Pipeline File

The pipeline is defined in `.woodpecker.yml` at the repository root. It uses YAML anchors (`&deploy_stack`, `&deploy_stack_vault`) to avoid repetition across deploy steps.
