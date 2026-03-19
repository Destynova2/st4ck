# Getting Started

This tutorial takes you from a fresh checkout to a running Talos Kubernetes cluster with full observability. Estimated time: 20 minutes (including cloud provisioning).

## Prerequisites

Install these tools before proceeding:

| Tool | Version | Purpose | Install |
|------|---------|---------|---------|
| OpenTofu | >= 1.9 | Infrastructure as Code | `brew install opentofu` |
| podman | >= 4.0 | Local KMS bootstrap (OpenBao) | `brew install podman` |
| kubectl | >= 1.35 | Kubernetes CLI | `brew install kubectl` |
| jq | any | JSON parsing in scripts | `brew install jq` |
| Helm | >= 3.0 | Helm chart templating | `brew install helm` |

For Scaleway deployments, you also need:
- A Scaleway account with Organization admin access
- `scw` CLI configured (`brew install scw`)

For local deployments:
- libvirt/KVM (`brew install libvirt` on Linux, not available on macOS)
- At least 16 GB RAM and 8 CPU cores

## Step 1: Clone the repository

```bash
git clone git@github.com:Destynova2/st4ck.git
cd st4ck
```

## Step 2: Bootstrap the platform pod

The platform pod is a local podman pod containing: 3-node OpenBao Raft cluster, vault-backend, Gitea, and a tofu-setup sidecar. It generates:
- Root CA + intermediate CA
- Static seal key for in-cluster OpenBao
- vault-backend token for Terraform state storage

```bash
make bootstrap
make bootstrap-export    # Copy tokens + certs to kms-output/
```

Expected output:
```
=========================================
  Platform starting
=========================================
  OpenBao:  http://127.0.0.1:8200
  State:    http://127.0.0.1:8080
=========================================
```

Verify it is running:
```bash
curl -s http://localhost:8200/v1/sys/health | jq .
curl -s http://localhost:8080/state/test  # Should return empty or 404
```

The `kms-output/` directory now contains certificates and tokens. This directory is gitignored and must not be committed.

## Step 3: Configure Scaleway credentials (Scaleway only)

Create the IAM secret file:

```bash
cat > envs/scaleway/iam/secret.tfvars << 'EOF'
organization_id = "your-org-id"
access_key      = "your-admin-access-key"
secret_key      = "your-admin-secret-key"
EOF
```

Bootstrap IAM (creates scoped API keys for image builder, cluster, and CI):

```bash
make scaleway-iam-init
make scaleway-iam-apply
```

## Step 4: Deploy the cluster

### Option A: Scaleway (cloud)

```bash
make scaleway-up
```

This runs the full pipeline:
1. `scaleway-apply` -- Creates VMs, load balancer, private network
2. `scaleway-wait` -- Waits for Kubernetes API server (up to 5 minutes)
3. `scaleway-kubeconfig` -- Writes kubeconfig to `~/.kube/talos-scaleway`
4. `k8s-up` -- Deploys all 7 stacks sequentially (~15 minutes)

### Option B: Local (libvirt/KVM)

```bash
make ENV=local local-up
```

## Step 5: Verify the deployment

Check that all pods are running:

```bash
export KUBECONFIG=~/.kube/talos-scaleway  # or talos-local
kubectl get pods -A | grep -v Running | grep -v Completed
```

All stacks should be healthy:

```bash
# Cilium
kubectl -n kube-system get pods -l app.kubernetes.io/name=cilium-agent

# Monitoring
kubectl -n monitoring get pods

# PKI
kubectl -n secrets get pods

# Security
kubectl -n security get pods

# Storage
kubectl -n garage get pods
kubectl -n storage get pods
```

## Step 6: Access the dashboards

```bash
# Headlamp (Kubernetes UI) -- token copied to clipboard
make scaleway-headlamp

# Grafana (metrics and logs)
make scaleway-grafana

# Harbor (container registry) -- password copied to clipboard
make scaleway-harbor
```

## What was deployed?

At this point, your cluster has:

| Stack | Components | Namespace |
|-------|-----------|-----------|
| CNI | Cilium (eBPF, replaces kube-proxy) | kube-system |
| Monitoring | VictoriaMetrics, VictoriaLogs, Grafana, Headlamp | monitoring |
| PKI | OpenBao x2, cert-manager, Root/Intermediate CA | secrets |
| Identity | Kratos, Hydra, Pomerium (OIDC/SSO) | identity |
| Security | Trivy, Tetragon, Kyverno, Cosign policy | security |
| Storage | local-path, Garage S3, Velero, Harbor | garage, storage |
| GitOps | Flux v2 (day-2 reconciliation) | flux-system |

## Next steps

- [How to deploy to other environments](../how-to/deploy.md)
- [How to troubleshoot common issues](../how-to/troubleshoot.md)
- [Architecture explanation](../explanation/architecture.md)
- [Command reference](../reference/commands.md)

## Teardown

When you are done:

```bash
make scaleway-down    # Destroy k8s stacks + cluster
make kms-stop         # Stop local KMS pod
```

To destroy everything including IAM and images:

```bash
make scaleway-nuke    # Requires confirmation prompt
```
